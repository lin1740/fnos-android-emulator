/*
 * Wire protocol between the Codec2 components running inside Android
 * (bionic) and this VA-API daemon running on the host (glibc).
 *
 * Why this exists at all: porting Mesa's radeonsi Gallium driver (+ the
 * LLVM shader compiler it needs) to build against bionic turned out to be
 * a vastly bigger undertaking than expected -- this AOSP build's Mesa only
 * compiles the gfxstream/ANGLE/Vulkan pieces for Android; there is no
 * Android-side radeonsi at all, real GLES rendering is forwarded to the
 * host's own Mesa the same way. This protocol does the equivalent for
 * VA-API encode: the Android side sends a dma-buf fd + frame parameters,
 * the host side (running the exact VA-API pipeline already proven in
 * tier2-vaapi-encode/tier3-dmabuf-import) does the real encode and sends
 * back the coded bytes.
 *
 * Transport: SOCK_STREAM AF_UNIX. One connection = one encode request/
 * response for now (matches Tier 2/3's "one frame, prove it end to end"
 * scope; a real streaming protocol is Tier 5.6's concern once this
 * baseline round-trip is confirmed).
 *
 * Request: sendmsg() with EncodeRequest as the regular data and the
 * dma-buf fd as SCM_RIGHTS ancillary data, in a single call (so the fd and
 * the metadata describing it can never arrive mismatched).
 *
 * Response: EncodeResponse header, then (if status == 0) exactly
 * `coded_size` bytes of Annex-B H.264.
 *
 * Tier 7 added a second command, decode, on the same socket/connection
 * shape (one connection = one request/response) but a simpler wire shape
 * of its own: every byte flows as plain stream data, no SCM_RIGHTS at all
 * in either direction. The daemon's own persistent VA-API decode surface
 * is driver-allocated (there's no client dma-buf to import on the way
 * in), and - unlike encode's real hardware-tiled output, which stays on
 * the GPU as a coded bitstream - a decoded NV12 frame is small enough,
 * and this project's existing convention already asks for it (see
 * VaapiEncComponent's own encodeViaDaemon()/process(): the daemon returns
 * plain bytes, the component copies them into its own output block), that
 * doing the same for decode's output keeps this new code path consistent
 * with the encode path already proven end to end, rather than adding a
 * new, less-tested zero-copy-into-a-client-buffer scheme up front.
 *
 * Every new connection sends a 4-byte VaapiCommand tag FIRST (a plain
 * write()/read(), before any encode-specific sendmsg()/recvmsg()), so the
 * daemon can dispatch before touching either request struct - existing
 * encode clients (this repo's own test-client.c and
 * VaapiEncComponent.cpp) were updated to send VAAPI_CMD_ENCODE first;
 * anything predating this tag would desync the protocol entirely, so
 * there's no backward-compatible "old" framing to preserve.
 *
 * Decode request: VaapiCommand tag, then a DecodeRequest header, then
 * exactly `bitstream_size` bytes of Annex-B H.264 - the real NAL unit as
 * it appears in the stream (start code excluded, but - a real bug
 * tier6-vaapi-decode's own README documents in detail - the NAL's own
 * 1-byte header INCLUDED, not just the RBSP payload after it).
 *
 * Decode response: DecodeResponse header, then (if status == 0) exactly
 * `frame_size` bytes of tightly-packed NV12 (no plane padding).
 */

#ifndef TIER5_VAAPI_DAEMON_PROTOCOL_H
#define TIER5_VAAPI_DAEMON_PROTOCOL_H

#include <stdint.h>

#define VAAPI_DAEMON_SOCKET_PATH "/dev/vaapi-helper/socket"

typedef enum {
    VAAPI_CMD_ENCODE = 1,
    VAAPI_CMD_DECODE = 2,   /* decode NVIDIA de UN frame intra suelto (Tier 7) */
    VAAPI_CMD_HWDEC = 3,    /* stream de decode por hardware, persistente (AMD/Intel via libavcodec) */
    VAAPI_CMD_HWDEC_CAPS = 4, /* which codecs this host decodes in hardware */
} VaapiCommand;

/* NV12 only for now -- matches what a real Codec2 encoder input buffer
 * (GRALLOC_USAGE_HW_VIDEO_ENCODER) is expected to be, unlike the RGBA
 * SurfaceFlinger composited buffer the Tier 3 real-gralloc spike found
 * (that one back was the wrong kind of buffer for this exact reason). */
typedef struct {
    uint32_t width;
    uint32_t height;
    uint32_t stride_y;    /* plane 0 (Y) row stride, bytes */
    uint32_t stride_uv;   /* plane 1 (interleaved UV) row stride, bytes */
    uint32_t offset_uv;   /* plane 1 offset within the same dma-buf, bytes */
    uint32_t dmabuf_size; /* total dma-buf size, bytes -- sanity check on the server side */
    /* Tier 5.7 finding: a buffer that comes from a real gralloc allocation
     * (as opposed to the dumb/synthetic buffers earlier tiers used) can be
     * GPU-tiled even with DCC disabled (AMD_DEBUG=nodcc only turns off
     * *compression*, not tiling) -- importing it as if it were a plain
     * linear NV12 raster produces a garbled, striped decode. cros_gralloc's
     * native handle (cros_gralloc_handle.h) carries the real DRM format
     * modifier alongside the buffer; forwarding it here lets the daemon use
     * VA-API's modifier-aware DRM_PRIME_2 import instead of guessing LINEAR. */
    uint64_t drm_format_modifier;
    /* Target bitrate in bits per second (what MediaCodec asked for), 0 = not specified. The
     * encoder is constant-QP underneath; the daemon steers the QP of every frame to reach this
     * average (ratectl.h). With 0 it keeps its historical fixed QP. A request WITHOUT these last
     * 8 bytes (an older Android component, EncodeRequestV1 in size) is accepted as 0. */
    uint32_t bitrate;
    uint32_t reserved;
} EncodeRequest;

/* Size of EncodeRequest before `bitrate` existed. */
#define ENCODE_REQUEST_V1_SIZE 32

typedef struct {
    int32_t status;      /* 0 = ok, negative = error (see vaErrorStr equivalents server-side) */
    uint32_t coded_size; /* bytes of Annex-B H.264 following this header, 0 if status != 0 */
} EncodeResponse;

typedef struct {
    uint32_t width;
    uint32_t height;
    uint32_t bitstream_size; /* bytes of Annex-B H.264 immediately following
                              * this header on the wire - see this file's
                              * own top comment for the exact NAL framing. */
} DecodeRequest;

typedef struct {
    int32_t status;      /* 0 = ok, negative = error */
    uint32_t frame_size; /* bytes of tightly-packed NV12 following this header, 0 if status != 0 */
} DecodeResponse;

/* ------------------------------------------------------------------ *
 * hwdec (protocol v2): stateful hardware decode, AMD/Intel.
 * Design in docs/ROADMAP.md (Phase 2, step 5) and backend/native/vaapi-daemon/hwdec.h.
 *
 * Unlike ENCODE/DECODE (one connection = one request), VAAPI_CMD_HWDEC is
 * A PERSISTENT CONNECTION PER STREAM, served by the daemon in its own thread so as
 * not to block the encode. Closing the connection closes the session.
 *
 *   client -> tag VAAPI_CMD_HWDEC (4 bytes), then HwDecOpenRequest
 *   daemon -> HwDecOpenResponse (status != 0: the hardware does not support that codec
 *             or something failed; there is NO fallback to software, the client decides)
 *   repeated:
 *     client -> HwDecRequest { msg, size, pts }, and `size` bytes if msg == AU
 *     daemon -> HwDecResponse { status, nframes }, and then `nframes` times:
 *               HwDecFrameHeader + `size` bytes of frame
 *
 * Every AU delivers ONE access unit (Annex-B for H.264/HEVC, a raw frame for VP8/VP9/AV1)
 * and the response carries ALL the frames the decoder released up to that moment, already
 * reordered: normally 0 or 1, more when there are B-frames. EOS drains the decoder and
 * returns the frames that were left. FLUSH discards references and pending output.
 *
 * The frames are compact NV12 or P010, without padding. They travel inline through the
 * socket, or through shared memory (memfd) if the client asks for it
 * (VAAPI_HWDEC_OPEN_SHM), which avoids two copies per frame. For 10-bit 4K (~750 MB/s) a
 * dma-buf would have to be passed (step 2b, only if the measurement justifies it).
 *
 * VAAPI_CMD_HWDEC_CAPS: a tag, and the daemon answers HwDecCapsResponse (a single
 * response, the connection is closed). The backend uses it to register in Android only the
 * decoders the host really supports.
 * ------------------------------------------------------------------ */

/* The same values as HwDecCodec of hwdec.h (the daemon verifies it at build time). */
enum {
    VAAPI_HWDEC_CODEC_H264 = 0,
    VAAPI_HWDEC_CODEC_HEVC = 1,
    VAAPI_HWDEC_CODEC_VP9 = 2,
    VAAPI_HWDEC_CODEC_VP8 = 3,
    VAAPI_HWDEC_CODEC_MPEG2 = 4,
    VAAPI_HWDEC_CODEC_VC1 = 5,
    VAAPI_HWDEC_CODEC_AV1 = 6,
    VAAPI_HWDEC_CODEC_COUNT = 7,
};

typedef enum {
    VAAPI_HWDEC_MSG_AU = 1,    /* one access unit; `size` bytes follow */
    VAAPI_HWDEC_MSG_FLUSH = 2,
    VAAPI_HWDEC_MSG_EOS = 3,
    VAAPI_HWDEC_MSG_CLOSE = 4,
    /* The stream's configuration data (SPS/PPS/VPS in Annex-B, Android's "codec config"), WITHOUT an image.
     * libavcodec rejects an H.264 packet that carries only parameters ("no frame!"), so the daemon
     * stores them and prepends them to the next access unit (and again after a FLUSH/EOS). `size` bytes
     * follow; the response carries no frames. */
    VAAPI_HWDEC_MSG_CONFIG = 5,
} VaapiHwdecMsg;

/* HwDecOpenRequest.flags: the client knows how to receive the fd of a shared memory (SCM_RIGHTS) and read the
 * frames there. If the daemon offers it, HwDecOpenResponse.shm_mib != 0 and the fd travels attached to that
 * response; the frames no longer follow inline: after every HwDecResponse come `nframes` HwDecFrameHeader
 * WITHOUT data, and frame k is in the shared memory, at the offset (the sum of the previous `size` values, each
 * rounded up to VAAPI_HWDEC_SHM_ALIGN). The frames of one response are overwritten by those of the next: the
 * client copies them before its next request. Without the flag (or if the daemon cannot), the protocol is the
 * usual inline one. */
#define VAAPI_HWDEC_OPEN_SHM 1u
#define VAAPI_HWDEC_SHM_ALIGN 4096u

typedef struct {
    uint32_t codec; /* VAAPI_HWDEC_CODEC_* */
    uint32_t flags; /* VAAPI_HWDEC_OPEN_* */
} HwDecOpenRequest;

typedef struct {
    int32_t status;   /* 0 = session open */
    uint32_t shm_mib; /* size of the shared memory in MiB (0 = none, frames inline) */
} HwDecOpenResponse;

typedef struct {
    uint32_t msg;  /* VaapiHwdecMsg */
    uint32_t size; /* bytes of the AU that follow (AU only) */
    int64_t pts;
} HwDecRequest;

typedef struct {
    int32_t status;   /* 0 = ok; <0 error (the `nframes` already decoded are still sent) */
    uint32_t nframes;
} HwDecResponse;

typedef struct {
    uint32_t width;
    uint32_t height;
    uint32_t is_10bit; /* 0: NV12, 1: P010 */
    uint32_t size;     /* bytes of frame that follow */
    int64_t pts;
} HwDecFrameHeader;

typedef struct {
    int32_t status;
    uint32_t reserved;
    uint32_t supported_mask;      /* bit i = VAAPI_HWDEC_CODEC_i decodable in hardware */
    uint32_t supported_10bit_mask; /* ... and also its 10-bit variant */
    char driver[160];             /* the VA-API driver string, informative */
} HwDecCapsResponse;

#endif
