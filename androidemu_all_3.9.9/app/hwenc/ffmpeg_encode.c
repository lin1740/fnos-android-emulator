/* Ver ffmpeg_encode.h. */
#include "ffmpeg_encode.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_vaapi.h>
#include <libavutil/opt.h>

#define FIXED_QP 26 /* matches ratectl.h's RC_QP_LEGACY -- see ffmpeg_encode.h on why CQP/fixed */

struct FFmpegEncState {
    AVBufferRef *hw_dev;
    AVCodecContext *ctx;
    AVFrame *sw;   /* persistent NV12 software frame, refilled every call */
    AVFrame *hw;   /* persistent VAAPI hardware frame, re-gotten from the pool every call */
    AVPacket *pkt;
    unsigned int width, height;
    int64_t next_pts;
    /* Scratch buffer for the NV12 download off src_surface -- grown as needed, never shrunk. */
    uint8_t *dl_buf;
    size_t dl_cap;
};

static void averr(const char *what, int err) {
    char b[128];
    av_strerror(err, b, sizeof(b));
    fprintf(stderr, "ffmpeg_encode: %s: %s\n", what, b);
}

FFmpegEncState *ffmpeg_encode_open(const char *drm_node) {
    FFmpegEncState *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    int r = av_hwdevice_ctx_create(&s->hw_dev, AV_HWDEVICE_TYPE_VAAPI, drm_node, NULL, 0);
    if (r < 0) { averr("av_hwdevice_ctx_create(VAAPI)", r); free(s); return NULL; }
    s->pkt = av_packet_alloc();
    s->sw = av_frame_alloc();
    s->hw = av_frame_alloc();
    if (!s->pkt || !s->sw || !s->hw) { ffmpeg_encode_close(s); return NULL; }
    return s;
}

static void close_codec(FFmpegEncState *s) {
    avcodec_free_context(&s->ctx);
}

/* (Re)opens the encoder for this resolution. A no-op if nothing changed since the last call (the
 * common case: one instance streams at a fixed resolution). */
static int ensure_codec(FFmpegEncState *s, unsigned int width, unsigned int height) {
    if (s->ctx && s->width == width && s->height == height) return 0;
    close_codec(s);

    const AVCodec *enc = avcodec_find_encoder_by_name("h264_vaapi");
    if (!enc) { fprintf(stderr, "ffmpeg_encode: libavcodec has no h264_vaapi encoder\n"); return -1; }
    s->ctx = avcodec_alloc_context3(enc);
    if (!s->ctx) return -1;

    s->ctx->width = (int)width;
    s->ctx->height = (int)height;
    s->ctx->time_base = (AVRational){1, 90000};
    s->ctx->framerate = (AVRational){60, 1};
    s->ctx->pix_fmt = AV_PIX_FMT_VAAPI;
    s->ctx->gop_size = 1 << 30; /* IDR timing is driven per-frame via force_idr, not this counter */
    s->ctx->max_b_frames = 0;
    s->ctx->refs = 1;
    s->ctx->profile = AV_PROFILE_H264_CONSTRAINED_BASELINE;

    AVBufferRef *frames_ref = av_hwframe_ctx_alloc(s->hw_dev);
    if (!frames_ref) { fprintf(stderr, "ffmpeg_encode: av_hwframe_ctx_alloc failed\n"); close_codec(s); return -1; }
    AVHWFramesContext *frames_ctx = (AVHWFramesContext *)frames_ref->data;
    frames_ctx->format = AV_PIX_FMT_VAAPI;
    frames_ctx->sw_format = AV_PIX_FMT_NV12;
    frames_ctx->width = (int)width;
    frames_ctx->height = (int)height;
    frames_ctx->initial_pool_size = 4;
    int r = av_hwframe_ctx_init(frames_ref);
    if (r < 0) {
        averr("av_hwframe_ctx_init", r);
        av_buffer_unref(&frames_ref);
        close_codec(s);
        return -1;
    }
    s->ctx->hw_frames_ctx = av_buffer_ref(frames_ref);
    av_buffer_unref(&frames_ref);

    /* The wire protocol is one connection = one encode request/response (protocol.h) -- the
     * encoder's own default async_depth=2 buffers up to 2 frames before emitting a packet,
     * which left avcodec_receive_packet() with nothing to return for the very first frame
     * (confirmed live: "no packet produced for this frame"). Forcing it to 1 makes send/receive
     * fully synchronous, matching what every caller of this module already assumes. */
    av_opt_set_int(s->ctx->priv_data, "async_depth", 1, 0);

    /* CQP, forced explicitly -- see ffmpeg_encode.h's comment on ffmpeg_encode_frame() for why
     * (confirmed live on Intel: this driver/entrypoint only supports CQP, and leaving the RC mode
     * on "auto" picked something else and failed avcodec_open2() outright). */
    av_opt_set(s->ctx->priv_data, "rc_mode", "CQP", 0);
    av_opt_set_int(s->ctx->priv_data, "qp", FIXED_QP, 0);

    r = avcodec_open2(s->ctx, enc, NULL);
    if (r < 0) { averr("avcodec_open2", r); close_codec(s); return -1; }

    s->width = width;
    s->height = height;
    s->next_pts = 0;
    fprintf(stderr, "ffmpeg_encode: h264_vaapi opened, %ux%u, CQP qp=%d\n", width, height, FIXED_QP);
    return 0;
}

/* Downloads `surface` (already NV12) off `dpy` into s->dl_buf, tightly packed (no row padding):
 * width*height bytes of Y, then width*height/2 bytes of interleaved UV. Same vaDeriveImage/
 * vaMapBuffer technique hwdec.c's va_download() already uses (the daemon's own proven way to pull
 * VA-API surface pixels into RAM), just duplicated here rather than shared -- it is a small,
 * self-contained helper and this module intentionally doesn't share any VA-API state with
 * daemon.c's own st->dpy (see ffmpeg_encode.h). */
static int download_nv12(FFmpegEncState *s, VADisplay dpy, VASurfaceID surface, unsigned int width,
                          unsigned int height) {
    const size_t need = (size_t)width * height + (size_t)width * height / 2;
    if (need > s->dl_cap) {
        uint8_t *nb = realloc(s->dl_buf, need);
        if (!nb) return -1;
        s->dl_buf = nb;
        s->dl_cap = need;
    }

    VAImage img;
    VAStatus st = vaDeriveImage(dpy, surface, &img);
    if (st != VA_STATUS_SUCCESS) { fprintf(stderr, "ffmpeg_encode: vaDeriveImage: %s\n", vaErrorStr(st)); return -1; }
    void *p = NULL;
    st = vaMapBuffer(dpy, img.buf, &p);
    if (st != VA_STATUS_SUCCESS) {
        fprintf(stderr, "ffmpeg_encode: vaMapBuffer: %s\n", vaErrorStr(st));
        vaDestroyImage(dpy, img.image_id);
        return -1;
    }
    const uint8_t *base = p;
    const unsigned int crows = (height + 1) / 2;
    uint8_t *dy = s->dl_buf, *duv = s->dl_buf + (size_t)width * height;
    for (unsigned int y = 0; y < height; y++)
        memcpy(dy + (size_t)y * width, base + img.offsets[0] + (size_t)y * img.pitches[0], width);
    for (unsigned int y = 0; y < crows; y++)
        memcpy(duv + (size_t)y * width, base + img.offsets[1] + (size_t)y * img.pitches[1], width);
    vaUnmapBuffer(dpy, img.buf);
    vaDestroyImage(dpy, img.image_id);
    return 0;
}

long ffmpeg_encode_frame(FFmpegEncState *s, VADisplay src_dpy, VASurfaceID src_surface, unsigned int width,
                          unsigned int height, int force_idr, unsigned char **out_buf) {
    if (download_nv12(s, src_dpy, src_surface, width, height) != 0) return -1;
    if (ensure_codec(s, width, height) != 0) return -1;

    av_frame_unref(s->sw);
    s->sw->format = AV_PIX_FMT_NV12;
    s->sw->width = (int)width;
    s->sw->height = (int)height;
    int r = av_frame_get_buffer(s->sw, 0);
    if (r < 0) { averr("av_frame_get_buffer", r); return -1; }

    const unsigned int crows = (height + 1) / 2;
    const uint8_t *sy = s->dl_buf, *suv = s->dl_buf + (size_t)width * height;
    for (unsigned int y = 0; y < height; y++)
        memcpy(s->sw->data[0] + (size_t)y * s->sw->linesize[0], sy + (size_t)y * width, width);
    for (unsigned int y = 0; y < crows; y++)
        memcpy(s->sw->data[1] + (size_t)y * s->sw->linesize[1], suv + (size_t)y * width, width);

    av_frame_unref(s->hw);
    r = av_hwframe_get_buffer(s->ctx->hw_frames_ctx, s->hw, 0);
    if (r < 0) { averr("av_hwframe_get_buffer", r); return -1; }
    r = av_hwframe_transfer_data(s->hw, s->sw, 0);
    if (r < 0) { averr("av_hwframe_transfer_data", r); return -1; }
    s->hw->pts = s->next_pts++;
    /* The documented way to force a keyframe on a specific frame via the public encode API (the
     * same idiom ffmpeg's own CLI uses for -force_key_frames, fftools/ffmpeg_enc.c) -- gop_size
     * above is set high on purpose so the encoder's own periodic counter never fires on its own;
     * gop_next()'s decision (new peer, resolution change, periodic, previous frame failed) is the
     * only thing that decides this, identically to the legacy backend. */
    s->hw->pict_type = force_idr ? AV_PICTURE_TYPE_I : AV_PICTURE_TYPE_NONE;

    r = avcodec_send_frame(s->ctx, s->hw);
    if (r < 0) { averr("avcodec_send_frame", r); return -1; }

    unsigned char *out = NULL;
    size_t total = 0;
    for (;;) {
        av_packet_unref(s->pkt);
        r = avcodec_receive_packet(s->ctx, s->pkt);
        if (r == AVERROR(EAGAIN) || r == AVERROR_EOF) break;
        if (r < 0) { averr("avcodec_receive_packet", r); free(out); return -1; }
        unsigned char *grown = realloc(out, total + (size_t)s->pkt->size);
        if (!grown) { free(out); return -1; }
        out = grown;
        memcpy(out + total, s->pkt->data, (size_t)s->pkt->size);
        total += (size_t)s->pkt->size;
    }
    if (total == 0) { fprintf(stderr, "ffmpeg_encode: no packet produced for this frame\n"); free(out); return -1; }
    *out_buf = out;
    return (long)total;
}

void ffmpeg_encode_close(FFmpegEncState *s) {
    if (!s) return;
    close_codec(s);
    av_packet_free(&s->pkt);
    av_frame_free(&s->sw);
    av_frame_free(&s->hw);
    av_buffer_unref(&s->hw_dev);
    free(s->dl_buf);
    free(s);
}
