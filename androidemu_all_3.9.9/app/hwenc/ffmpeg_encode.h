/*
 * H.264 VA-API encode via libavcodec's h264_vaapi (REDROID_FORGE_ENCODE_BACKEND=ffmpeg), as an
 * alternative to daemon.c's own hand-rolled bitstream writer (REDROID_FORGE_ENCODE_BACKEND=legacy,
 * the default). See docs/ROADMAP.md and the Dockerfile's ffmpeg-lgpl stage comment for why this is
 * safe to add (LGPL-only, same build already used by hwdec.c for decode).
 *
 * This module owns its OWN, independent VADisplay (same DRM render node as daemon.c's st->dpy, but
 * a separate vaInitialize()), instead of sharing st->dpy directly -- VASurfaceIDs aren't valid
 * across VADisplay instances, so daemon.c's own NV12 surface (populated by its existing RGBA->NV12
 * VPP step, unchanged by this module) has to be downloaded to a plain RAM buffer first and handed
 * over as bytes; ffmpeg_encode_frame() does that download itself. This costs one extra GPU<->RAM
 * round trip per frame (download NV12, then ffmpeg uploads it again into its own VAAPI surface
 * pool) in exchange for a much simpler, fully decoupled integration that can't fight the legacy
 * path over VA-API config/context lifetime -- a deliberate simplification for this first cut, not
 * a limit of VA-API/ffmpeg itself.
 */
#ifndef FFMPEG_ENCODE_H
#define FFMPEG_ENCODE_H

#include <va/va.h>
#include <stdint.h>

typedef struct FFmpegEncState FFmpegEncState;

/* Opens an h264_vaapi encoder session on `drm_node` (daemon.c's own DRM_RENDER_DEVICE). Returns
 * NULL on error (logged) -- the caller should fall back to the legacy backend in that case. */
FFmpegEncState *ffmpeg_encode_open(const char *drm_node);

/* Encodes one frame. `src_dpy`/`src_surface` is the daemon's own NV12 source surface (already
 * populated by its RGBA->NV12 VPP conversion before this is called) -- downloaded internally, not
 * owned or modified by this call. (Re)configures the encoder on a resolution change,
 * transparently. `force_idr` should be gop.h's GopDecision.is_idr, so this backend honours the
 * exact same new-peer/resolution-change/periodic-IDR policy as the legacy one (gop_next() itself
 * has no VA-API/backend dependency).
 *
 * Fixed CQP, no client-requested bitrate (unlike the legacy backend's ratectl.h) -- confirmed live
 * on Intel (n02, iHD, VAEntrypointEncSliceLP): asking for anything else ("Driver does not support
 * any RC mode compatible with selected options (supported modes: CQP)") fails avcodec_open2()
 * outright on that driver/entrypoint. CQP is also what the legacy backend forces on every vendor,
 * for the same reason (ratectl.h's own comment: "the driver must not run its own rate control").
 * A later iteration could feed the daemon's own g_rate_ctl-computed QP in per frame instead of a
 * fixed one; out of scope for this first cut.
 *
 * Returns malloc'd Annex-B bytes in *out_buf (caller frees) and the byte count, or -1 on error
 * (logged). */
long ffmpeg_encode_frame(FFmpegEncState *s, VADisplay src_dpy, VASurfaceID src_surface,
                          unsigned int width, unsigned int height, int force_idr,
                          unsigned char **out_buf);

void ffmpeg_encode_close(FFmpegEncState *s);

#endif
