/* Ver hwdec.h. */
#include "hwdec.h"

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_vaapi.h>
#include <libavutil/imgutils.h>
#include <libavutil/pixdesc.h>

#include <va/va.h>
#include <immintrin.h>
#include <va/va_drm.h>

static const char *CODEC_NAMES[HWDEC_NCODECS] = {"h264", "hevc", "vp9", "vp8", "mpeg2", "vc1", "av1"};

const char *hwdec_codec_name(HwDecCodec c) {
    return (c >= 0 && c < HWDEC_NCODECS) ? CODEC_NAMES[c] : "?";
}

static enum AVCodecID codec_id(HwDecCodec c) {
    switch (c) {
    case HWDEC_H264: return AV_CODEC_ID_H264;
    case HWDEC_HEVC: return AV_CODEC_ID_HEVC;
    case HWDEC_VP9: return AV_CODEC_ID_VP9;
    case HWDEC_VP8: return AV_CODEC_ID_VP8;
    case HWDEC_MPEG2: return AV_CODEC_ID_MPEG2VIDEO;
    case HWDEC_VC1: return AV_CODEC_ID_VC1;
    case HWDEC_AV1: return AV_CODEC_ID_AV1;
    default: return AV_CODEC_ID_NONE;
    }
}

/* ---------------------------- probe (libva only) ---------------------------- */

int hwdec_probe(const char *drm_node, HwDecCaps *caps) {
    memset(caps, 0, sizeof(*caps));
    int fd = open(drm_node, O_RDWR);
    if (fd < 0) { perror("hwdec_probe: open"); return -1; }
    VADisplay dpy = vaGetDisplayDRM(fd);
    int major, minor;
    if (!dpy || vaInitialize(dpy, &major, &minor) != VA_STATUS_SUCCESS) {
        fprintf(stderr, "hwdec_probe: vaInitialize failed on %s\n", drm_node);
        close(fd);
        return -1;
    }
    const char *vendor = vaQueryVendorString(dpy);
    snprintf(caps->driver, sizeof(caps->driver), "%s", vendor ? vendor : "?");

    int np = vaMaxNumProfiles(dpy);
    VAProfile *profiles = calloc(np, sizeof(*profiles));
    int n = 0;
    if (profiles && vaQueryConfigProfiles(dpy, profiles, &n) == VA_STATUS_SUCCESS) {
        int ne_max = vaMaxNumEntrypoints(dpy);
        VAEntrypoint *eps = calloc(ne_max, sizeof(*eps));
        for (int i = 0; eps && i < n; i++) {
            int ne = 0;
            if (vaQueryConfigEntrypoints(dpy, profiles[i], eps, &ne) != VA_STATUS_SUCCESS) continue;
            int vld = 0;
            for (int j = 0; j < ne; j++) if (eps[j] == VAEntrypointVLD) vld = 1;
            if (!vld) continue;
            switch (profiles[i]) {
            case VAProfileH264ConstrainedBaseline: case VAProfileH264Main: case VAProfileH264High:
                caps->supported[HWDEC_H264] = 1; break;
            case VAProfileHEVCMain: caps->supported[HWDEC_HEVC] = 1; break;
            case VAProfileHEVCMain10: caps->supported[HWDEC_HEVC] = caps->supported_10bit[HWDEC_HEVC] = 1; break;
            case VAProfileVP9Profile0: caps->supported[HWDEC_VP9] = 1; break;
            case VAProfileVP9Profile2: caps->supported[HWDEC_VP9] = caps->supported_10bit[HWDEC_VP9] = 1; break;
            case VAProfileVP8Version0_3: caps->supported[HWDEC_VP8] = 1; break;
            case VAProfileMPEG2Simple: case VAProfileMPEG2Main: caps->supported[HWDEC_MPEG2] = 1; break;
            case VAProfileVC1Simple: case VAProfileVC1Main: case VAProfileVC1Advanced:
                caps->supported[HWDEC_VC1] = 1; break;
            case VAProfileAV1Profile0: caps->supported[HWDEC_AV1] = 1; caps->supported_10bit[HWDEC_AV1] = 1; break;
            default: break;
            }
        }
        free(eps);
    }
    free(profiles);
    vaTerminate(dpy);
    close(fd);
    return 0;
}

/* ------------------------------- sesion ------------------------------------ */

struct HwDecSession {
    HwDecCodec codec;
    AVBufferRef *hw_dev;
    AVCodecContext *ctx;
    AVPacket *pkt;
    AVFrame *frame;
    AVFrame *sw;
    uint8_t *buf;
    size_t cap;
    /* Time per stage (REDROID_FORGE_HWDEC_STATS=1), in ns. */
    /* How the frame is brought from the GPU to RAM (REDROID_FORGE_HWDEC_DOWNLOAD): ffmpeg | getimage | derive | derive-sse */
    int dl_mode;
    int dl_checked;    /* the first frame has already been compared against ffmpeg's download */
    VAImage img;       /* a system image reused by the getimage mode */
    int img_ok;
    int img_w, img_h;
    int stats;
    uint64_t ns_send, ns_recv, ns_sync, ns_transfer, ns_copy, nframes, nbytes;
};

static uint64_t now_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
}


enum { DL_FFMPEG = 0, DL_GETIMAGE, DL_DERIVE, DL_DERIVE_SSE };

/* Copies rows of `rowbytes` bytes. `sse`: reading with non-temporal loads (movntdqa), the way to read
 * write-combining/video memory without going through the cache; it requires a 16-byte aligned source. */
__attribute__((target("sse4.1")))
static void copy_rows_sse(uint8_t *dst, size_t dpitch, const uint8_t *src, size_t spitch, size_t rowbytes,
                          int rows) {
    for (int y = 0; y < rows; y++) {
        const uint8_t *s = src + (size_t)y * spitch;
        uint8_t *d = dst + (size_t)y * dpitch;
        size_t x = 0;
        if ((((uintptr_t)s) & 15) == 0) {
            for (; x + 64 <= rowbytes; x += 64) {
                __m128i a = _mm_stream_load_si128((__m128i *)(s + x));
                __m128i b = _mm_stream_load_si128((__m128i *)(s + x + 16));
                __m128i c = _mm_stream_load_si128((__m128i *)(s + x + 32));
                __m128i e = _mm_stream_load_si128((__m128i *)(s + x + 48));
                _mm_storeu_si128((__m128i *)(d + x), a);
                _mm_storeu_si128((__m128i *)(d + x + 16), b);
                _mm_storeu_si128((__m128i *)(d + x + 32), c);
                _mm_storeu_si128((__m128i *)(d + x + 48), e);
            }
        }
        if (x < rowbytes) memcpy(d + x, s + x, rowbytes - x);
    }
}

static void copy_rows_plain(uint8_t *dst, size_t dpitch, const uint8_t *src, size_t spitch, size_t rowbytes,
                            int rows) {
    for (int y = 0; y < rows; y++) memcpy(dst + (size_t)y * dpitch, src + (size_t)y * spitch, rowbytes);
}

/* Downloads the surface into `dst`, already compact (NV12 or P010 without padding), with the direct VA-API API, without going through
 * av_hwframe_transfer_data. 0 = ok. */
static int va_download(HwDecSession *s, VADisplay dpy, VASurfaceID surf, enum AVPixelFormat swfmt, int w, int h,
                       uint8_t *dst) {
    const int p010 = swfmt == AV_PIX_FMT_P010LE;
    const size_t rowbytes = (size_t)w * (p010 ? 2 : 1);
    const int crows = (h + 1) / 2;
    VAImage tmp;
    VAImage *img = &s->img;
    VAStatus st;
    int derived = 0;

    if (s->dl_mode == DL_GETIMAGE) {
        if (!s->img_ok || s->img_w != w || s->img_h != h) {
            if (s->img_ok) vaDestroyImage(dpy, s->img.image_id);
            s->img_ok = 0;
            VAImageFormat fmt;
            memset(&fmt, 0, sizeof(fmt));
            fmt.fourcc = p010 ? VA_FOURCC_P010 : VA_FOURCC_NV12;
            fmt.byte_order = VA_LSB_FIRST;
            fmt.bits_per_pixel = p010 ? 24 : 12;
            st = vaCreateImage(dpy, &fmt, w, h, &s->img);
            if (st != VA_STATUS_SUCCESS) { fprintf(stderr, "hwdec: vaCreateImage: %s\n", vaErrorStr(st)); return -1; }
            s->img_ok = 1;
            s->img_w = w;
            s->img_h = h;
        }
        st = vaGetImage(dpy, surf, 0, 0, w, h, s->img.image_id);
        if (st != VA_STATUS_SUCCESS) { fprintf(stderr, "hwdec: vaGetImage: %s\n", vaErrorStr(st)); return -1; }
    } else {
        img = &tmp;
        st = vaDeriveImage(dpy, surf, img);
        if (st != VA_STATUS_SUCCESS) { fprintf(stderr, "hwdec: vaDeriveImage: %s\n", vaErrorStr(st)); return -1; }
        derived = 1;
    }
    void *p = NULL;
    st = vaMapBuffer(dpy, img->buf, &p);
    if (st != VA_STATUS_SUCCESS) {
        fprintf(stderr, "hwdec: vaMapBuffer: %s\n", vaErrorStr(st));
        if (derived) vaDestroyImage(dpy, img->image_id);
        return -1;
    }
    const uint8_t *base = p;
    uint8_t *dy = dst, *duv = dst + rowbytes * (size_t)h;
    if (s->dl_mode == DL_DERIVE_SSE) {
        copy_rows_sse(dy, rowbytes, base + img->offsets[0], img->pitches[0], rowbytes, h);
        copy_rows_sse(duv, rowbytes, base + img->offsets[1], img->pitches[1], rowbytes, crows);
    } else {
        copy_rows_plain(dy, rowbytes, base + img->offsets[0], img->pitches[0], rowbytes, h);
        copy_rows_plain(duv, rowbytes, base + img->offsets[1], img->pitches[1], rowbytes, crows);
    }
    vaUnmapBuffer(dpy, img->buf);
    if (derived) vaDestroyImage(dpy, img->image_id);
    return 0;
}

static enum AVPixelFormat pick_vaapi(AVCodecContext *ctx, const enum AVPixelFormat *fmts) {
    (void)ctx;
    for (const enum AVPixelFormat *p = fmts; *p != AV_PIX_FMT_NONE; p++)
        if (*p == AV_PIX_FMT_VAAPI) return *p;
    /* Without VAAPI there is no decode: it does NOT fall back to software silently. */
    return AV_PIX_FMT_NONE;
}

static void averr(const char *what, int err) {
    char b[128];
    av_strerror(err, b, sizeof(b));
    fprintf(stderr, "hwdec: %s: %s\n", what, b);
}

HwDecSession *hwdec_open(const char *drm_node, HwDecCodec codec) {
    HwDecCaps caps;
    if (hwdec_probe(drm_node, &caps) != 0) return NULL;
    if (codec < 0 || codec >= HWDEC_NCODECS || !caps.supported[codec]) {
        fprintf(stderr, "hwdec: this hardware does not decode %s (%s)\n", hwdec_codec_name(codec), caps.driver);
        return NULL;
    }
    const AVCodec *dec = avcodec_find_decoder(codec_id(codec));
    if (!dec) { fprintf(stderr, "hwdec: libavcodec has no decoder for %s\n", hwdec_codec_name(codec)); return NULL; }

    HwDecSession *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->codec = codec;
    s->stats = getenv("REDROID_FORGE_HWDEC_STATS") != NULL;
    {
        const char *dl = getenv("REDROID_FORGE_HWDEC_DOWNLOAD");
        s->dl_mode = !dl ? DL_DERIVE_SSE : !strcmp(dl, "getimage") ? DL_GETIMAGE : !strcmp(dl, "derive") ? DL_DERIVE
                   : !strcmp(dl, "ffmpeg") ? DL_FFMPEG : DL_DERIVE_SSE;
    }
    int r = av_hwdevice_ctx_create(&s->hw_dev, AV_HWDEVICE_TYPE_VAAPI, drm_node, NULL, 0);
    if (r < 0) { averr("av_hwdevice_ctx_create(VAAPI)", r); goto fail; }
    s->ctx = avcodec_alloc_context3(dec);
    if (!s->ctx) goto fail;
    s->ctx->hw_device_ctx = av_buffer_ref(s->hw_dev);
    s->ctx->get_format = pick_vaapi;
    s->ctx->thread_count = 1; /* the GPU does the heavy lifting */
    r = avcodec_open2(s->ctx, dec, NULL);
    if (r < 0) { averr("avcodec_open2", r); goto fail; }
    s->pkt = av_packet_alloc();
    s->frame = av_frame_alloc();
    s->sw = av_frame_alloc();
    if (!s->pkt || !s->frame || !s->sw) goto fail;
    return s;
fail:
    hwdec_close(s);
    return NULL;
}

int hwdec_send(HwDecSession *s, const uint8_t *data, size_t size, int64_t pts) {
    const uint64_t t0 = s->stats ? now_ns() : 0;
    av_packet_unref(s->pkt);
    int r = av_new_packet(s->pkt, (int)size);  /* adds the padding libavcodec requires */
    if (r < 0) return r;
    memcpy(s->pkt->data, data, size);
    s->pkt->pts = pts;
    s->pkt->dts = pts;
    r = avcodec_send_packet(s->ctx, s->pkt);
    if (s->stats) s->ns_send += now_ns() - t0;
    if (r == AVERROR(EAGAIN)) return HWDEC_AGAIN;
    if (r < 0) { averr("avcodec_send_packet", r); return r; }
    return HWDEC_OK;
}

int hwdec_send_eos(HwDecSession *s) {
    int r = avcodec_send_packet(s->ctx, NULL);
    if (r < 0 && r != AVERROR_EOF) { averr("send_eos", r); return r; }
    return HWDEC_OK;
}

int hwdec_receive(HwDecSession *s, HwDecFrame *out) {
    return hwdec_receive_to(s, out, NULL, 0);
}

int hwdec_receive_to(HwDecSession *s, HwDecFrame *out, uint8_t *dst, size_t dstcap) {
    av_frame_unref(s->frame);
    av_frame_unref(s->sw);
    uint64_t t0 = s->stats ? now_ns() : 0;
    int r = avcodec_receive_frame(s->ctx, s->frame);
    if (s->stats && r == 0) s->ns_recv += now_ns() - t0;
    if (r == AVERROR(EAGAIN)) return HWDEC_AGAIN;
    if (r == AVERROR_EOF) return HWDEC_EOF;
    if (r < 0) { averr("avcodec_receive_frame", r); return r; }

    if (s->frame->format != AV_PIX_FMT_VAAPI || !s->frame->hw_frames_ctx) {
        fprintf(stderr, "hwdec: the frame did NOT come from VA-API (format %d): it is rejected, there is no fallback to software\n",
                s->frame->format);
        return -1;
    }
    AVHWFramesContext *fc = (AVHWFramesContext *)s->frame->hw_frames_ctx->data;
    enum AVPixelFormat swfmt = fc->sw_format;  /* NV12 u P010 */
    if (swfmt != AV_PIX_FMT_NV12 && swfmt != AV_PIX_FMT_P010LE) {
        fprintf(stderr, "hwdec: surface format not supported yet: %s\n", av_get_pix_fmt_name(swfmt));
        return -1;
    }
    s->sw->format = swfmt;
    AVHWFramesContext *hfc = (AVHWFramesContext *)s->frame->hw_frames_ctx->data;
    AVVAAPIDeviceContext *vctx = hfc->device_ctx->hwctx;
    const VASurfaceID surf = (VASurfaceID)(uintptr_t)s->frame->data[3];
    if (s->stats) {
        /* Separates the wait for the GPU (decode is asynchronous) from the download to RAM. */
        t0 = now_ns();
        vaSyncSurface(vctx->display, surf);
        s->ns_sync += now_ns() - t0;
    }

    int w = s->frame->width, h = s->frame->height;
    int need = av_image_get_buffer_size(swfmt, w, h, 1);
    if (need < 0) return need;
    uint8_t *dstbuf;
    if (dst) {
        if ((size_t)need > dstcap) return HWDEC_NOSPACE;
        dstbuf = dst;
    } else {
        if ((size_t)need > s->cap) {
            uint8_t *nb = realloc(s->buf, need);
            if (!nb) return -1;
            s->buf = nb;
            s->cap = need;
        }
        dstbuf = s->buf;
    }
    if (s->dl_mode == DL_FFMPEG) {
        t0 = s->stats ? now_ns() : 0;
        r = av_hwframe_transfer_data(s->sw, s->frame, 0);
        if (s->stats) s->ns_transfer += now_ns() - t0;
        if (r < 0) { averr("av_hwframe_transfer_data", r); return r; }
        t0 = s->stats ? now_ns() : 0;
        r = av_image_copy_to_buffer(dstbuf, need, (const uint8_t *const *)s->sw->data, s->sw->linesize, swfmt, w, h, 1);
        if (s->stats) s->ns_copy += now_ns() - t0;
        if (r < 0) return r;
    } else {
        /* Direct download with VA-API: it downloads and compacts in a single step (it counts as "download"). */
        t0 = s->stats ? now_ns() : 0;
        r = va_download(s, vctx->display, surf, swfmt, w, h, dstbuf);
        if (s->stats) s->ns_transfer += now_ns() - t0;
        /* Self-check: the first frame of the session is also downloaded through ffmpeg and compared byte by byte.
         * If the direct download fails or differs (a driver with tiled surfaces, etc.), this session goes back to the
         * ffmpeg path, which is the reference one. */
        int ok = (r == 0);
        if (ok && !s->dl_checked) {
            s->dl_checked = 1;
            uint8_t *ref = malloc((size_t)need);
            int rr = ref ? av_hwframe_transfer_data(s->sw, s->frame, 0) : -1;
            if (rr >= 0)
                rr = av_image_copy_to_buffer(ref, need, (const uint8_t *const *)s->sw->data, s->sw->linesize,
                                             swfmt, w, h, 1);
            if (rr < 0 || memcmp(ref, dstbuf, (size_t)need) != 0) {
                fprintf(stderr, "hwdec: the direct download (%s) does not match ffmpeg's: ffmpeg is used\n",
                        s->dl_mode == DL_GETIMAGE ? "getimage" : s->dl_mode == DL_DERIVE ? "derive" : "derive-sse");
                ok = 0;
                if (rr >= 0) memcpy(dstbuf, ref, (size_t)need);
            }
            free(ref);
        }
        if (!ok) {
            fprintf(stderr, "hwdec: direct download not available: av_hwframe_transfer_data is used\n");
            s->dl_mode = DL_FFMPEG;
            r = av_hwframe_transfer_data(s->sw, s->frame, 0);
            if (r < 0) { averr("av_hwframe_transfer_data", r); return r; }
            r = av_image_copy_to_buffer(dstbuf, need, (const uint8_t *const *)s->sw->data, s->sw->linesize, swfmt, w, h, 1);
            if (r < 0) return r;
        }
    }
    if (s->stats) { s->nframes++; s->nbytes += (uint64_t)need; }
    out->width = w;
    out->height = h;
    out->is_10bit = (swfmt == AV_PIX_FMT_P010LE);
    out->pts = s->frame->pts;
    out->data = dstbuf;
    out->size = need;
    return HWDEC_OK;
}

void hwdec_flush(HwDecSession *s) {
    if (s && s->ctx) avcodec_flush_buffers(s->ctx);
}

void hwdec_close(HwDecSession *s) {
    if (!s) return;
    if (s->stats && s->nframes) {
        const double n = (double)s->nframes;
        fprintf(stderr,
                "hwdec-stats[%s,download=%s]: %llu frames, %.1f MB/frame | per frame (ms): send=%.2f receive=%.2f "
                "gpu_wait(decode)=%.2f download_GPU->RAM=%.2f compact_copy=%.2f\n",
                hwdec_codec_name(s->codec),
                s->dl_mode == DL_GETIMAGE ? "getimage" : s->dl_mode == DL_DERIVE ? "derive" : s->dl_mode == DL_DERIVE_SSE ? "derive-sse" : "ffmpeg",
                (unsigned long long)s->nframes, (double)s->nbytes / n / 1e6,
                (double)s->ns_send / n / 1e6, (double)s->ns_recv / n / 1e6, (double)s->ns_sync / n / 1e6,
                (double)s->ns_transfer / n / 1e6,
                (double)s->ns_copy / n / 1e6);
    }
    if (s->img_ok && s->hw_dev) {
        AVHWDeviceContext *dc = (AVHWDeviceContext *)s->hw_dev->data;
        vaDestroyImage(((AVVAAPIDeviceContext *)dc->hwctx)->display, s->img.image_id);
    }
    av_packet_free(&s->pkt);
    av_frame_free(&s->frame);
    av_frame_free(&s->sw);
    avcodec_free_context(&s->ctx);
    av_buffer_unref(&s->hw_dev);
    free(s->buf);
    free(s);
}
