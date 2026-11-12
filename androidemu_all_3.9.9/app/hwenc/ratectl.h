/*
 * Rate control for the H.264 encoder (CQP underneath): every frame is an IDR, or -- with the P-frame GOP of daemon.c --
 * an IDR every N frames and P frames in between.
 *
 * The hardware runs in constant-QP mode, so the bitrate the client asks for is reached by choosing
 * the QP of every frame. For intra frames the size follows S ~ C * 2^(-QP/6) (the quantizer step
 * doubles every 6 QP), where C is the "complexity" of the picture. After every frame C is
 * re-estimated from the real size; the QP of the next frame is the one that would make a frame of
 * that complexity fit its share of the budget. A leaky "debt" term (bytes sent above the budget,
 * decaying over about a second) corrects the drift when the estimate is off. The frame rate is not
 * needed: the budget of a frame is bitrate * (time since the previous frame), so variable-rate
 * sources (a screen that only produces frames when it changes) are handled the same way.
 *
 * Header-only and free of VA-API so it can be tested on its own (test/ratectl-test.c).
 */
#ifndef RATECTL_H
#define RATECTL_H

#include <math.h>
#include <stdint.h>

/* GOP with P frames: an IDR frame may use this many times the budget of a frame (the debt term does not count that
 * excess as debt, otherwise the P frames after every IDR would be starved), and a P frame is typically this fraction
 * of an intra frame of the same QP (only the starting estimate: it is measured). */
#define RC_IDR_BOOST 3.0
#define RC_P_RATIO 0.2

#define RC_QP_MIN 14
#define RC_QP_MAX 51
#define RC_QP_LEGACY 26      /* what the encoder used before it had rate control */
#define RC_MAX_QP_STEP 8     /* largest QP change between two consecutive frames */
#define RC_RESET_GAP_NS 1500000000LL

typedef struct {
    int valid;
    int gop;                 /* 1: IDR every N frames with P frames in between (an IDR gets RC_IDR_BOOST of the budget); 0: all-intra */
    uint32_t bitrate;        /* bits per second asked for by the client */
    uint32_t width, height;
    double complexity;       /* bytes * 2^(qp/6) of an intra frame, smoothed */
    double complexity_p;     /* the same for a P frame */
    double dt_est;           /* smoothed time between frames, seconds */
    double debt;             /* bytes sent above the budget (negative: below), decaying */
    int64_t last_ns;
    int qp;                  /* QP of the last frame */
} RateCtl;

static inline double rc_clamp(double v, double lo, double hi) { return v < lo ? lo : (v > hi ? hi : v); }

/* QP for the frame that is about to be encoded. bitrate == 0 means "the client did not say": the
 * encoder keeps its historical fixed QP. */
static inline int rc_next_qp_t(RateCtl *rc, int64_t now_ns, uint32_t bitrate, uint32_t w, uint32_t h, int is_idr) {
    if (bitrate == 0) { rc->valid = 0; return RC_QP_LEGACY; }
    if (!rc->valid || rc->bitrate != bitrate || rc->width != w || rc->height != h ||
        now_ns - rc->last_ns > RC_RESET_GAP_NS || now_ns < rc->last_ns) {
        rc->valid = 1;
        rc->bitrate = bitrate;
        rc->width = w;
        rc->height = h;
        /* Typical screen/video content at QP 26 is around 0.11 byte per pixel when intra coded. */
        rc->complexity = 0.11 * (double)w * (double)h * pow(2.0, RC_QP_LEGACY / 6.0);
        rc->complexity_p = RC_P_RATIO * rc->complexity;
        rc->dt_est = 1.0 / 30.0;
        rc->debt = 0;
        rc->qp = RC_QP_LEGACY;
    } else {
        double dt = rc_clamp((double)(now_ns - rc->last_ns) / 1e9, 1.0 / 240.0, 0.25);
        rc->dt_est = 0.8 * rc->dt_est + 0.2 * dt;
    }
    double bytes_per_sec = (double)bitrate / 8.0;
    double target = bytes_per_sec * rc->dt_est * ((rc->gop && is_idr) ? RC_IDR_BOOST : 1.0);
    /* The debt, measured in half seconds of budget, scales the target down (or up) by a factor of 2 per unit. */
    target *= pow(2.0, -rc_clamp(rc->debt / (bytes_per_sec * 0.5), -1.0, 2.0));
    if (target < 64) target = 64;
    int qp = (int)lround(6.0 * log2((is_idr ? rc->complexity : rc->complexity_p) / target));
    if (qp > rc->qp + RC_MAX_QP_STEP) qp = rc->qp + RC_MAX_QP_STEP;
    if (qp < rc->qp - RC_MAX_QP_STEP) qp = rc->qp - RC_MAX_QP_STEP;
    if (qp < RC_QP_MIN) qp = RC_QP_MIN;
    if (qp > RC_QP_MAX) qp = RC_QP_MAX;
    rc->qp = qp;
    return qp;
}

/* All-intra use (every frame an IDR): what the encoder did before the P frames. */
static inline int rc_next_qp(RateCtl *rc, int64_t now_ns, uint32_t bitrate, uint32_t w, uint32_t h) {
    return rc_next_qp_t(rc, now_ns, bitrate, w, h, 1);
}

/* Feeds back the real size of the frame that was encoded with `qp`. */
static inline void rc_frame_done_t(RateCtl *rc, int64_t now_ns, size_t bytes, int qp, int is_idr) {
    if (!rc->valid) return;
    double c = (double)bytes * pow(2.0, qp / 6.0);
    if (is_idr) rc->complexity = 0.5 * rc->complexity + 0.5 * c;
    else rc->complexity_p = 0.5 * rc->complexity_p + 0.5 * c;
    double elapsed = rc_clamp((double)(now_ns - rc->last_ns) / 1e9, 1.0 / 240.0, 0.25);
    if (rc->last_ns == 0) elapsed = rc->dt_est;
    double bytes_per_sec = (double)rc->bitrate / 8.0;
    rc->debt = rc->debt * exp(-elapsed) + ((double)bytes - bytes_per_sec * elapsed * ((rc->gop && is_idr) ? RC_IDR_BOOST : 1.0));
    rc->debt = rc_clamp(rc->debt, -bytes_per_sec * 0.5, bytes_per_sec * 2.0);
    rc->last_ns = now_ns;
}

static inline void rc_frame_done(RateCtl *rc, int64_t now_ns, size_t bytes, int qp) {
    rc_frame_done_t(rc, now_ns, bytes, qp, 1);
}

#endif
