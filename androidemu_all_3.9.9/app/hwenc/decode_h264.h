/*
 * Tier 7: NVIDIA H.264 decode via VA-API (nvidia-vaapi-driver), ported from
 * the standalone spike (../tier6-vaapi-decode/main.c, see its own README
 * for the full bug-by-bug trail) into a persistent-state API this daemon
 * can call once per request, the same shape encode_one_frame()/
 * vaapi_state_t already use for encode.
 *
 * Deliberately its own compilation unit, not folded into daemon.c directly:
 * decode needs Vulkan (to de-tile NVDEC's own hardware decode surface,
 * which stays genuinely GPU-tiled no matter what this code asks for - see
 * the spike's own README for why), loaded lazily via dlopen exactly like
 * redroid-nvidia's own vtest_gpu_encode.c, so a daemon built and run on an
 * AMD/Intel-only host never needs libvulkan installed at all - the encode
 * path in daemon.c itself has no Vulkan dependency, and this file's own
 * init function fails cleanly (returns nonzero) rather than crashing if
 * Vulkan or nvidia-vaapi-driver aren't present.
 */

#ifndef TIER5_VAAPI_DAEMON_DECODE_H264_H
#define TIER5_VAAPI_DAEMON_DECODE_H264_H

#include <stddef.h>
#include <stdint.h>

/*
 * One-time setup: opens the DRM render node, initializes VA-API (this
 * daemon's own main() is responsible for making sure LIBVA_DRIVER_NAME
 * resolves to "nvidia" for THIS init call specifically - see daemon.c's
 * own comment on how it keeps that separate from the existing AMD/Intel
 * encode vaInitialize() call in the same process), and confirms
 * VAEntrypointVLD is available for H.264. Safe to call even on a host
 * without NVIDIA decode support: returns nonzero, logs why, and every
 * decode_h264_frame() call after a failed init returns an error
 * immediately rather than touching uninitialized state.
 *
 * Returns 0 on success.
 */
int decode_h264_init(void);

/*
 * Decodes one picture from a caller-supplied Annex-B H.264 buffer. Unlike
 * the standalone spike (which read SPS/PPS/IDR from a pre-split file),
 * this takes the whole buffer as handed over the wire (see protocol.h) and
 * does its own NAL splitting/parsing internally - it expects to find (in
 * any order) an SPS, a PPS, and exactly one IDR slice NAL in `bitstream`,
 * matching the spike's own scope otherwise (baseline profile, CAVLC, one
 * slice per picture, no B-frames/interlacing/cropping; see
 * tier6-vaapi-decode/main.c's own header comment for the full list).
 *
 * Width/height are NOT taken from the caller - they're read out of the
 * SPS itself (the only authoritative source) and returned via out_width
 * and out_height so the caller can cross-check them against whatever it
 * already expected.
 *
 * On success, *out_data points at a buffer owned by this module (valid
 * until the next call - copy it before calling again) holding *out_size
 * bytes of tightly-packed NV12 (no plane padding: `width*height` luma
 * bytes, then `width*height/2` interleaved-UV bytes).
 *
 * Returns 0 on success, or a negative value on failure.
 */
int decode_h264_frame(const uint8_t *bitstream, size_t bitstream_size, const uint8_t **out_data,
                      size_t *out_size, uint32_t *out_width, uint32_t *out_height);

#endif
