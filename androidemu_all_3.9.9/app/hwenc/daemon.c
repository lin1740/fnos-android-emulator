/*
 * Tier 5.2: VA-API encode daemon.
 *
 * A persistent host-side (glibc) process that does real hardware H.264
 * encode on behalf of the Codec2 component that will eventually run inside
 * Android (bionic) -- see protocol.h for why this exists instead of a
 * native Android-side VA-API stack.
 *
 * The actual encode logic (packed SPS/PPS/slice headers, the VA-API call
 * sequence, the dma-buf import via VASurfaceAttribExternalBuffers) is the
 * same pipeline already proven end to end in tier2-vaapi-encode and
 * tier3-dmabuf-import -- this just wraps it in a socket server instead of
 * a one-shot CLI tool, and imports whatever dma-buf a client hands it
 * instead of allocating/filling one itself.
 */

/* struct ucred (SO_PEERCRED: which process is on the other end of a connection) needs this before any include. */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>

#include <va/va.h>
#include <va/va_drm.h>
#include <va/va_drmcommon.h>
#include <va/va_enc_h264.h>
#include <va/va_vpp.h>
/* Depending on the Alpine/Debian version, libdrm-dev puts drm_fourcc.h in <drm/...> (Alpine 3.24,
 * Debian), only in <libdrm/...> (Alpine 3.23), or both: all cases are covered (with the -I that the
 * Makefile adds from pkg-config). Confirmed on 06/10/2026: server01 had an alpine:latest 3.23 image
 * cached and the build failed there, while on 3.24 it compiled. */
#if __has_include(<drm/drm_fourcc.h>)
#include <drm/drm_fourcc.h>
#else
#include <drm_fourcc.h>
#endif

#include <gbm.h>
#define EGL_EGLEXT_PROTOTYPES
#include <EGL/egl.h>
#include <EGL/eglext.h>

#include "protocol.h"
#include "decode_h264.h"
#include "ratectl.h"
#include "gop.h"

#ifdef HAVE_HWDEC
#include <pthread.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include "hwdec.h"
#include "ffmpeg_encode.h"
#endif

#define DRM_RENDER_DEVICE "/dev/dri/renderD128"

#define CHECK_VA(status, msg)                                                \
    do {                                                                     \
        if ((status) != VA_STATUS_SUCCESS) {                                 \
            fprintf(stderr, "%s failed: %s (0x%x)\n", (msg),                 \
                    vaErrorStr(status), (status));                           \
            return -1;                                                      \
        }                                                                    \
    } while (0)

static unsigned int align16(unsigned int v) { return (v + 15) & ~15u; }

/* ------------------------------------------------------------------ *
 * Same bitstream writer as tier2-vaapi-encode/main.c -- see that file
 * for the detailed spec-reference comments on each field. Kept terse
 * here since this daemon's own comments focus on what's new (the socket
 * protocol and per-request dma-buf import), not re-deriving H.264 syntax.
 * ------------------------------------------------------------------ */
typedef struct {
    unsigned char *buf;
    size_t capacity;
    size_t bit_pos;
} bitstream_t;

static void bs_init(bitstream_t *bs) {
    bs->capacity = 256;
    bs->buf = calloc(1, bs->capacity);
    bs->bit_pos = 0;
}

static void bs_grow_if_needed(bitstream_t *bs, size_t extra_bits) {
    size_t needed_bytes = (bs->bit_pos + extra_bits + 7) / 8;
    if (needed_bytes <= bs->capacity) return;
    while (needed_bytes > bs->capacity) bs->capacity *= 2;
    bs->buf = realloc(bs->buf, bs->capacity);
}

static void bs_put_bit(bitstream_t *bs, unsigned int bit) {
    bs_grow_if_needed(bs, 1);
    size_t byte_i = bs->bit_pos / 8;
    int shift = 7 - (bs->bit_pos % 8);
    if (bit) bs->buf[byte_i] |= (1u << shift);
    bs->bit_pos++;
}

static void bs_put_bits(bitstream_t *bs, unsigned int value, int n) {
    for (int i = n - 1; i >= 0; i--) bs_put_bit(bs, (value >> i) & 1);
}

static void bs_put_ue(bitstream_t *bs, unsigned int val) {
    unsigned int code_num = val + 1;
    int bits = 0;
    for (unsigned int tmp = code_num; tmp; tmp >>= 1) bits++;
    bs_put_bits(bs, 0, bits - 1);
    bs_put_bits(bs, code_num, bits);
}

static void bs_put_se(bitstream_t *bs, int val) {
    unsigned int mapped = (val <= 0) ? (unsigned int)(-2 * val)
                                      : (unsigned int)(2 * val - 1);
    bs_put_ue(bs, mapped);
}

static void bs_rbsp_trailing_bits(bitstream_t *bs) {
    bs_put_bit(bs, 1);
    while (bs->bit_pos % 8) bs_put_bit(bs, 0);
}

static void bs_start_code_and_nal_header(bitstream_t *bs, int nal_ref_idc, int nal_unit_type) {
    bs_put_bits(bs, 0x000001, 24);
    bs_put_bit(bs, 0);
    bs_put_bits(bs, nal_ref_idc, 2);
    bs_put_bits(bs, nal_unit_type, 5);
}

static void build_sps_rbsp(bitstream_t *bs, const VAEncSequenceParameterBufferH264 *seq) {
    bs_start_code_and_nal_header(bs, 3, 7);
    bs_put_bits(bs, 66, 8);
    bs_put_bit(bs, 1);
    bs_put_bit(bs, 1);
    bs_put_bit(bs, 0);
    bs_put_bit(bs, 0);
    bs_put_bits(bs, 0, 4);
    bs_put_bits(bs, seq->level_idc, 8);
    bs_put_ue(bs, seq->seq_parameter_set_id);
    bs_put_ue(bs, seq->seq_fields.bits.log2_max_frame_num_minus4);
    bs_put_ue(bs, seq->seq_fields.bits.pic_order_cnt_type);
    bs_put_ue(bs, seq->max_num_ref_frames);
    bs_put_bit(bs, 0);
    bs_put_ue(bs, seq->picture_width_in_mbs - 1);
    bs_put_ue(bs, seq->picture_height_in_mbs - 1);
    bs_put_bit(bs, seq->seq_fields.bits.frame_mbs_only_flag);
    bs_put_bit(bs, 1);
    bs_put_bit(bs, seq->frame_cropping_flag);
    if (seq->frame_cropping_flag) {
        bs_put_ue(bs, seq->frame_crop_left_offset);
        bs_put_ue(bs, seq->frame_crop_right_offset);
        bs_put_ue(bs, seq->frame_crop_top_offset);
        bs_put_ue(bs, seq->frame_crop_bottom_offset);
    }
    /* vui_parameters_present_flag. Reverted (30/10/2026): tried declaring the VUI colour matrix
     * explicitly (first BT.601 to match convert_rgba_to_nv12's conversion, then BT.709 to test
     * whether scrcpy's renderer ignores VUI and assumes a fixed matrix instead) -- neither
     * version changed the washed-out picture reported live against cifi-nuevo-nuevo on
     * jgustavo46, so colour matrix is being ruled out as the cause for now, isolated back out to
     * retest the GOP/P-frames angle (REDROID_FORGE_ENCODE_IDR_PERIOD) on its own. Revisit if that
     * doesn't fix it either -- the two VUI attempts are recoverable from git history/this comment
     * if colour needs a second look. Deliberately NOT calling bs_rbsp_trailing_bits(bs) here:
     * adding it (30/10/2026, same session) broke scrcpy's own SPS parsing for recording
     * ("Failed to write header", reproducible on a warm daemon, not a cold-start race) even
     * though the live --no-window path and the confirmed-working P-frames test both predate that
     * change. Root cause not investigated -- reverted to match the exact bitstream the user
     * already validated live (8Mbps and 1Mbps, both "perfecto") rather than chase it further
     * live. Investigate bs_rbsp_trailing_bits() / how this RBSP's bit length is used downstream
     * before trying this again. */
    bs_put_bit(bs, 0);
}

static void build_pps_rbsp(bitstream_t *bs, const VAEncPictureParameterBufferH264 *pic) {
    bs_start_code_and_nal_header(bs, 3, 8);
    bs_put_ue(bs, pic->pic_parameter_set_id);
    bs_put_ue(bs, pic->seq_parameter_set_id);
    bs_put_bit(bs, pic->pic_fields.bits.entropy_coding_mode_flag);
    bs_put_bit(bs, 0);
    bs_put_ue(bs, 0);
    bs_put_ue(bs, pic->num_ref_idx_l0_active_minus1);
    bs_put_ue(bs, 0);
    bs_put_bit(bs, 0);
    bs_put_bits(bs, 0, 2);
    bs_put_se(bs, pic->pic_init_qp - 26);
    bs_put_se(bs, 0);
    bs_put_se(bs, 0);
    bs_put_bit(bs, pic->pic_fields.bits.deblocking_filter_control_present_flag);
    bs_put_bit(bs, 0);
    bs_put_bit(bs, 0);
    bs_rbsp_trailing_bits(bs);
}

static void build_slice_header_bits(bitstream_t *bs,
                                     const VAEncSequenceParameterBufferH264 *seq,
                                     const VAEncPictureParameterBufferH264 *pic,
                                     const VAEncSliceParameterBufferH264 *slice) {
    const int is_idr = pic->pic_fields.bits.idr_pic_flag;
    /* IDR: nal_unit_type 5. P frame: nal_unit_type 1 and nal_ref_idc != 0 (the next frame references it). */
    bs_start_code_and_nal_header(bs, is_idr ? 3 : 2, is_idr ? 5 : 1);
    bs_put_ue(bs, slice->macroblock_address);
    bs_put_ue(bs, slice->slice_type);
    bs_put_ue(bs, slice->pic_parameter_set_id);
    bs_put_bits(bs, pic->frame_num,
                seq->seq_fields.bits.log2_max_frame_num_minus4 + 4);
    if (is_idr) {
        bs_put_ue(bs, slice->idr_pic_id);
        bs_put_bit(bs, 0);  /* no_output_of_prior_pics_flag */
        bs_put_bit(bs, 0);  /* long_term_reference_flag */
    } else {
        bs_put_bit(bs, 0);  /* num_ref_idx_active_override_flag: the PPS default (1 reference) */
        bs_put_bit(bs, 0);  /* ref_pic_list_modification_flag_l0 */
        bs_put_bit(bs, 0);  /* adaptive_ref_pic_marking_mode_flag: sliding window */
        if (pic->pic_fields.bits.entropy_coding_mode_flag) bs_put_ue(bs, 0);  /* cabac_init_idc */
    }
    bs_put_se(bs, slice->slice_qp_delta);
    if (pic->pic_fields.bits.deblocking_filter_control_present_flag) {
        bs_put_ue(bs, slice->disable_deblocking_filter_idc);
        if (slice->disable_deblocking_filter_idc != 1) {
            bs_put_se(bs, 0);
            bs_put_se(bs, 0);
        }
    }
}

static void submit_packed_header(VADisplay dpy, VAContextID context_id,
                                  VAEncPackedHeaderType type, bitstream_t *bs,
                                  VABufferID *out_param_buf, VABufferID *out_data_buf) {
    VAEncPackedHeaderParameterBuffer param = {0};
    param.type = type;
    param.bit_length = (unsigned int)bs->bit_pos;
    param.has_emulation_bytes = 0;
    vaCreateBuffer(dpy, context_id, VAEncPackedHeaderParameterBufferType,
                   sizeof(param), 1, &param, out_param_buf);
    vaCreateBuffer(dpy, context_id, VAEncPackedHeaderDataBufferType,
                   (bs->bit_pos + 7) / 8, 1, bs->buf, out_data_buf);
}

/* ------------------------------------------------------------------ *
 * Persistent VA-API state, initialized once at daemon startup and reused
 * across requests. Config/context are sized to a specific resolution;
 * encode_one_frame() recreates them if a request's resolution changes.
 * ------------------------------------------------------------------ */
typedef struct {
    int drm_fd;
    VADisplay dpy;
    VAEntrypoint entrypoint;
    VAConfigID config_id;
    VAContextID context_id;
    /* Tier 5.8: a real Surface-sourced frame is RGBA, not NV12 (Tier 5.7's
     * closing finding) -- this driver's own VAEntrypointVideoProc (VPP)
     * pipeline does the RGBA->NV12 conversion entirely on the GPU (queried
     * capable of both surface types simultaneously; confirmed via a
     * standalone probe before writing any of this). [0] = imported RGBA
     * input (recreated per request, since it wraps a different dma-buf
     * every time), [1] = recon, [2] = VPP's NV12 output / the encode's
     * actual source surface (created once per resolution, reused/
     * overwritten every request -- VPP replaces its content, no need to
     * destroy and recreate like the imported surface). */
    VASurfaceID surfaces[3];
    VAConfigID vpp_config_id;
    VAContextID vpp_context_id;
    unsigned int width, height;
    int have_context;
    /* Every frame of this encoder is an IDR, and the standard requires two consecutive IDR pictures to carry
     * a different idr_pic_id (7.4.3): a counter, modulo its 16-bit range. Written as 0 in every frame it made
     * recent ffmpeg warn "idr_pic_id is invalid" on each one (found with scrcpy, 10/2026). */
    unsigned int idr_pic_id;
    /* P frames (gop.h): the two reconstruction surfaces that the frames alternate between (the previous one is the
     * reference of the next), and the state of the stream that holds the reference. */
    VASurfaceID recon[2];
    GopState gop;
    /* Tier 5.9: the real DRM format modifier a GPU-render-target RGBA
     * buffer ends up with is GPU-generation-specific (confirmed: differs
     * between a Renoir/GFX9 APU and a Polaris/GFX8 discrete card) and can't
     * be read off the buffer itself on this Android build (see DEVLOG) --
     * determined once at startup instead, per host GPU, so a new machine
     * only ever needs this daemon rebuilt (a local `gcc`, seconds) and never
     * the Android-side component (an AOSP rebuild, tied to a single build
     * host). See rgba_modifier_init() for how. */
    uint64_t rgba_modifier;
    /* Tier 5.10 finding, Tier 5.12 fix: some GPUs (confirmed: Polaris/GFX8)
     * report *zero* DRM format modifiers for a GPU-render-target RGBA
     * buffer at all -- there is no modifier value that describes their
     * tiling, because minigbm falls back to Mesa-opaque, non-modifier
     * tiling (TILE_TYPE_DRI) for that combination. DRM_PRIME_2
     * fundamentally cannot import a buffer like that. Tier 5.10 tried
     * bridging via GL (import through EGL's plain, non-modifier extension,
     * then GPU-blit into a fresh explicitly-linear buffer) -- confirmed
     * working only when the same process both allocates and re-imports the
     * buffer, which is a Mesa same-process shortcut, not real cross-process
     * opaque-tiling resolution; failed for the actual (cross-process) case.
     * Tier 5.12 found the real fix instead: VA-API's own *old*, pre-
     * modifier import (VASurfaceAttribExternalBuffers /
     * VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME) resolves this GPU's opaque
     * tiling correctly even across processes -- unlike EGL's equivalent,
     * apparently because libva's import machinery is built around
     * cross-process IPC as the normal case to begin with. use_legacy_prime,
     * set once at startup, means encode_one_frame() takes that import path
     * for this GPU's requests instead of DRM_PRIME_2. */
    int use_legacy_prime;
} vaapi_state_t;

/* Tier 5.9: reproduces minigbm's own tie-break for which tiling a
 * GPU-render-target RGBA buffer gets (amdgpu.c's amdgpu_add_kms_item():
 * one combination per modifier Mesa reports via dri_query_modifiers(), all
 * at equal priority; drv.c's drv_get_combination() keeps whichever combo
 * was registered *first* on a priority tie) -- by asking Mesa for that same
 * ordering directly via EGL and taking its first answer, instead of relying
 * on a value hardcoded for one specific GPU generation.
 *
 * Needs AMD_DEBUG=nodcc set (main() does this, before any Mesa entry point
 * runs -- Mesa parses its debug env vars once per process and caches them,
 * so setenv() here would be too late: confirmed the hard way, calling it at
 * the top of this function still queried under the process's original
 * environment). surfaceflinger gets the same env var exported to it at
 * boot (see redroid-nodcc.rc) so the real buffer's allocation never picks
 * a DCC-compressed tiling at all (VCN can't encode from those, confirmed
 * in Tier 5.7) -- without nodcc here too, this queries 8 modifiers instead
 * of 4 and the first one has DCC=1: a decision the real allocation was
 * never actually given the chance to make.
 *
 * Tier 5.10 finding, Tier 5.12 fix: zero modifiers reported doesn't mean
 * LINEAR here -- it means this GPU can't describe its render-target tiling
 * as a modifier at all (confirmed: Polaris/GFX8). Sets st->use_legacy_prime
 * in that case instead of silently assuming LINEAR (which produced
 * "resource allocation failed" -- a genuinely-linear buffer at the
 * identical stride imports fine, proving the real buffer just isn't
 * linear); encode_one_frame() then imports via the old, pre-modifier
 * VA-API path instead of DRM_PRIME_2 for this GPU (see its own comment).
 *
 * Deliberately self-contained (creates and destroys its own throwaway
 * GBM/EGL, using st->drm_fd) rather than keeping any of it around --
 * confirmed the hard way, during the Tier 5.10 GL-bridge attempt that
 * later got removed, that *any* longer-lived GBM/EGL object in this
 * process, even on a GPU that never touches it again, disturbed VA-API's
 * own unrelated dma-buf import. A query-and-destroy right here, before
 * VA-API has imported anything for real yet, doesn't have that problem.
 *
 * Tier 5.11: "index 0 wins" is an AMD-specific fact, not a general one --
 * confirmed on Intel (TigerLake/gen12, iHD driver): the real buffer came
 * out visually corrupted (tiled-as-linear striping) despite this exact
 * function reporting modifier[0] = DRM_FORMAT_MOD_LINEAR and the import
 * succeeding without error. Read minigbm's *other* backend, i915.c, to
 * understand why: unlike amdgpu.c (one combination per modifier, all at
 * equal priority, so registration order -- which matches this query's
 * order -- decides ties), i915.c registers LINEAR at explicit priority 1
 * and X/Y/4-tiled at explicit priority 2/3 for the *same* render+encoder
 * usage whenever the request has no SW/CPU-read/write usage bits (which
 * ours never does) -- and drv_get_combination() always keeps the highest
 * priority match. Tiled beats linear on Intel, unconditionally, for this
 * usage class. Confirmed by comparing the reported modifier list against
 * i915.c's I915_FORMAT_MOD_Y_TILED constant -- present, and exactly what
 * minigbm's priority rule would pick for this GPU generation (not MTL+,
 * which prefers 4-tiled instead; not handled here since no such GPU has
 * been tested yet). Detected via the VA-API vendor string rather than by
 * driver library name, since that's already queried at daemon startup
 * for logging and reliably distinguishes Intel from AMD/other vendors. */
static uint64_t rgba_modifier_init(vaapi_state_t *st) {
    uint64_t fallback = DRM_FORMAT_MOD_LINEAR;
    struct gbm_device *gbm = gbm_create_device(st->drm_fd);
    if (!gbm) {
        fprintf(stderr, "rgba_modifier_init: gbm_create_device failed, assuming LINEAR\n");
        return fallback;
    }
    EGLDisplay dpy = eglGetPlatformDisplay(EGL_PLATFORM_GBM_KHR, gbm, NULL);
    EGLint major, minor;
    if (dpy == EGL_NO_DISPLAY || !eglInitialize(dpy, &major, &minor)) {
        fprintf(stderr, "rgba_modifier_init: eglInitialize failed, assuming LINEAR\n");
        gbm_device_destroy(gbm);
        return fallback;
    }
    PFNEGLQUERYDMABUFMODIFIERSEXTPROC queryMods =
        (PFNEGLQUERYDMABUFMODIFIERSEXTPROC)eglGetProcAddress("eglQueryDmaBufModifiersEXT");
    EGLint num_mods = 0;
    if (!queryMods || !queryMods(dpy, DRM_FORMAT_ABGR8888, 0, NULL, NULL, &num_mods) ||
        num_mods == 0) {
        fprintf(stderr,
                "rgba_modifier_init: no modifiers reported for this GPU -- opaque tiling, "
                "using the old pre-modifier VA-API import path instead\n");
        st->use_legacy_prime = 1;
        gbm_device_destroy(gbm);
        return fallback;
    }
    EGLuint64KHR *mods = malloc(num_mods * sizeof(EGLuint64KHR));
    EGLBoolean *external = malloc(num_mods * sizeof(EGLBoolean));
    queryMods(dpy, DRM_FORMAT_ABGR8888, num_mods, mods, external, &num_mods);

    uint64_t chosen = mods[0];
    const char *vendor = vaQueryVendorString(st->dpy);
    if (vendor && strstr(vendor, "Intel")) {
        /* I915_FORMAT_MOD_Y_TILED / X_TILED (fourcc_mod_code(INTEL, 2/1)) --
         * not including drm_fourcc.h's i915-specific header here (kernel
         * UAPI header, not always present), just the two known numeric
         * values, per the priority rule above. */
        const uint64_t y_tiled = 0x0100000000000002ULL;
        const uint64_t x_tiled = 0x0100000000000001ULL;
        int found = 0;
        for (int i = 0; i < num_mods && !found; i++) {
            if (mods[i] == y_tiled) {
                chosen = y_tiled;
                found = 1;
            }
        }
        for (int i = 0; i < num_mods && !found; i++) {
            if (mods[i] == x_tiled) {
                chosen = x_tiled;
                found = 1;
            }
        }
        fprintf(stderr, "rgba_modifier_init: Intel GPU, preferring tiled over linear -> %s\n",
                found ? (chosen == y_tiled ? "Y_TILED" : "X_TILED") : "none found, using index 0");
    }

    fprintf(stderr, "rgba_modifier_init: %d modifiers for ABGR8888, using: 0x%016llx\n", num_mods,
            (unsigned long long)chosen);
    free(mods);
    free(external);
    gbm_device_destroy(gbm);
    return chosen;
}

static int vaapi_state_init(vaapi_state_t *st) {
    memset(st, 0, sizeof(*st));
    st->drm_fd = open(DRM_RENDER_DEVICE, O_RDWR);
    if (st->drm_fd < 0) {
        perror("open " DRM_RENDER_DEVICE);
        return -1;
    }
    st->dpy = vaGetDisplayDRM(st->drm_fd);
    if (!st->dpy) {
        fprintf(stderr, "vaGetDisplayDRM failed\n");
        return -1;
    }
    int major, minor;
    CHECK_VA(vaInitialize(st->dpy, &major, &minor), "vaInitialize");
    fprintf(stderr, "VA-API %d.%d, driver: %s\n", major, minor,
            vaQueryVendorString(st->dpy));

    st->rgba_modifier = rgba_modifier_init(st);
    if (st->use_legacy_prime) {
        fprintf(stderr,
                "This GPU can't describe its RGBA render-target tiling as a DRM modifier -- "
                "using the old, pre-modifier VA-API import path for it instead (see DEVLOG "
                "Tier 5.12).\n");
    }

    int num_entrypoints = vaMaxNumEntrypoints(st->dpy);
    VAEntrypoint *entrypoints = malloc(num_entrypoints * sizeof(VAEntrypoint));
    int n = 0;
    CHECK_VA(vaQueryConfigEntrypoints(st->dpy, VAProfileH264ConstrainedBaseline,
                                       entrypoints, &n),
             "vaQueryConfigEntrypoints");
    st->entrypoint = (VAEntrypoint)-1;
    for (int i = 0; i < n; i++) {
        if (entrypoints[i] == VAEntrypointEncSlice || entrypoints[i] == VAEntrypointEncSliceLP) {
            st->entrypoint = entrypoints[i];
            break;
        }
    }
    free(entrypoints);
    if (st->entrypoint == (VAEntrypoint)-1) {
        fprintf(stderr, "No H.264 encode entrypoint on this GPU\n");
        return -1;
    }
    fprintf(stderr, "Using entrypoint %s\n",
            st->entrypoint == VAEntrypointEncSlice ? "VAEntrypointEncSlice" : "VAEntrypointEncSliceLP");

    /* Constant QP on purpose: ratectl.h picks the QP of every frame, so the driver must not run its own
     * rate control (asked for explicitly when the driver advertises it; otherwise CQP is the default). */
    VAConfigAttrib attrib[2] = {{.type = VAConfigAttribRTFormat, .value = VA_RT_FORMAT_YUV420},
                                {.type = VAConfigAttribRateControl}};
    int nattrib = 1;
    vaGetConfigAttributes(st->dpy, VAProfileH264ConstrainedBaseline, st->entrypoint, &attrib[1], 1);
    if (attrib[1].value != VA_ATTRIB_NOT_SUPPORTED && (attrib[1].value & VA_RC_CQP)) {
        attrib[1].value = VA_RC_CQP;
        nattrib = 2;
    }
    CHECK_VA(vaCreateConfig(st->dpy, VAProfileH264ConstrainedBaseline, st->entrypoint,
                             attrib, nattrib, &st->config_id),
             "vaCreateConfig");

    /* VPP config for the RGBA->NV12 conversion stage (Tier 5.8). No RT
     * format restriction needed here -- confirmed via a standalone probe
     * that this driver's VPP surface attributes already list both RGBA-
     * family and YUV-family pixel formats for VAProfileNone/VideoProc. */
    CHECK_VA(vaCreateConfig(st->dpy, VAProfileNone, VAEntrypointVideoProc, NULL, 0,
                             &st->vpp_config_id),
             "vaCreateConfig(VideoProc)");

    st->have_context = 0;
    return 0;
}

/* (Re)creates the context + recon surface for a new resolution. The
 * imported input surface (surfaces[0]) is created fresh per request
 * regardless, since it wraps a different dma-buf every time. */
static int vaapi_state_ensure_resolution(vaapi_state_t *st, unsigned int width, unsigned int height) {
    if (st->have_context && st->width == width && st->height == height) return 0;
    if (st->have_context) {
        vaDestroyContext(st->dpy, st->context_id);
        vaDestroyContext(st->dpy, st->vpp_context_id);
        vaDestroySurfaces(st->dpy, st->recon, 2);
        vaDestroySurfaces(st->dpy, &st->surfaces[2], 1);
        st->have_context = 0;
    }
    gop_reset(&st->gop);  /* a new context has no reference */
    CHECK_VA(vaCreateSurfaces(st->dpy, VA_RT_FORMAT_YUV420, width, height,
                               st->recon, 2, NULL, 0),
             "vaCreateSurfaces(recon)");
    CHECK_VA(vaCreateContext(st->dpy, st->config_id, width, height, VA_PROGRESSIVE,
                              st->recon, 2, &st->context_id),
             "vaCreateContext");

    /* Tier 5.8: the NV12 surface VPP converts into and the encode context
     * then reads from directly -- allocated internally by the driver
     * (vaCreateSurfaces with no import attribs), so unlike the RGBA input
     * there's no gralloc tiling/modifier to worry about here at all. */
    CHECK_VA(vaCreateSurfaces(st->dpy, VA_RT_FORMAT_YUV420, width, height,
                               &st->surfaces[2], 1, NULL, 0),
             "vaCreateSurfaces(vpp-nv12)");
    CHECK_VA(vaCreateContext(st->dpy, st->vpp_config_id, width, height, VA_PROGRESSIVE,
                              &st->surfaces[2], 1, &st->vpp_context_id),
             "vaCreateContext(VideoProc)");

    st->width = width;
    st->height = height;
    st->have_context = 1;
    return 0;
}

/* Tier 5.8: converts the imported RGBA surface into st->surfaces[2] (NV12)
 * entirely on the GPU via VA-API's video post-processing pipeline -- the
 * only VA-API mechanism this driver offers for turning what
 * GraphicBufferSource actually hands the encoder (RGBA; see DEVLOG for why
 * getting real YUV out of GraphicBufferSource itself isn't viable on this
 * Mesa/minigbm stack) into something VCN's encode block can read at all. */
static int convert_rgba_to_nv12(vaapi_state_t *st, VASurfaceID rgba_surface,
                                 unsigned int width, unsigned int height) {
    VARectangle region = {.x = 0, .y = 0, .width = (short)width, .height = (short)height};

    VAProcPipelineParameterBuffer pipeline_param = {0};
    pipeline_param.surface = rgba_surface;
    pipeline_param.surface_region = &region;
    pipeline_param.output_region = &region;
    pipeline_param.surface_color_standard = VAProcColorStandardNone;
    /* Reverted to BT601 (30/10/2026): neither this nor a BT709 + matching VUI attempt changed the
     * washed-out picture reported live against cifi-nuevo-nuevo on jgustavo46 -- see
     * build_sps_rbsp's comment. Colour matrix ruled out for now; isolating the GOP/P-frames
     * angle next. */
    pipeline_param.output_color_standard = VAProcColorStandardBT601;

    VABufferID pipeline_buf;
    CHECK_VA(vaCreateBuffer(st->dpy, st->vpp_context_id, VAProcPipelineParameterBufferType,
                             sizeof(pipeline_param), 1, &pipeline_param, &pipeline_buf),
             "vaCreateBuffer(vpp-pipeline)");

    CHECK_VA(vaBeginPicture(st->dpy, st->vpp_context_id, st->surfaces[2]), "vaBeginPicture(vpp)");
    CHECK_VA(vaRenderPicture(st->dpy, st->vpp_context_id, &pipeline_buf, 1), "vaRenderPicture(vpp)");
    CHECK_VA(vaEndPicture(st->dpy, st->vpp_context_id), "vaEndPicture(vpp)");
    CHECK_VA(vaSyncSurface(st->dpy, st->surfaces[2]), "vaSyncSurface(vpp)");

    vaDestroyBuffer(st->dpy, pipeline_buf);
    return 0;
}

/* Normalizes ALL the Annex-B start codes of a bitstream to 4 bytes
 * (00 00 00 01). It is needed because the Intel driver (iHD) emits 3-byte start codes
 * (00 00 01) and radeonsi 4-byte ones: the CSD parser of MPEG4Writer (used by screenrecord
 * and by the MP4 muxer of scrcpy) requires 4 bytes and aborts with
 * "FORTIFY: write: count 18446744073709551615 > SSIZE_MAX" if it receives 3 --
 * confirmed live on 05/10/2026 on an Iris Xe (n02), while the raw
 * stream (--output-format=h264) decoded perfectly. It is safe to do it
 * over the whole buffer: by the emulation-prevention rules, the sequence
 * 00 00 01 cannot appear inside a NAL payload, so every
 * occurrence is a start code. A 00 00 01 already preceded by 00 is left as
 * it is (it is already 4 bytes, or it carries trailing_zero_8bits).
 * Returns a new buffer (malloc) and frees `in`. */
static unsigned char *normalize_start_codes(unsigned char *in, size_t n, size_t *out_n) {
    size_t cap = n + n / 3 + 4;
    unsigned char *out = malloc(cap);
    if (!out) { *out_n = n; return in; }
    size_t o = 0;
    for (size_t i = 0; i < n; i++) {
        if (i + 2 < n && in[i] == 0 && in[i + 1] == 0 && in[i + 2] == 1
            && (i == 0 || in[i - 1] != 0)) {
            out[o++] = 0;
        }
        out[o++] = in[i];
    }
    free(in);
    *out_n = o;
    return out;
}

/* Imports the client's dma-buf as surfaces[0], runs the same encode
 * sequence tier2/tier3 already proved, and returns malloc'd Annex-B H.264
 * bytes (caller frees). Returns byte count, or -1 on error. */
static RateCtl g_rate_ctl;  /* encode requests are served one at a time */

static int64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

/* REDROID_FORGE_ENCODE_BACKEND=ffmpeg (default: legacy, the hand-rolled bitstream writer below) --
 * read once at startup in main(), before the first request. See ffmpeg_encode.h/.c: a libavcodec
 * h264_vaapi encoder sharing the same RGBA->NV12 VPP step but replacing SPS/PPS/slice-header
 * construction and the vaRenderPicture sequence entirely, to get past the Intel P-frame corruption
 * below without having to keep bisecting the hand-rolled bitstream writer itself. */
#ifdef HAVE_HWDEC
static FFmpegEncState *g_ffmpeg_enc;
#endif
static int g_backend_is_ffmpeg;

/* P frames (gop.h): off unless REDROID_FORGE_ENCODE_IDR_PERIOD > 1 (frames per IDR; 120 is about 2 s at 60 fps). Until it has been
 * validated on every GPU the default stays the old all-intra encoder. REDROID_FORGE_ENCODE_INTRA_ONLY=1 forces it either way. */
static unsigned int g_gop_period = 1;
static int g_gop_intra_only = 1;
static void gop_config_init(const vaapi_state_t *st) {
    static int done;
    if (done) return;
    done = 1;
    const char *p = getenv("REDROID_FORGE_ENCODE_IDR_PERIOD");
    if (p && atoi(p) > 1) g_gop_period = (unsigned int)atoi(p);
    const char *io = getenv("REDROID_FORGE_ENCODE_INTRA_ONLY");
    g_gop_intra_only = (g_gop_period <= 1) || (io && atoi(io) != 0);
    g_rate_ctl.gop = !g_gop_intra_only;
    /* The Intel driver (iHD) produces P frames that do not decode with the hand-written slice header (measured on an Iris Xe,
     * entrypoint EncSlice: most P frames fail with "top block unavailable for requested intra mode"). Stay all-intra there
     * unless REDROID_FORGE_ENCODE_P_ON_INTEL=1, to experiment -- this restriction is specific to the legacy backend's own
     * bitstream writer, not to Intel/VA-API in general, so it does not apply when REDROID_FORGE_ENCODE_BACKEND=ffmpeg (the
     * whole point of that backend is a mature encoder that gets P frames right on every vendor). */
    const char *vendor = vaQueryVendorString(st->dpy);
    if (!g_gop_intra_only && vendor && strstr(vendor, "Intel") && !g_backend_is_ffmpeg) {
        const char *force = getenv("REDROID_FORGE_ENCODE_P_ON_INTEL");
        if (!(force && atoi(force) != 0)) {
            fprintf(stderr, "encoder: P frames are not supported on the Intel driver (%s): staying all-intra\n", vendor);
            g_gop_intra_only = 1;
            g_rate_ctl.gop = 0;
        }
    }
    if (!g_gop_intra_only) fprintf(stderr, "encoder: P frames, an IDR every %u frames\n", g_gop_period);
}

/* Imports the client's dma-buf as st->surfaces[0] (RGBA) -- shared between the legacy and ffmpeg
 * encode backends (see ffmpeg_encode.h), since this step and the RGBA->NV12 VPP conversion that
 * follows (convert_rgba_to_nv12) are identical either way; only what happens AFTER st->surfaces[2]
 * (NV12) is ready differs by backend.
 *
 * Tier 5.12: GPUs where no DRM modifier exists for this buffer class at
 * all (e.g. Polaris/GFX8's opaque TILE_TYPE_DRI, see rgba_modifier_init())
 * use the OLD, pre-modifier VA-API import (VASurfaceAttribExternalBuffers
 * / VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME) directly on the real fd instead
 * of DRM_PRIME_2 -- confirmed working, including cross-process, unlike
 * the Tier 5.10 GL-bridge attempt this replaced (EGL's plain dma-buf
 * import only resolves opaque tiling within the same process that
 * allocated the buffer; VA-API's own import machinery doesn't share that
 * limitation, likely because libva is built around cross-process IPC as
 * the normal case to begin with, unlike EGL/GL).
 *
 * Tier 5.7 finding: VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME (the old path
 * used up through Tier 5.6) has no way to describe a DRM format
 * modifier -- it always assumes the buffer is a plain linear raster.
 * That held for every earlier tier's synthetic/dumb buffers (which
 * genuinely were linear) but not for a real gralloc-allocated Surface
 * buffer, which can be GPU-tiled even with DCC compression disabled
 * (AMD_DEBUG=nodcc only affects compression, not tiling) -- importing a
 * tiled buffer this way produced a garbled, striped decode. DRM_PRIME_2
 * (VADRMPRIMESurfaceDescriptor) carries the modifier the component read
 * out of cros_gralloc's native handle, so the driver interprets the
 * memory layout correctly regardless of tiling.
 *
 * Tier 5.8 finding: the buffer itself is RGBA, not NV12 (Tier 5.7's
 * closing discovery -- GraphicBufferSource hands the encoder
 * SurfaceFlinger's raw GL-composited output, and this Mesa/minigbm
 * stack cannot allocate a buffer that's both GPU-renderable and real
 * YUV, see DEVLOG). VA_FOURCC_RGBA's byte order matches Android's
 * RGBA_8888 directly (confirmed back in tier3-dmabuf-import); the DRM
 * equivalent is DRM_FORMAT_ABGR8888, not DRM_FORMAT_RGBA8888 -- DRM
 * format names describe *bit* packing in a little-endian 32-bit word,
 * which inverts to the opposite letter order when read as bytes.
 *
 * Tier 5.9: the modifier comes from st->rgba_modifier (this host's own
 * GPU, determined once at daemon startup), not from the client's
 * request -- the Android-side component has no reliable way to read
 * its real value at all (see DEVLOG), and the value is GPU-generation-
 * specific besides, so asking this host's own driver directly is both
 * the only correct source and the one that needs no Android rebuild to
 * change machines. req->drm_format_modifier is intentionally ignored. */
static int import_dmabuf_as_surface0(vaapi_state_t *st, int dmabuf_fd, const EncodeRequest *req) {
    VADRMPRIMESurfaceDescriptor prime_desc = {0};
    VASurfaceAttribExternalBuffers legacy_ext_buf = {0};
    uintptr_t legacy_buffer_handles[1];
    VASurfaceAttrib import_attribs[2];
    VAStatus st_import;

    if (st->use_legacy_prime) {
        legacy_buffer_handles[0] = (uintptr_t)dmabuf_fd;
        legacy_ext_buf.pixel_format = VA_FOURCC_RGBA;
        legacy_ext_buf.width = req->width;
        legacy_ext_buf.height = req->height;
        legacy_ext_buf.data_size = req->dmabuf_size;
        legacy_ext_buf.num_planes = 1;
        legacy_ext_buf.pitches[0] = req->stride_y;
        legacy_ext_buf.offsets[0] = 0;
        legacy_ext_buf.buffers = legacy_buffer_handles;
        legacy_ext_buf.num_buffers = 1;

        import_attribs[0].type = VASurfaceAttribMemoryType;
        import_attribs[0].flags = VA_SURFACE_ATTRIB_SETTABLE;
        import_attribs[0].value.type = VAGenericValueTypeInteger;
        import_attribs[0].value.value.i = VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME;
        import_attribs[1].type = VASurfaceAttribExternalBufferDescriptor;
        import_attribs[1].flags = VA_SURFACE_ATTRIB_SETTABLE;
        import_attribs[1].value.type = VAGenericValueTypePointer;
        import_attribs[1].value.value.p = &legacy_ext_buf;

        st_import = vaCreateSurfaces(st->dpy, VA_RT_FORMAT_RGB32, req->width, req->height,
                                      &st->surfaces[0], 1, import_attribs, 2);
    } else {
        prime_desc.fourcc = VA_FOURCC_RGBA;
        prime_desc.width = req->width;
        prime_desc.height = req->height;
        prime_desc.num_objects = 1;
        prime_desc.objects[0].fd = dmabuf_fd;
        prime_desc.objects[0].size = req->dmabuf_size;
        prime_desc.objects[0].drm_format_modifier = st->rgba_modifier;
        prime_desc.num_layers = 1;
        prime_desc.layers[0].drm_format = DRM_FORMAT_ABGR8888;
        prime_desc.layers[0].num_planes = 1;
        prime_desc.layers[0].object_index[0] = 0;
        prime_desc.layers[0].offset[0] = 0;
        prime_desc.layers[0].pitch[0] = req->stride_y;

        import_attribs[0].type = VASurfaceAttribMemoryType;
        import_attribs[0].flags = VA_SURFACE_ATTRIB_SETTABLE;
        import_attribs[0].value.type = VAGenericValueTypeInteger;
        import_attribs[0].value.value.i = VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2;
        import_attribs[1].type = VASurfaceAttribExternalBufferDescriptor;
        import_attribs[1].flags = VA_SURFACE_ATTRIB_SETTABLE;
        import_attribs[1].value.type = VAGenericValueTypePointer;
        import_attribs[1].value.value.p = &prime_desc;

        st_import = vaCreateSurfaces(st->dpy, VA_RT_FORMAT_RGB32, req->width, req->height,
                                      &st->surfaces[0], 1, import_attribs, 2);
    }
    if (st_import != VA_STATUS_SUCCESS) {
        fprintf(stderr, "dma-buf import failed: %s\n", vaErrorStr(st_import));
        return -1;
    }
    return 0;
}

static long encode_one_frame(vaapi_state_t *st, int dmabuf_fd, const EncodeRequest *req, pid_t peer_pid,
                              unsigned char **out_buf) {
    if (vaapi_state_ensure_resolution(st, req->width, req->height) != 0) return -1;
    gop_config_init(st);
    const int64_t gop_now = now_ns();
    const GopDecision gd = gop_next(&st->gop, peer_pid, req->width, req->height, gop_now, g_gop_period, g_gop_intra_only);
    const int qp = rc_next_qp_t(&g_rate_ctl, now_ns(), req->bitrate, req->width, req->height, gd.is_idr);

    if (import_dmabuf_as_surface0(st, dmabuf_fd, req) != 0) return -1;

    if (convert_rgba_to_nv12(st, st->surfaces[0], req->width, req->height) != 0) {
        vaDestroySurfaces(st->dpy, &st->surfaces[0], 1);
        return -1;
    }

    unsigned int mb_width = align16(req->width) / 16;
    unsigned int mb_height = align16(req->height) / 16;

    VABufferID coded_buf;
    CHECK_VA(vaCreateBuffer(st->dpy, st->context_id, VAEncCodedBufferType,
                             req->width * req->height * 3, 1, NULL, &coded_buf),
             "vaCreateBuffer(coded)");

    VAEncSequenceParameterBufferH264 seq = {0};
    seq.seq_parameter_set_id = 0;
    seq.level_idc = 30;
    seq.intra_period = g_gop_intra_only ? 1 : g_gop_period;
    seq.intra_idr_period = g_gop_intra_only ? 1 : g_gop_period;
    seq.ip_period = g_gop_intra_only ? 0 : 1;
    seq.bits_per_second = req->bitrate ? req->bitrate : 2000000;
    seq.max_num_ref_frames = 1;
    seq.picture_width_in_mbs = mb_width;
    seq.picture_height_in_mbs = mb_height;
    seq.seq_fields.bits.frame_mbs_only_flag = 1;
    seq.seq_fields.bits.chroma_format_idc = 1;
    seq.seq_fields.bits.log2_max_frame_num_minus4 = 0;
    seq.seq_fields.bits.pic_order_cnt_type = 2;
    seq.frame_cropping_flag = (req->width != mb_width * 16 || req->height != mb_height * 16);
    seq.frame_crop_right_offset = (mb_width * 16 - req->width) / 2;
    seq.frame_crop_bottom_offset = (mb_height * 16 - req->height) / 2;

    VABufferID seq_buf;
    vaCreateBuffer(st->dpy, st->context_id, VAEncSequenceParameterBufferType, sizeof(seq), 1, &seq, &seq_buf);

    VAEncPictureParameterBufferH264 pic = {0};
    pic.CurrPic.picture_id = st->recon[gd.cur];
    pic.CurrPic.frame_idx = gd.frame_num;
    pic.CurrPic.TopFieldOrderCnt = (int32_t)gd.poc;
    pic.CurrPic.BottomFieldOrderCnt = (int32_t)gd.poc;
    pic.frame_num = (uint16_t)gd.frame_num;
    for (int i = 0; i < 16; i++) {
        pic.ReferenceFrames[i].picture_id = VA_INVALID_ID;
        pic.ReferenceFrames[i].flags = VA_PICTURE_H264_INVALID;
    }
    if (!gd.is_idr) {
        pic.ReferenceFrames[0].picture_id = st->recon[gd.ref];
        pic.ReferenceFrames[0].frame_idx = gd.ref_frame_num;
        pic.ReferenceFrames[0].flags = VA_PICTURE_H264_SHORT_TERM_REFERENCE;
        pic.ReferenceFrames[0].TopFieldOrderCnt = (int32_t)gd.ref_poc;
        pic.ReferenceFrames[0].BottomFieldOrderCnt = (int32_t)gd.ref_poc;
    }
    pic.coded_buf = coded_buf;
    pic.pic_init_qp = qp;
    pic.pic_fields.bits.idr_pic_flag = gd.is_idr;
    pic.pic_fields.bits.reference_pic_flag = 1;
    pic.pic_fields.bits.entropy_coding_mode_flag = 1;
    pic.pic_fields.bits.deblocking_filter_control_present_flag = 1;

    VABufferID pic_buf;
    vaCreateBuffer(st->dpy, st->context_id, VAEncPictureParameterBufferType, sizeof(pic), 1, &pic, &pic_buf);

    VAEncSliceParameterBufferH264 slice = {0};
    slice.num_macroblocks = mb_width * mb_height;
    slice.macroblock_info = VA_INVALID_ID;
    slice.slice_type = gd.is_idr ? 2 : 0;
    if (gd.is_idr) slice.idr_pic_id = st->idr_pic_id++ & 0xFFFF;
    slice.direct_spatial_mv_pred_flag = 1;
    slice.num_ref_idx_active_override_flag = 1;
    for (int i = 0; i < 32; i++) {
        slice.RefPicList0[i].picture_id = VA_INVALID_ID;
        slice.RefPicList0[i].flags = VA_PICTURE_H264_INVALID;
        slice.RefPicList1[i].picture_id = VA_INVALID_ID;
        slice.RefPicList1[i].flags = VA_PICTURE_H264_INVALID;
    }
    if (!gd.is_idr) {
        slice.num_ref_idx_l0_active_minus1 = 0;
        slice.RefPicList0[0] = pic.ReferenceFrames[0];
    }

    VABufferID slice_buf;
    vaCreateBuffer(st->dpy, st->context_id, VAEncSliceParameterBufferType, sizeof(slice), 1, &slice, &slice_buf);

    bitstream_t sps_bs, pps_bs, slice_hdr_bs;
    bs_init(&sps_bs);
    bs_init(&pps_bs);
    bs_init(&slice_hdr_bs);
    if (gd.is_idr) {
        build_sps_rbsp(&sps_bs, &seq);
        build_pps_rbsp(&pps_bs, &pic);
    }
    build_slice_header_bits(&slice_hdr_bs, &seq, &pic, &slice);

    VABufferID sps_param_buf, sps_data_buf, pps_param_buf, pps_data_buf;
    VABufferID slice_hdr_param_buf, slice_hdr_data_buf;
    if (gd.is_idr) {
        submit_packed_header(st->dpy, st->context_id, VAEncPackedHeaderSequence, &sps_bs, &sps_param_buf, &sps_data_buf);
        submit_packed_header(st->dpy, st->context_id, VAEncPackedHeaderPicture, &pps_bs, &pps_param_buf, &pps_data_buf);
    }
    submit_packed_header(st->dpy, st->context_id, VAEncPackedHeaderSlice, &slice_hdr_bs, &slice_hdr_param_buf, &slice_hdr_data_buf);

    CHECK_VA(vaBeginPicture(st->dpy, st->context_id, st->surfaces[2]), "vaBeginPicture");
    VABufferID b1[] = {seq_buf};
    vaRenderPicture(st->dpy, st->context_id, b1, 1);
    if (gd.is_idr) {
        VABufferID b2[] = {sps_param_buf, sps_data_buf};
        vaRenderPicture(st->dpy, st->context_id, b2, 2);
    }
    VABufferID b3[] = {pic_buf};
    vaRenderPicture(st->dpy, st->context_id, b3, 1);
    if (gd.is_idr) {
        VABufferID b4[] = {pps_param_buf, pps_data_buf};
        vaRenderPicture(st->dpy, st->context_id, b4, 2);
    }
    VABufferID b5[] = {slice_hdr_param_buf, slice_hdr_data_buf};
    vaRenderPicture(st->dpy, st->context_id, b5, 2);
    VABufferID b6[] = {slice_buf};
    vaRenderPicture(st->dpy, st->context_id, b6, 1);
    CHECK_VA(vaEndPicture(st->dpy, st->context_id), "vaEndPicture");
    CHECK_VA(vaSyncSurface(st->dpy, st->surfaces[2]), "vaSyncSurface");

    free(sps_bs.buf);
    free(pps_bs.buf);
    free(slice_hdr_bs.buf);

    VACodedBufferSegment *seg = NULL;
    CHECK_VA(vaMapBuffer(st->dpy, coded_buf, (void **)&seg), "vaMapBuffer(coded)");
    size_t total = 0;
    for (VACodedBufferSegment *s = seg; s != NULL; s = s->next) total += s->size;
    unsigned char *out = malloc(total);
    size_t off = 0;
    for (VACodedBufferSegment *s = seg; s != NULL; s = s->next) {
        memcpy(out + off, s->buf, s->size);
        off += s->size;
    }
    vaUnmapBuffer(st->dpy, coded_buf);
    vaDestroyBuffer(st->dpy, coded_buf);
    vaDestroySurfaces(st->dpy, &st->surfaces[0], 1);

    out = normalize_start_codes(out, total, &total);
    rc_frame_done_t(&g_rate_ctl, now_ns(), total, qp, gd.is_idr);
    gop_commit(&st->gop, &gd, peer_pid, req->width, req->height, gop_now);
    if (getenv("REDROID_FORGE_ENCODE_STATS")) {
        static int64_t t0; static uint64_t frames, bytes;
        int64_t t = now_ns();
        if (!t0 || t - t0 > 5000000000LL) {
            if (t0 && frames) fprintf(stderr, "encode-stats: %.2f Mbps over %.1f s (%llu frames, target %.2f Mbps, last qp %d)\n",
                                      bytes * 8.0 / ((t - t0) / 1e9) / 1e6, (t - t0) / 1e9, (unsigned long long)frames,
                                      req->bitrate / 1e6, qp);
            t0 = t; frames = 0; bytes = 0;
        }
        frames++; bytes += total;
    }
    if (getenv("REDROID_FORGE_ENCODE_STATS")) {
        static int64_t g0; static uint64_t gi, gp, gib, gpb;
        int64_t t = now_ns();
        if (!g0 || t - g0 > 5000000000LL) {
            if (g0 && (gi + gp)) fprintf(stderr, "gop-stats: %llu IDR (%.0f KB avg), %llu P (%.0f KB avg) in %.1f s\n",
                                         (unsigned long long)gi, gi ? gib / 1024.0 / gi : 0.0, (unsigned long long)gp,
                                         gp ? gpb / 1024.0 / gp : 0.0, (t - g0) / 1e9);
            g0 = t; gi = gp = gib = gpb = 0;
        }
        if (gd.is_idr) { gi++; gib += total; } else { gp++; gpb += total; }
    }
    *out_buf = out;
    return (long)total;
}

#ifdef HAVE_HWDEC
/* REDROID_FORGE_ENCODE_BACKEND=ffmpeg: same dma-buf import + RGBA->NV12 VPP step as
 * encode_one_frame() above (import_dmabuf_as_surface0/convert_rgba_to_nv12, untouched), same
 * gop_next()/gop_commit() IDR policy (gop.h has no VA-API dependency) -- only the actual encode
 * is different: ffmpeg_encode_frame() hands st->surfaces[2] to libavcodec's h264_vaapi encoder
 * instead of the hand-rolled SPS/PPS/slice-header + vaRenderPicture sequence. No per-frame qp /
 * rc_next_qp_t / req->bitrate here -- ffmpeg_encode.c forces a fixed CQP (see its own comment on
 * why: this is what every VA-API driver tested so far actually supports for this entrypoint, same
 * reasoning ratectl.h already gives for the legacy backend). REDROID_FORGE_ENCODE_STATS
 * is not mirrored for this backend yet either (both are known, deliberate gaps for this first cut,
 * not oversights -- see the plan this was built from). */
static long encode_one_frame_ffmpeg(vaapi_state_t *st, int dmabuf_fd, const EncodeRequest *req, pid_t peer_pid,
                                     unsigned char **out_buf) {
    if (vaapi_state_ensure_resolution(st, req->width, req->height) != 0) return -1;
    gop_config_init(st);
    const int64_t gop_now = now_ns();
    const GopDecision gd = gop_next(&st->gop, peer_pid, req->width, req->height, gop_now, g_gop_period, g_gop_intra_only);

    if (import_dmabuf_as_surface0(st, dmabuf_fd, req) != 0) return -1;

    if (convert_rgba_to_nv12(st, st->surfaces[0], req->width, req->height) != 0) {
        vaDestroySurfaces(st->dpy, &st->surfaces[0], 1);
        return -1;
    }

    unsigned char *out = NULL;
    long n = ffmpeg_encode_frame(g_ffmpeg_enc, st->dpy, st->surfaces[2], req->width, req->height,
                                  gd.is_idr, &out);
    vaDestroySurfaces(st->dpy, &st->surfaces[0], 1);
    if (n < 0) return -1;

    size_t total = (size_t)n;
    out = normalize_start_codes(out, total, &total);
    gop_commit(&st->gop, &gd, peer_pid, req->width, req->height, gop_now);
    *out_buf = out;
    return (long)total;
}
#endif

/* ------------------------------------------------------------------ *
 * Socket server: one connection = one request/response, per protocol.h.
 * Tier 7 added a second command (decode) dispatched by a 4-byte tag read
 * before either command's own request struct - see protocol.h's own top
 * comment and handle_connection() below.
 * ------------------------------------------------------------------ */
static int recv_request(int conn_fd, EncodeRequest *req, int *out_dmabuf_fd) {
    char cmsg_buf[CMSG_SPACE(sizeof(int))];
    struct iovec iov = {.iov_base = req, .iov_len = sizeof(*req)};
    struct msghdr msg = {0};
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = cmsg_buf;
    msg.msg_controllen = sizeof(cmsg_buf);

    memset(req, 0, sizeof(*req));  /* fields an older client does not send stay 0 */
    ssize_t n = recvmsg(conn_fd, &msg, 0);
    if (n != (ssize_t)sizeof(*req) && n != ENCODE_REQUEST_V1_SIZE) {
        if (n < 0) perror("recvmsg");
        else fprintf(stderr, "recvmsg: short read (%zd of %zu bytes)\n", n, sizeof(*req));
        return -1;
    }

    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
    if (!cmsg || cmsg->cmsg_type != SCM_RIGHTS) {
        fprintf(stderr, "recvmsg: no fd received (SCM_RIGHTS missing)\n");
        return -1;
    }
    memcpy(out_dmabuf_fd, CMSG_DATA(cmsg), sizeof(int));
    return 0;
}

static void send_response(int conn_fd, int32_t status, const unsigned char *buf, uint32_t size) {
    EncodeResponse resp = {.status = status, .coded_size = (status == 0) ? size : 0};
    if (write(conn_fd, &resp, sizeof(resp)) != (ssize_t)sizeof(resp)) {
        perror("write(response header)");
        return;
    }
    if (status == 0 && size > 0) {
        if (write(conn_fd, buf, size) != (ssize_t)size) perror("write(response body)");
    }
}

static void handle_encode(vaapi_state_t *st, int have_encode, int conn_fd) {
    EncodeRequest req;
    int dmabuf_fd = -1;
    if (recv_request(conn_fd, &req, &dmabuf_fd) != 0) {
        send_response(conn_fd, -1, NULL, 0);
        return;
    }
    if (!have_encode) {
        fprintf(stderr, "handle_encode: no AMD/Intel VA-API encode on this host, rejecting\n");
        close(dmabuf_fd);
        send_response(conn_fd, -1, NULL, 0);
        return;
    }

    fprintf(stderr, "Request: %ux%u, stride_y=%u stride_uv=%u offset_uv=%u dmabuf_size=%u fd=%d\n",
            req.width, req.height, req.stride_y, req.stride_uv, req.offset_uv, req.dmabuf_size, dmabuf_fd);

    struct ucred cred = {0};
    socklen_t cred_len = sizeof(cred);
    if (getsockopt(conn_fd, SOL_SOCKET, SO_PEERCRED, &cred, &cred_len) != 0) cred.pid = 0;

    unsigned char *out_buf = NULL;
    long n;
#ifdef HAVE_HWDEC
    if (g_backend_is_ffmpeg) n = encode_one_frame_ffmpeg(st, dmabuf_fd, &req, cred.pid, &out_buf);
    else
#endif
        n = encode_one_frame(st, dmabuf_fd, &req, cred.pid, &out_buf);
    close(dmabuf_fd);

    if (n < 0) {
        gop_reset(&st->gop);  /* the reference may be lost: the next frame is an IDR */
        send_response(conn_fd, -1, NULL, 0);
    } else {
        fprintf(stderr, "Encoded %ld bytes\n", n);
        send_response(conn_fd, 0, out_buf, (uint32_t)n);
        free(out_buf);
    }
}

static void send_decode_response(int conn_fd, int32_t status, const uint8_t *buf, uint32_t size) {
    DecodeResponse resp = {.status = status, .frame_size = (status == 0) ? size : 0};
    if (write(conn_fd, &resp, sizeof(resp)) != (ssize_t)sizeof(resp)) {
        perror("write(decode response header)");
        return;
    }
    if (status == 0 && size > 0) {
        if (write(conn_fd, buf, size) != (ssize_t)size) perror("write(decode response body)");
    }
}

/* Bitstream size cap: a sanity bound on untrusted client input (this is a
 * real system boundary - the Codec2 component runs Android-side), not a
 * real protocol limit. 32MiB is far beyond any single-picture Annex-B
 * buffer this project's own scope (baseline profile, one slice, no B-
 * frames) would ever produce. */
#define DECODE_MAX_BITSTREAM_SIZE (32u * 1024 * 1024)

static void handle_decode(int have_decode, int conn_fd) {
    DecodeRequest req;
    ssize_t n = read(conn_fd, &req, sizeof(req));
    if (n != (ssize_t)sizeof(req)) {
        if (n < 0) perror("read(DecodeRequest)");
        else fprintf(stderr, "read(DecodeRequest): short read (%zd of %zu bytes)\n", n, sizeof(req));
        send_decode_response(conn_fd, -1, NULL, 0);
        return;
    }
    if (req.bitstream_size == 0 || req.bitstream_size > DECODE_MAX_BITSTREAM_SIZE) {
        fprintf(stderr, "handle_decode: bad bitstream_size %u\n", req.bitstream_size);
        send_decode_response(conn_fd, -1, NULL, 0);
        return;
    }

    unsigned char *bitstream = malloc(req.bitstream_size);
    size_t got = 0;
    while (got < req.bitstream_size) {
        ssize_t r = read(conn_fd, bitstream + got, req.bitstream_size - got);
        if (r <= 0) {
            perror("read(bitstream)");
            free(bitstream);
            send_decode_response(conn_fd, -1, NULL, 0);
            return;
        }
        got += (size_t)r;
    }

    if (!have_decode) {
        fprintf(stderr, "handle_decode: no NVIDIA VA-API decode on this host, rejecting\n");
        free(bitstream);
        send_decode_response(conn_fd, -1, NULL, 0);
        return;
    }

    fprintf(stderr, "Decode request: %ux%u hint, %u bytes bitstream\n", req.width, req.height,
            req.bitstream_size);

    const uint8_t *out_data;
    size_t out_size;
    uint32_t out_width, out_height;
    int rc = decode_h264_frame(bitstream, req.bitstream_size, &out_data, &out_size, &out_width,
                               &out_height);
    free(bitstream);
    if (rc != 0) {
        send_decode_response(conn_fd, -1, NULL, 0);
        return;
    }
    if (out_width != req.width || out_height != req.height) {
        fprintf(stderr,
                "handle_decode: warning: SPS resolution %ux%u doesn't match request's %ux%u hint\n",
                out_width, out_height, req.width, req.height);
    }
    fprintf(stderr, "Decoded %ux%u, %zu bytes NV12\n", out_width, out_height, out_size);
    send_decode_response(conn_fd, 0, out_data, (uint32_t)out_size);
}

#ifdef HAVE_HWDEC
/* ------------------------------------------------------------------ *
 * hwdec (protocol v2, see protocol.h): stateful hardware decode.
 * One persistent connection = one session = one thread. The encode and the NVIDIA decode
 * above are still served serially on the main thread.
 * ------------------------------------------------------------------ */
_Static_assert((int)HWDEC_H264 == (int)VAAPI_HWDEC_CODEC_H264 && (int)HWDEC_HEVC == (int)VAAPI_HWDEC_CODEC_HEVC &&
               (int)HWDEC_VP9 == (int)VAAPI_HWDEC_CODEC_VP9 && (int)HWDEC_VP8 == (int)VAAPI_HWDEC_CODEC_VP8 &&
               (int)HWDEC_MPEG2 == (int)VAAPI_HWDEC_CODEC_MPEG2 && (int)HWDEC_VC1 == (int)VAAPI_HWDEC_CODEC_VC1 &&
               (int)HWDEC_AV1 == (int)VAAPI_HWDEC_CODEC_AV1 && (int)HWDEC_NCODECS == (int)VAAPI_HWDEC_CODEC_COUNT,
               "the codec ids of protocol.h and hwdec.h have to match");
_Static_assert(sizeof(HwDecRequest) == 16 && sizeof(HwDecFrameHeader) == 24 &&
               sizeof(HwDecResponse) == 8 && sizeof(HwDecCapsResponse) == 176,
               "unexpected protocol.h layout (Android and the daemon must match)");

#define HWDEC_MAX_AU_SIZE (32u * 1024 * 1024)

static const char *hwdec_node(void) {
    const char *n = getenv("REDROID_FORGE_DRM_NODE");
    return (n && *n) ? n : "/dev/dri/renderD128";
}

static int io_read_all(int fd, void *buf, size_t len) {
    size_t got = 0;
    while (got < len) {
        ssize_t n = read(fd, (char *)buf + got, len - got);
        if (n == 0) return 0;               /* the client closed */
        if (n < 0) { if (errno == EINTR) continue; return -1; }
        got += (size_t)n;
    }
    return 1;
}

static uint64_t mono_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
}

static int io_write_all(int fd, const void *buf, size_t len) {
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = write(fd, (const char *)buf + sent, len - sent);
        if (n < 0) { if (errno == EINTR) continue; return -1; }
        sent += (size_t)n;
    }
    return 0;
}

/* Frames pending to be sent: [HwDecFrameHeader][bytes] repeated. */
typedef struct {
    unsigned char *buf;
    size_t len, cap;
    uint32_t nframes;
} FrameQueue;

static int fq_append(FrameQueue *q, const HwDecFrame *f) {
    size_t need = q->len + sizeof(HwDecFrameHeader) + f->size;
    if (need > q->cap) {
        size_t cap = q->cap ? q->cap : 1u << 20;
        while (cap < need) cap *= 2;
        unsigned char *nb = realloc(q->buf, cap);
        if (!nb) return -1;
        q->buf = nb;
        q->cap = cap;
    }
    HwDecFrameHeader h = {.width = f->width, .height = f->height, .is_10bit = (uint32_t)f->is_10bit,
                          .size = (uint32_t)f->size, .pts = f->pts};
    memcpy(q->buf + q->len, &h, sizeof(h));
    memcpy(q->buf + q->len + sizeof(h), f->data, f->size);
    q->len = need;
    q->nframes++;
    return 0;
}

/* Drains whatever the decoder has ready. Returns 0, or <0 if there was a real error. */
static __thread uint64_t tl_ns_queue;  /* time in fq_append of the current thread (REDROID_FORGE_HWDEC_STATS) */

/* Shared memory (memfd) of the hwdec session, if the client asked for it: the frames are written there directly. */
typedef struct {
    uint8_t *base;
    size_t cap, off;
} ShmWin;
static __thread ShmWin *tl_shm;

static size_t shm_align(size_t n) {
    return (n + VAAPI_HWDEC_SHM_ALIGN - 1) / VAAPI_HWDEC_SHM_ALIGN * VAAPI_HWDEC_SHM_ALIGN;
}

static int fq_append_hdr(FrameQueue *q, const HwDecFrame *f) {
    size_t need = q->len + sizeof(HwDecFrameHeader);
    if (need > q->cap) {
        size_t cap = q->cap ? q->cap * 2 : 4096;
        unsigned char *nb = realloc(q->buf, cap);
        if (!nb) return -1;
        q->buf = nb;
        q->cap = cap;
    }
    HwDecFrameHeader h = {.width = f->width, .height = f->height, .is_10bit = (uint32_t)f->is_10bit,
                          .size = (uint32_t)f->size, .pts = f->pts};
    memcpy(q->buf + q->len, &h, sizeof(h));
    q->len = need;
    q->nframes++;
    return 0;
}

static int hwdec_drain(HwDecSession *s, FrameQueue *q) {
    HwDecFrame f;
    for (;;) {
        int r;
        if (tl_shm) {
            /* Shared memory mode: the frame is downloaded straight into place; only the header stays in the queue. */
            r = hwdec_receive_to(s, &f, tl_shm->base + tl_shm->off, tl_shm->cap - tl_shm->off);
            if (r == HWDEC_AGAIN || r == HWDEC_EOF) return 0;
            if (r < 0) return r;
            tl_shm->off += shm_align(f.size);
            if (fq_append_hdr(q, &f) != 0) return -1;
            continue;
        }
        r = hwdec_receive(s, &f);
        if (r == HWDEC_AGAIN || r == HWDEC_EOF) return 0;
        if (r < 0) return r;
        const uint64_t t0 = mono_ns();
        int ar = fq_append(q, &f);
        tl_ns_queue += mono_ns() - t0;
        if (ar != 0) return -1;
    }
}

/* Open response with the shared memory fd attached (SCM_RIGHTS). */
static int send_open_resp_fd(int sock, const HwDecOpenResponse *resp, int fd) {
    struct iovec iov = {.iov_base = (void *)resp, .iov_len = sizeof(*resp)};
    union {
        struct cmsghdr align;
        char buf[CMSG_SPACE(sizeof(int))];
    } u;
    memset(&u, 0, sizeof(u));
    struct msghdr msg = {.msg_iov = &iov, .msg_iovlen = 1, .msg_control = u.buf, .msg_controllen = sizeof(u.buf)};
    struct cmsghdr *c = CMSG_FIRSTHDR(&msg);
    c->cmsg_level = SOL_SOCKET;
    c->cmsg_type = SCM_RIGHTS;
    c->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(c), &fd, sizeof(int));
    ssize_t n;
    do { n = sendmsg(sock, &msg, MSG_NOSIGNAL); } while (n < 0 && errno == EINTR);
    return n == (ssize_t)sizeof(*resp) ? 0 : -1;
}

#define HWDEC_SHM_MIB 512u  /* virtual memory: only what the frames write is touched (and takes up RAM) */

static void *hwdec_stream_thread(void *arg) {
    int fd = (int)(intptr_t)arg;
    HwDecOpenRequest open_req;
    HwDecOpenResponse open_resp = {0};
    HwDecSession *s = NULL;
    unsigned char *au = NULL;
    size_t au_cap = 0;
    /* Stream configuration (VAAPI_HWDEC_MSG_CONFIG): pending to be prepended to the next AU, and the last
     * known one to repeat it after a decoder restart. */
    unsigned char *cfg = NULL, *last_cfg = NULL, *joined = NULL;
    size_t cfg_len = 0, last_cfg_len = 0, joined_cap = 0;
    int need_replay = 1;
    ShmWin shm = {0};
    int memfd = -1;
    tl_shm = NULL;
    const int stats = getenv("REDROID_FORGE_HWDEC_STATS") != NULL;
    uint64_t ns_wait = 0, ns_write = 0, nresp = 0;
    tl_ns_queue = 0;

    if (io_read_all(fd, &open_req, sizeof(open_req)) != 1) goto done;
    if (open_req.codec < HWDEC_NCODECS) s = hwdec_open(hwdec_node(), (HwDecCodec)open_req.codec);
    if (!s) {
        open_resp.status = -1;
        io_write_all(fd, &open_resp, sizeof(open_resp));
        goto done;
    }
    if (open_req.flags & VAAPI_HWDEC_OPEN_SHM) {
        /* The client can use shared memory: memfd + mmap, and the fd travels with the response. If something fails
         * it goes on with inline frames (the client knows by shm_mib == 0). */
        const size_t cap = (size_t)HWDEC_SHM_MIB << 20;
        memfd = (int)syscall(SYS_memfd_create, "redroid-forge-hwdec", 1u /* MFD_CLOEXEC */);
        if (memfd >= 0 && ftruncate(memfd, (off_t)cap) == 0) {
            void *m = mmap(NULL, cap, PROT_READ | PROT_WRITE, MAP_SHARED, memfd, 0);
            if (m != MAP_FAILED) {
                shm.base = m;
                shm.cap = cap;
                open_resp.shm_mib = HWDEC_SHM_MIB;
            }
        }
        if (!shm.base && memfd >= 0) { close(memfd); memfd = -1; }
    }
    if (shm.base) {
        if (send_open_resp_fd(fd, &open_resp, memfd) != 0) goto done;
        tl_shm = &shm;
    } else if (io_write_all(fd, &open_resp, sizeof(open_resp)) != 0) {
        goto done;
    }
    fprintf(stderr, "hwdec: session open (%s%s)\n", hwdec_codec_name((HwDecCodec)open_req.codec),
            shm.base ? ", shared memory" : "");

    for (;;) {
        HwDecRequest rq;
        const uint64_t tw0 = stats ? mono_ns() : 0;
        if (io_read_all(fd, &rq, sizeof(rq)) != 1) break;   /* the connection closed: the session is closed */
        if (stats) ns_wait += mono_ns() - tw0;
        FrameQueue q = {0};
        int status = 0, stop = 0;
        shm.off = 0;  /* the client has already copied the frames of the previous response */

        switch (rq.msg) {
        case VAAPI_HWDEC_MSG_AU: {
            if (rq.size == 0 || rq.size > HWDEC_MAX_AU_SIZE) { status = -2; stop = 1; break; }
            if (rq.size > au_cap) {
                unsigned char *nb = realloc(au, rq.size);
                if (!nb) { status = -3; stop = 1; break; }
                au = nb;
                au_cap = rq.size;
            }
            if (io_read_all(fd, au, rq.size) != 1) { stop = 1; status = -4; break; }
            /* Diagnostics (REDROID_FORGE_HWDEC_DEBUG=1): first bytes of every access unit that arrives. It is used
             * to see in what format Android delivers it (Annex-B with 00 00 00 01, or with a length prefix). */
            if (getenv("REDROID_FORGE_HWDEC_DEBUG")) {
                char hex[3 * 24 + 1] = {0};
                for (uint32_t i = 0; i < rq.size && i < 24; i++) snprintf(hex + 3 * i, 4, "%02x ", au[i]);
                fprintf(stderr, "hwdec: AU pts=%lld size=%u: %s\n", (long long)rq.pts, rq.size, hex);
            }
            /* Prepends the pending configuration (SPS/PPS), or the last known one if the decoder restarted. */
            const unsigned char *send_buf = au;
            size_t send_len = rq.size;
            const unsigned char *pre = cfg_len ? cfg : (need_replay ? last_cfg : NULL);
            size_t pre_len = cfg_len ? cfg_len : (need_replay ? last_cfg_len : 0);
            if (pre && pre_len) {
                if (pre_len + rq.size > joined_cap) {
                    unsigned char *nb = realloc(joined, pre_len + rq.size);
                    if (!nb) { status = -3; stop = 1; break; }
                    joined = nb;
                    joined_cap = pre_len + rq.size;
                }
                memcpy(joined, pre, pre_len);
                memcpy(joined + pre_len, au, rq.size);
                send_buf = joined;
                send_len = pre_len + rq.size;
            }
            cfg_len = 0;
            need_replay = 0;
            int r;
            while ((r = hwdec_send(s, send_buf, send_len, rq.pts)) == HWDEC_AGAIN) {
                if ((status = hwdec_drain(s, &q)) < 0) break;
            }
            if (status == 0 && r < 0) status = r;
            if (status == 0) status = hwdec_drain(s, &q);
            break;
        }
        case VAAPI_HWDEC_MSG_CONFIG: {
            if (rq.size == 0 || rq.size > HWDEC_MAX_AU_SIZE) { status = -2; stop = 1; break; }
            /* Android delivers the parameters in SEVERAL configuration buffers (H.264: first the SPS and
             * then the PPS; HEVC: VPS, SPS, PPS). As long as no access unit has consumed them they are
             * ACCUMULATED; the first CONFIG after an AU starts a new set. */
            /* Only H.264 and HEVC carry the configuration INSIDE the bitstream (SPS/PPS/VPS in Annex-B) and need it
             * prepended. In VP8/VP9/AV1 Android's "CSD" is the container's CodecPrivate (for VP9
             * it starts with 0x01, not with the 0x49 sync marker): prepending it makes the frame invalid. */
            if (open_req.codec != VAAPI_HWDEC_CODEC_H264 && open_req.codec != VAAPI_HWDEC_CODEC_HEVC) {
                unsigned char *skip = malloc(rq.size);
                if (!skip) { status = -3; stop = 1; break; }
                int rd = io_read_all(fd, skip, rq.size);
                free(skip);
                if (rd != 1) { stop = 1; status = -4; }
                break;
            }
            size_t total = cfg_len + rq.size;
            unsigned char *nb = realloc(cfg, total);
            if (!nb) { status = -3; stop = 1; break; }
            cfg = nb;
            if (io_read_all(fd, cfg + cfg_len, rq.size) != 1) { stop = 1; status = -4; break; }
            cfg_len = total;
            unsigned char *nl = realloc(last_cfg, total);
            if (!nl) { status = -3; stop = 1; break; }
            last_cfg = nl;
            memcpy(last_cfg, cfg, total);
            last_cfg_len = total;
            break;
        }
        case VAAPI_HWDEC_MSG_FLUSH:
            hwdec_flush(s);
            need_replay = 1;
            break;
        case VAAPI_HWDEC_MSG_EOS:
            status = hwdec_send_eos(s);
            if (status == 0) status = hwdec_drain(s, &q);
            /* After draining, libavcodec is left in the EOF state and rejects more input. Android's
             * component also asks to drain mid-stream (drain without EOS, e.g. on a change of
             * resolution), so the decoder is restarted to be able to keep decoding. */
            hwdec_flush(s);
            need_replay = 1;
            break;
        case VAAPI_HWDEC_MSG_CLOSE:
            stop = 1;
            break;
        default:
            status = -5;
            stop = 1;
            break;
        }

        HwDecResponse resp = {.status = status, .nframes = q.nframes};
        const uint64_t ts0 = stats ? mono_ns() : 0;
        int werr = io_write_all(fd, &resp, sizeof(resp));
        if (!werr && q.len) werr = io_write_all(fd, q.buf, q.len);
        if (stats) { ns_write += mono_ns() - ts0; nresp++; }
        free(q.buf);
        if (werr || stop) break;
    }
done:
    tl_shm = NULL;
    if (shm.base) munmap(shm.base, shm.cap);
    if (memfd >= 0) close(memfd);
    if (stats && nresp) {
        fprintf(stderr,
                "hwdec-stats[daemon]: %llu responses | per response (ms): android_wait=%.2f queue_build=%.2f "
                "socket_write=%.2f\n",
                (unsigned long long)nresp, (double)ns_wait / nresp / 1e6, (double)tl_ns_queue / nresp / 1e6,
                (double)ns_write / nresp / 1e6);
    }
    free(au);
    free(cfg);
    free(last_cfg);
    free(joined);
    hwdec_close(s);
    close(fd);
    return NULL;
}

static void handle_hwdec_caps(int conn_fd) {
    HwDecCapsResponse resp = {0};
    HwDecCaps caps;
    if (hwdec_probe(hwdec_node(), &caps) != 0) {
        resp.status = -1;
    } else {
        for (int i = 0; i < HWDEC_NCODECS; i++) {
            if (caps.supported[i]) resp.supported_mask |= 1u << i;
            if (caps.supported_10bit[i]) resp.supported_10bit_mask |= 1u << i;
        }
        snprintf(resp.driver, sizeof(resp.driver), "%s", caps.driver);
    }
    io_write_all(conn_fd, &resp, sizeof(resp));
}
#endif /* HAVE_HWDEC */

/* Returns 1 if the connection moves to another thread (which closes it), 0 if it has to be closed here. */
static int handle_connection(vaapi_state_t *st, int have_encode, int have_decode, int conn_fd) {
    VaapiCommand cmd;
    ssize_t n = read(conn_fd, &cmd, sizeof(cmd));
    if (n != (ssize_t)sizeof(cmd)) {
        if (n < 0) perror("read(command tag)");
        else fprintf(stderr, "read(command tag): short read (%zd of %zu bytes)\n", n, sizeof(cmd));
        return 0;
    }
    switch (cmd) {
    case VAAPI_CMD_ENCODE:
        handle_encode(st, have_encode, conn_fd);
        break;
    case VAAPI_CMD_DECODE:
        handle_decode(have_decode, conn_fd);
        break;
#ifdef HAVE_HWDEC
    case VAAPI_CMD_HWDEC: {
        pthread_t t;
        if (pthread_create(&t, NULL, hwdec_stream_thread, (void *)(intptr_t)conn_fd) != 0) {
            perror("pthread_create(hwdec)");
            return 0;
        }
        pthread_detach(t);
        return 1;
    }
    case VAAPI_CMD_HWDEC_CAPS:
        handle_hwdec_caps(conn_fd);
        break;
#else
    case VAAPI_CMD_HWDEC:
    case VAAPI_CMD_HWDEC_CAPS:
        fprintf(stderr, "hwdec requested, but this daemon was compiled without HAVE_HWDEC\n");
        break; /* the connection is closed: the client sees it as a clean rejection */
#endif
    default:
        fprintf(stderr, "handle_connection: unknown command tag %d\n", (int)cmd);
        break;
    }
    return 0;
}

int main(void) {
    setvbuf(stderr, NULL, _IONBF, 0);

    /* Must happen before any Mesa entry point runs at all (vaInitialize
     * included) -- see rgba_modifier_init()'s comment for why. */
    setenv("AMD_DEBUG", "nodcc", 1);

    /* Encode (AMD/Intel) and decode (NVIDIA) are independent, optional
     * backends - a host may have either, both (two different GPUs, two
     * different render nodes down the line), or neither yet. Tier 7's own
     * dev host (jgustavo47, a GTX 1050 Ti with no AMD/Intel GPU at all) is
     * decode-only; existing production hosts stay encode-only. Neither
     * init failing is fatal by itself - only both together mean this
     * daemon has nothing to actually do. */
    vaapi_state_t st;
    int have_encode = (vaapi_state_init(&st) == 0);
    if (!have_encode) {
        fprintf(stderr, "No AMD/Intel VA-API encode on this host - encode requests will be rejected\n");
    }
    if (have_encode) {
        const char *backend = getenv("REDROID_FORGE_ENCODE_BACKEND");
        int ffmpeg_requested = backend && strcmp(backend, "ffmpeg") == 0;
#ifdef HAVE_HWDEC
        if (ffmpeg_requested) {
            g_ffmpeg_enc = ffmpeg_encode_open(DRM_RENDER_DEVICE);
            g_backend_is_ffmpeg = (g_ffmpeg_enc != NULL);
            if (!g_backend_is_ffmpeg)
                fprintf(stderr, "encoder backend: ffmpeg requested but failed to open -- falling back to legacy\n");
        }
#else
        if (ffmpeg_requested)
            fprintf(stderr, "encoder backend: ffmpeg requested, but this daemon was compiled without HAVE_HWDEC -- using legacy\n");
#endif
        fprintf(stderr, "encoder backend: %s\n", g_backend_is_ffmpeg ? "ffmpeg (h264_vaapi)" : "legacy (hand-rolled bitstream)");
    }
    int have_decode = (decode_h264_init() == 0);
    if (!have_decode) {
        fprintf(stderr, "No NVIDIA VA-API decode on this host - decode requests will be rejected\n");
    }
    int have_hwdec = 0;
#ifdef HAVE_HWDEC
    {
        HwDecCaps caps;
        have_hwdec = (hwdec_probe(hwdec_node(), &caps) == 0);
        if (have_hwdec) {
            fprintf(stderr, "hwdec: %s; decodes in hardware:", caps.driver);
            for (int i = 0; i < HWDEC_NCODECS; i++)
                if (caps.supported[i]) fprintf(stderr, " %s%s", hwdec_codec_name((HwDecCodec)i), caps.supported_10bit[i] ? "(+10b)" : "");
            fputc('\n', stderr);
        } else {
            fprintf(stderr, "hwdec: this host offers no hardware decode through VA-API\n");
        }
    }
#endif
    if (!have_encode && !have_decode && !have_hwdec) {
        fprintf(stderr, "Neither encode nor decode available on this host - nothing to do\n");
        return 1;
    }

    /* Parent directory is the shared bind-mount point between this host
     * process and the redroid container (see README.md) -- created here
     * so the daemon can run before that mount is even set up manually. */
    const char *socket_path = getenv("REDROID_FORGE_VAAPI_SOCKET");
    if (!socket_path || !*socket_path) socket_path = VAAPI_DAEMON_SOCKET_PATH;
    if (strcmp(socket_path, VAAPI_DAEMON_SOCKET_PATH) == 0) mkdir("/dev/vaapi-helper", 0755);
    /* Never take the name away from a daemon that is alive (another forge on this host): that one would keep running but
     * nobody could reach it. A socket nobody listens on is a leftover and is replaced. */
    {
        int probe = socket(AF_UNIX, SOCK_STREAM, 0);
        struct sockaddr_un pa = {0};
        pa.sun_family = AF_UNIX;
        strncpy(pa.sun_path, socket_path, sizeof(pa.sun_path) - 1);
        if (probe >= 0 && connect(probe, (struct sockaddr *)&pa, sizeof(pa)) == 0) {
            fprintf(stderr, "Another daemon is already listening on %s: not starting\n", socket_path);
            close(probe);
            return 1;
        }
        if (probe >= 0) close(probe);
    }
    unlink(socket_path);

    int listen_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listen_fd < 0) {
        perror("socket");
        return 1;
    }
    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, socket_path, sizeof(addr.sun_path) - 1);
    if (bind(listen_fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        perror("bind");
        return 1;
    }
    chmod(socket_path, 0666);
    if (listen(listen_fd, 4) != 0) {
        perror("listen");
        return 1;
    }
    fprintf(stderr, "Listening on %s\n", socket_path);

    while (1) {
        int conn_fd = accept(listen_fd, NULL, NULL);
        if (conn_fd < 0) {
            if (errno == EINTR) continue;
            perror("accept");
            break;
        }
        if (!handle_connection(&st, have_encode, have_decode, conn_fd)) close(conn_fd);
    }

    close(listen_fd);
    return 0;
}
