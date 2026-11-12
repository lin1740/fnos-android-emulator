/*
 * Vendor-agnostic hardware decode (AMD/Intel via VA-API) with libavcodec.
 * Step 1 of the hwdecode goal (docs/ROADMAP.md, Phase 2, step 5).
 *
 * Principles (decided on 06/10/2026):
 *  - EVERYTHING the host's hardware offers is used in hardware: hwdec_probe()
 *    asks VA-API which codecs this GPU decodes, and hwdec_open() only opens
 *    sessions for those.
 *  - There is NEVER a silent fallback to software: if the hardware cannot handle
 *    the stream, hwdec_open()/hwdec_receive() fail, and the caller (Android's
 *    Codec2 component) decides to fall back to its software decoder.
 *  - One session = one stream, with state (references, B-frame reordering).
 *    Every hwdec_send() delivers ONE access unit; hwdec_receive() returns the
 *    already reordered frames, one at a time, when the decoder releases them.
 *
 * The frames are downloaded to CPU memory (compact NV12 / P010, no padding) and
 * handed over either inline or through shared memory (see protocol.h). Zero-copy
 * export (dma-buf), which 4K would need, is a future improvement (docs/ROADMAP.md).
 */
#ifndef REDROID_FORGE_HWDEC_H
#define REDROID_FORGE_HWDEC_H

#include <stddef.h>
#include <stdint.h>

typedef enum {
    HWDEC_H264 = 0,
    HWDEC_HEVC,
    HWDEC_VP9,
    HWDEC_VP8,
    HWDEC_MPEG2,
    HWDEC_VC1,
    HWDEC_AV1,
    HWDEC_NCODECS
} HwDecCodec;

enum { HWDEC_OK = 0, HWDEC_AGAIN = 1, HWDEC_EOF = 2 };  /* negative = error */
enum { HWDEC_NOSPACE = -1000 };  /* hwdec_receive_to: the frame does not fit in the given destination (it is lost) */

typedef struct {
    int supported[HWDEC_NCODECS];  /* the hardware decodes this codec (8 bits at least) */
    int supported_10bit[HWDEC_NCODECS]; /* it also decodes the 10-bit variant */
    char driver[160];              /* the VA-API driver string, informative only */
} HwDecCaps;

const char *hwdec_codec_name(HwDecCodec c);

/* Asks VA-API (without libavcodec) what the given DRM node decodes. 0 = ok. */
int hwdec_probe(const char *drm_node, HwDecCaps *caps);

typedef struct HwDecSession HwDecSession;

typedef struct {
    uint32_t width, height;
    int is_10bit;       /* 0: NV12 (8 bits), 1: P010 (10 bits in 16) */
    int64_t pts;        /* the pts of the input access unit that originated this frame */
    const uint8_t *data; /* compact NV12/P010; valid until the next call to hwdec_receive/close */
    size_t size;
} HwDecFrame;

/* NULL if the hardware does not support the codec or something fails (the reason goes to stderr). */
HwDecSession *hwdec_open(const char *drm_node, HwDecCodec codec);

/* One access unit. HWDEC_OK; HWDEC_AGAIN = drain with hwdec_receive() and retry; <0 error. */
int hwdec_send(HwDecSession *s, const uint8_t *data, size_t size, int64_t pts);

/* End of stream: afterwards keep calling hwdec_receive() until HWDEC_EOF. */
int hwdec_send_eos(HwDecSession *s);

/* HWDEC_OK (frame in *out), HWDEC_AGAIN (more input is needed), HWDEC_EOF, or <0. */
int hwdec_receive(HwDecSession *s, HwDecFrame *out);

/* The same, but the frame (compact NV12/P010) is written directly into `dst` (of `dstcap` bytes) instead of into
 * the session's internal buffer: out->data == dst. If it does not fit it returns HWDEC_NOSPACE (the frame is
 * lost). It is what allows delivering frames through shared memory without an intermediate copy. */
int hwdec_receive_to(HwDecSession *s, HwDecFrame *out, uint8_t *dst, size_t dstcap);

/* Discards references and pending output (seek / stream restart). */
void hwdec_flush(HwDecSession *s);

void hwdec_close(HwDecSession *s);

#endif
