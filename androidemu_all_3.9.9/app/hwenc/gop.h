/*
 * Which kind of frame the encoder produces next: the GOP policy. Header-only and free of VA-API so it can be tested on its own
 * (test/gop-test.c).
 *
 * The encoder used to make every frame an IDR (stateless: a request is one connection and one frame, with no identity of the
 * stream). With P frames each frame depends on the previous one OF ITS OWN STREAM, so the daemon has to know the stream. A request
 * carries none, but the process that sends it is known from the socket (SO_PEERCRED): every instance runs its own encoder service,
 * so (pid, width, height) identifies a stream without changing the protocol or the Android-side component.
 *
 * One stream at a time has the reference. If another stream (other pid) asks while this one is active, that frame is an IDR, which
 * is always correct (stateless); two streams interleaved therefore both get all-intra, never wrong references.
 *
 * A frame is an IDR when: P frames are disabled, there is no reference yet, the stream changed (pid, size), the stream paused for
 * longer than GOP_RESET_GAP_NS (a viewer may have attached in between), the GOP is full (a new viewer needs a key frame within
 * `period` frames), or the previous frame failed.
 */
#ifndef GOP_H
#define GOP_H

#include <stdint.h>
#include <sys/types.h>

#define GOP_DEFAULT_PERIOD 120          /* ~2 s at 60 fps */
#define GOP_RESET_GAP_NS 1500000000LL   /* the same pause that resets the rate control */
#define GOP_FRAME_NUM_BITS 4            /* log2_max_frame_num_minus4 = 0 in the SPS */

typedef struct {
    int have_ref;            /* the last frame was encoded and its reconstruction is the reference of the next one */
    pid_t pid;
    uint32_t width, height;
    int64_t last_ns;
    unsigned int since_idr;  /* frames since (and including) the last IDR */
    unsigned int frame_num;  /* frame_num of the last frame */
    int cur;                 /* index (0/1) of the reconstruction surface the last frame was written to */
} GopState;

typedef struct {
    int is_idr;
    unsigned int frame_num;  /* frame_num of the frame about to be encoded */
    int cur;                 /* reconstruction surface to write to */
    int ref;                 /* reconstruction surface to reference (P frames); -1 for an IDR */
    unsigned int poc;        /* picture order count (pic_order_cnt_type 2: 2 * frames since the IDR) */
    unsigned int ref_frame_num;
    unsigned int ref_poc;
} GopDecision;

/* `period` <= 1 or `intra_only`: every frame is an IDR (the old behaviour). */
static inline GopDecision gop_next(const GopState *g, pid_t pid, uint32_t w, uint32_t h, int64_t now_ns,
                                   unsigned int period, int intra_only) {
    GopDecision d = {0};
    int idr = intra_only || period <= 1 || !g->have_ref || g->pid != pid || g->width != w || g->height != h ||
              now_ns < g->last_ns || now_ns - g->last_ns > GOP_RESET_GAP_NS || g->since_idr >= period;
    d.is_idr = idr;
    d.cur = idr ? 0 : (g->cur ^ 1);
    d.ref = idr ? -1 : g->cur;
    d.frame_num = idr ? 0 : ((g->frame_num + 1) & ((1u << GOP_FRAME_NUM_BITS) - 1));
    d.poc = idr ? 0 : 2 * g->since_idr;
    d.ref_frame_num = idr ? 0 : g->frame_num;
    d.ref_poc = idr ? 0 : 2 * (g->since_idr - 1);
    return d;
}

/* The frame was encoded: it becomes the reference. */
static inline void gop_commit(GopState *g, const GopDecision *d, pid_t pid, uint32_t w, uint32_t h, int64_t now_ns) {
    g->have_ref = 1;
    g->pid = pid;
    g->width = w;
    g->height = h;
    g->last_ns = now_ns;
    g->since_idr = d->is_idr ? 1 : g->since_idr + 1;
    g->frame_num = d->frame_num;
    g->cur = d->cur;
}

/* The frame failed (or the resolution changed under it): the next one must be an IDR. */
static inline void gop_reset(GopState *g) { g->have_ref = 0; }

#endif
