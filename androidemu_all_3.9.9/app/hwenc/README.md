# Tier 5: the VA-API daemon

A host-side (glibc) persistent process that does real hardware video work on behalf of the Codec2
components running inside Android (bionic): H.264 **encode** (AMD/Intel, via each vendor's own
`VAEntrypointEncSlice`, hand-rolled bitstream by default or, since 5.16, a libavcodec/`h264_vaapi`
alternative), H.264/HEVC/VP9/... **vendor-agnostic hardware decode** for apps (since 5.15, AMD/
Intel, via libavcodec + VA-API), and, since Tier 7, H.264 **decode for this project's own
screen-streaming path** (NVIDIA, via `nvidia-vaapi-driver`'s `VAEntrypointVLD`). One process,
several independent backends — a host can have any combination, or neither encode nor decode yet;
see "Two backends, one daemon" below (written before 5.15 added a third, but the reasoning is the
same: each backend's own init failing is never fatal to the others).

This file covers the daemon itself and its wire protocol. The sections below are numbered by when
each capability landed (5.2 through 5.12 for the original encode path, Tier 7 for NVIDIA decode,
5.14–5.16 for later additions: GOP/P-frames, vendor-agnostic hwdec, and the ffmpeg encode
backend) — treat them as a build order, not a changelog to read start to finish; `DEVLOG.md` has
the full session-by-session narrative if you want that.

## Why a daemon instead of calling VA-API directly from the Android component

The original Tier 5 plan was to port Mesa's VA-API Gallium frontend
(`gallium/frontends/va`/`targets/va`) to Soong and link it against this build's Android-side
`radeonsi` driver. That driver doesn't exist: this AOSP build's Mesa (`external/mesa3d`) only
compiles the `gfxstream`/ANGLE/Vulkan pieces for Android -- real GLES rendering is *forwarded to
the host*, the same way ChromeOS ARC++ and the Android Emulator do it. Porting the actual
`radeonsi` + winsys + (likely) LLVM stack to bionic would be a vastly bigger undertaking than
porting just the VA-API frontend -- realistically weeks of work on its own.

Since Android's own graphics stack already solves "the guest doesn't have a real GPU driver" by
forwarding to the host, Tier 5 does the same thing for encode: this daemon runs on the host,
using the exact VA-API pipeline already proven in `tier2-vaapi-encode`/`tier3-dmabuf-import`. The
Android-side Codec2 component becomes a thin IPC client instead of needing any VA-API/Mesa code
of its own.

## Protocol (`protocol.h`)

`AF_UNIX`/`SOCK_STREAM`. One connection = one request/response (still true for both commands —
a real streaming protocol, reusing one connection across many frames, remains future work for
either direction).

Every connection starts with a plain 4-byte `VaapiCommand` tag (`VAAPI_CMD_ENCODE` or
`VAAPI_CMD_DECODE`), read via a plain `read()` before either command's own request struct — this
is how one daemon process dispatches both kinds of request on the same socket.

**Encode** (`EncodeRequest`/`EncodeResponse`):
- **Request**: tag, then `sendmsg()` with an `EncodeRequest` struct (width, height, NV12 plane
  strides/offset, dma-buf size) as the regular payload and the dma-buf fd as `SCM_RIGHTS`
  ancillary data, in a single call — so the fd and the metadata describing its layout can never
  arrive mismatched.
- **Response**: an `EncodeResponse` header (status + byte count), then that many bytes of
  Annex-B H.264 if status is 0.
- NV12 only, matching what a real Codec2 encoder input buffer (`GRALLOC_USAGE_HW_VIDEO_ENCODER`)
  should look like — not the RGBA SurfaceFlinger composited buffer the Tier 3 real-gralloc spike
  found (that was the wrong kind of buffer for this exact reason, see that tier's README).

**Decode** (`DecodeRequest`/`DecodeResponse`, added in Tier 7 — see that section below):
- **Request**: tag, then a plain `write()` of a `DecodeRequest` header (width/height hints,
  bitstream size), then exactly `bitstream_size` bytes of Annex-B H.264 — no `SCM_RIGHTS` at all,
  since there's no client dma-buf to import on the way in (the daemon's own decode surface is
  driver-allocated).
- **Response**: a `DecodeResponse` header (status + frame size), then that many bytes of
  tightly-packed NV12 if status is 0.
- The daemon does its own NAL splitting/parsing internally and derives the real width/height from
  the stream's own SPS — the request's width/height are hints only, cross-checked (not trusted)
  against what the SPS actually says.

## Build & run

A `Makefile` now covers this (it used to be a plain `gcc` one-liner, kept below for the two
standalone test clients, which still build that way):

```sh
# The daemon itself -- encode's own deps (libva/libva-drm/libgbm/libEGL) plus -ldl for NVIDIA
# decode's own lazy libvulkan.so.1 loading (see "Two backends, one daemon" above).
make                 # daemon without hwdec (vendor-agnostic decode, 5.15) or the ffmpeg encode backend (5.16)
make HWDEC=1 daemon  # adds both -- needs libavcodec/libavutil (pkg-config) and libdrm too

gcc -O2 -Wall -o test-client test-client.c $(pkg-config --cflags --libs libdrm)
gcc -O2 -Wall -o decode-test-client decode-test-client.c

sudo mkdir -p /dev/vaapi-helper && sudo chmod 777 /dev/vaapi-helper   # first run only

./daemon &          # listens on /dev/vaapi-helper/socket; logs which backend(s) initialized
./test-client       # encode: builds a synthetic dma-buf, sends it, writes out.h264
ffprobe out.h264 && ffmpeg -i out.h264 -f null -

# decode: needs a real Annex-B stream first, see decode-test-client.c's own error message
# for the exact ffmpeg invocation if /tmp/test.h264 doesn't exist yet
./decode-test-client
```

## Result

`test-client` (host-side only, no Android involved at this checkpoint) builds the same synthetic
NV12 DRM dumb buffer as `tier3-dmabuf-import`, sends it over the socket, and gets back **69 bytes,
byte-for-byte identical to `tier2-vaapi-encode`'s own reference output** — confirmed decodable.
Ran the client twice against the same long-lived daemon process to confirm the persistent VA-API
context (created once at startup, reused per request, only recreated if the resolution changes)
survives repeated requests correctly.

## 5.3: confirmed working from inside Android too

`android-test-client/` is the same protocol/test logic, built via Soong (`cc_binary`, `vendor:
true`) against the AOSP tree directly — no NDK needed, bionic handles `AF_UNIX`/`SCM_RIGHTS`/
`libdrm` identically to glibc here, no surprises. Bind-mounted the daemon's socket directory
(`/dev/vaapi-helper`) into a redroid test container the same way these containers already bind-
mount `/dev/binder`, pushed the built binary to `/data/local/tmp` (writable at runtime, unlike
`/vendor` which is genuinely read-only once Android has booted — see `DEVLOG.md` for the deploy
lessons), and ran it via `docker exec`. Result: **69 bytes, byte-for-byte identical to Tier 2's
reference output**, this time originating from a binary actually running inside Android.

## 5.4: confirmed against a real Android gralloc buffer

`android-test-client/real_gralloc_client.c` allocates a genuine gralloc buffer via
`AHardwareBuffer_allocate(AHARDWAREBUFFER_USAGE_VIDEO_ENCODE)` and gets its dma-buf fd via
`AHardwareBuffer_getNativeHandle()` (`libnativewindow` is LLNDK, explicitly meant for vendor code
to link against) — no more scavenging another process's fd like Tier 3's original real-gralloc
spike had to. Two real findings along the way (neither a blocker, see `DEVLOG.md` for the full
story): this build's Mapper HAL doesn't implement `AHardwareBuffer_lockPlanes()` (worked around
with a plain `mmap()` of the dma-buf fd instead), and requesting flexible YUV420 actually returns
an RGBA8888-sized buffer — plus one real fix: the tightly-packed stride `AHardwareBuffer_describe()`
reports fails VA-API import outright (`"resource allocation failed"`, isolated to a pitch
alignment requirement, not the buffer's origin), fixed by filling/describing the buffer with an
aligned stride instead. Result: another **69 bytes, byte-for-byte identical to Tier 2's reference
output**, this time encoded from a real Android-allocated gralloc buffer.

## 5.5: a real C2Component, driven through the genuine framework machinery

`codec2-component/VaapiEncComponent.{h,cpp}` is a real `C2Component` built on
`SimpleC2Component` (the same base class AOSP's own software codecs use, e.g. the stock
`c2.android.avc.encoder` Tier 0's fix unlocked) rather than porting `external/v4l2_codec2`'s much
larger `EncodeComponent` verbatim — that reference's `VideoEncoder` interface is built for V4L2's
async, interrupt-driven model, which doesn't fit this daemon's simple synchronous round trip, and
even the reference project itself has no complete example wiring it end to end. `process()`
extracts the input `C2GraphicBlock`'s dma-buf fd via `block.handle()->data[0]` (the same pattern
`v4l2_codec2`'s own `createInputFrame()` uses), sends it to the daemon, and writes the H.264 bytes
back via `createLinearBuffer()` — a helper `SimpleC2Component` already provides. `service.cpp`'s
`createComponent()`/`createInterface()` now construct real instances of this instead of returning
`C2_NOT_FOUND`.

`codec2-component/component_test.cpp` drives it with a **real** `C2Work` wrapping a **real**
`C2GraphicBlock` — built via `_C2BlockFactory::CreateGraphicBlock(AHardwareBuffer*)`, a genuine
AOSP API for wrapping an app-provided `AHardwareBuffer` into Codec2 (the same mechanism real
Surface-based encoder input eventually goes through) — through the actual
`queue_nb()`/`process()`/`onWorkDone_nb()` machinery, not a hand-rolled shortcut. Result: **83
bytes of valid, decodable H.264** (a different byte count than every other tier's 69/70 is
expected here — this test didn't fill the buffer with the usual flat-128 pattern, so it's
compressing real uninitialized memory content instead of a known test pattern).

## 5.6–5.12: hardening encode across real GPUs

Getting a real, unmodified app (`scrcpy`) recording correct video through the genuine
`MediaCodec`/`Codec2Client` framework path — not just a hand-built `C2Work` — surfaced a run of
real, GPU-specific bugs: HAL registration/instance-naming gaps, AMD VCN's DCC-compression
restriction (`AMD_DEBUG=nodcc`), the discovery that a real `Surface`-sourced frame is RGBA (not
NV12) and needs a VPP conversion stage, a GPU-generation-specific DRM format modifier that can't
be queried from the Android side at all (so it's determined once at daemon startup instead — see
`rgba_modifier_init()` in `daemon.c`), an Intel-specific tiling-priority difference from AMD, and
an older AMD generation (Polaris/GFX8) that can't describe its tiling as a modifier at all and
needs VA-API's old, pre-modifier import path. All of it lives in this daemon, none of it touches
the Android-side component — see the top-level `README.md`'s hardware compatibility table and
`DEVLOG.md` for the full, bug-by-bug story.

## 5.14: P frames for the legacy encoder (`REDROID_FORGE_ENCODE_IDR_PERIOD`)

By default every frame from the original hand-rolled encoder is an IDR (all-intra: stateless,
simple, but it compresses far worse than any normal encoder — on busy content at 8 Mbps the QP
climbs to 30–48). `REDROID_FORGE_ENCODE_IDR_PERIOD=N` (N > 1; 120 is about 2 s at 60 fps) makes
an IDR every N frames and **P frames in between** (one reference frame, no B frames, so no
reordering or extra latency). Off by default until validated on every GPU.

- A request has no stream identity of its own, but the process sending it is known from the
  socket (`SO_PEERCRED`): every redroid instance runs its own encoder service, so
  `(pid, width, height)` identifies the stream — the protocol and the Android component did not
  need to change. One stream at a time holds the reference; a frame from another stream, a
  resolution change, a pause longer than 1.5 s, or a failed frame forces an IDR (always correct —
  two interleaved streams simply stay all-intra). The policy lives in `gop.h`, with its own test:
  `cc -O2 -o /tmp/gop-test test/gop-test.c -I. && /tmp/gop-test`.
- Two reconstruction surfaces alternate (the previous one is the reference of the next); the P
  slice header is written by hand the same way the IDR one is (`nal_unit_type` 1, `frame_num`
  modulo 16, sliding-window reference marking, `cabac_init_idc` 0).
- Rate control: an IDR may use 3x the budget of a frame (not counted as debt), and a P frame's
  complexity is estimated separately from the intra one (`ratectl.h`, `gop` field). Check the
  controller on its own with `cc -O2 -o /tmp/ratectl-test test/ratectl-test.c -I. -lm &&
  /tmp/ratectl-test`.
- `REDROID_FORGE_ENCODE_INTRA_ONLY=1` forces the old behaviour even with a period set.

Measured on Polaris (RX 480, VCE) with a scrolling-screen scenario (2 Mbps asked, 2.49 Mbps
reaching the daemon): all-intra delivered 2.35 Mbps at **QP 31**; with P frames, 1.59 Mbps at
**QP 14** (the quality floor — the content fits the budget at the best quality). An 18 s scrcpy
capture: 525 P frames and 5 IDR, no decode errors with `ffmpeg -err_detect aggressive+explode`,
Constrained Baseline, 1 reference.

| GPU (entrypoint) | all-intra | P frames | recording |
|---|---|---|---|
| RX 480 (EncSlice) | 2.35 Mbps, QP 31 | 1.59 Mbps, QP 14 | decodes clean |
| Ryzen 5700G (EncSlice) | 2.4 Mbps, QP 31 | 1.12 Mbps, QP 14 | decodes clean |
| Iris Xe (iHD, EncSlice) | 2.39 Mbps, QP 33 | 0.7 Mbps, QP 14 | **broken**: 520 of ~880 frames fail (`top block unavailable for requested intra mode`) |

On Iris Xe the P frames do not decode correctly (cause not identified — could be the hand-written
slice header itself, or how the iHD driver uses it), so the daemon refuses P frames on the Intel
driver by default (`REDROID_FORGE_ENCODE_P_ON_INTEL=1` forces them, for whoever wants to dig into
why). This is the bug that motivated 5.16's ffmpeg backend.

## 5.15: vendor-agnostic hardware decode (`hwdec.c`)

A second, independent decode path (`hwdec.c`/`hwdec.h`), separate from Tier 7's NVIDIA-only one:
libavcodec + VA-API decode for **AMD and Intel**, serving H.264, HEVC, VP9 and more to the Android
Codec2 components (not just this project's own screen-streaming path) through two new protocol
commands, `VAAPI_CMD_HWDEC` (a persistent connection per stream, one thread per session) and
`VAAPI_CMD_HWDEC_CAPS` (what the host can decode).

Design rules:
- **Everything the host offers is used in hardware.** `hwdec_probe()` asks VA-API what the DRM
  node decodes (without even touching libavcodec), and `hwdec_open()` only opens sessions for
  those codecs.
- **No silent fallback to software.** If the hardware cannot handle the stream, the session fails
  and the caller (the Android-side component) falls back to its own software decoder.
- **A stateful session**: one access unit per `hwdec_send()`; `hwdec_receive()` returns the
  already-reordered frames (B-frames included), one at a time. Output is compact NV12 (8-bit) or
  P010 (10-bit).
- **Frame transport**: a client that sets `VAAPI_HWDEC_OPEN_SHM` in `HwDecOpenRequest.flags`
  receives a `memfd` (512 MiB virtual, only what the frames actually write is resident) attached
  to the open response through `SCM_RIGHTS`; every frame is downloaded straight into it and the
  frame headers carry no payload. The frames of one response overwrite the next, so the client
  copies them before its next request. Without the flag, frames travel inline through the socket,
  as before.

Verified by decoding the same clips in software (ffmpeg) and in hardware (`hwdec-test`) and
comparing frame by frame in output order (`test/hwdec-verify.sh` for the standalone daemon-less
checkpoint, `test/hwdec-stream-verify.sh` for the real protocol, through the daemon):

| GPU (driver) | H.264 720p | H.264 1080p | HEVC 4K 10-bit | VP9 4K 10-bit |
|---|---|---|---|---|
| Polaris RX 480 (radeonsi) | ✓ | ✓ | ✓ | rejected: no hardware |
| Iris Xe (iHD) | ✓ | ✓ | ✓ | ✓ |
| Vega 8 of the 5700G (radeonsi) | ✓ | ✓ | ✓ | ✓ |

What `hwdec_probe()` advertises per GPU: Polaris: h264, hevc (+10), mpeg2, vc1. Vega 8: h264, hevc
(+10), vp9 (+10), mpeg2, vc1. Iris Xe (iHD 26.2): h264, hevc (+10), vp9 (+10), vp8, mpeg2, vc1,
**av1** (+10); AV1 and VP8 are advertised but untested (no clips available for them).

Needs its own LGPL-only libavcodec/libavutil build (`--disable-gpl`, no libx264/avformat/
avfilter/etc. — see the parent project's `Dockerfile` for the exact `./configure` flags): Alpine's
own `ffmpeg` package is built `--enable-gpl` for its other users, and FFmpeg's own licensing
terms make the *whole* library GPL once that flag is on, regardless of which encoder/decoder a
given program actually calls.

## 5.16: the ffmpeg/`h264_vaapi` encode backend (fixes the Intel P-frame bug)

A second, independent **encode** backend, alongside the original hand-rolled bitstream one from
5.2–5.12: `ffmpeg_encode.c`/`ffmpeg_encode.h`, built on libavcodec's `h264_vaapi` encoder instead
of writing the slice header by hand. Directly motivated by 5.14's unsolved Iris Xe P-frame bug —
rather than debug the hand-written slice header further, hand the whole job to a real encoder
that already knows how to do it correctly.

Selectable per host via `REDROID_FORGE_ENCODE_BACKEND=legacy` (default, the 5.2–5.13 path) or
`=ffmpeg` (this one) — not a build-time choice, both are compiled in whenever `HWDEC=1` (they
share the same libavcodec/libavutil build as 5.15's `hwdec.c`).

This module owns its own, independent `VADisplay` (same DRM render node as the rest of the
daemon's `st->dpy`, but a separate `vaInitialize()`), instead of sharing `st->dpy` directly:
`VASurfaceID`s are not valid across `VADisplay` instances, so the existing NV12 surface
(populated by the daemon's own RGBA→NV12 VPP step, unchanged) has to be downloaded to a plain RAM
buffer first and handed over as bytes — `ffmpeg_encode_frame()` does that download itself. One
extra GPU↔RAM round trip per frame, in exchange for a simple, fully decoupled integration that
cannot fight the legacy path over VA-API config/context lifetime — a deliberate simplification
for this first cut, not a limit of VA-API/ffmpeg itself.

**Fixes the Iris Xe P-frame bug from 5.14**: encodes P frames correctly there. Also validated on
AMD Cezanne-family APUs (Ryzen 5700G). **Not yet safe on AMD Polaris (RX 400/500)**: real GPU
hangs during validation — a soft timeout with recovery, a full GPU reset (BACO) with a VM fault,
and one hang with visible corruption that needed a host reboot — both in a synthetic stress test
and in real scrcpy use. Root cause not identified (a small VA surface pool and two concurrent
sessions were both checked and ruled out as the sole cause). Polaris keeps using the legacy
(5.2–5.13) path, which stays solid there — the two known-risky combinations (`ffmpeg` on Polaris,
`legacy` on Intel) are warned about, never silently picked, by whatever integrates this daemon
(the parent redroid-forge project does it per-host, in Settings/instance creation/Doctor).

## Two backends, one daemon

`daemon.c`'s `main()` initializes encode (`vaapi_state_init()`) and decode (`decode_h264_init()`)
independently and neither failure is fatal by itself — only both failing together means the
daemon has nothing to do. This matters because the two backends target different vendors: every
encode-capable host tested so far is AMD/Intel, and the only decode-capable host is NVIDIA (no
GPU tested here does both). `handle_connection()` dispatches on the command tag and each handler
checks its own backend's availability, rejecting cleanly (a normal error response) rather than
crashing if that backend never initialized on this host.

One subtlety worth knowing if you're reading `decode_h264_init()`: `nvidia-vaapi-driver` isn't
something libva's own auto-detection resolves to for an NVIDIA render node by itself, so that
function scopes `LIBVA_DRIVER_NAME=nvidia` to just its own `vaInitialize()` call (save the
previous value, force it, initialize, restore it) — so it doesn't clobber the encode backend's own
`vaInitialize()` call in the same process, regardless of which one `main()` happens to run first.

## Tier 7: NVIDIA decode

`decode_h264.c`/`decode_h264.h` port the standalone decode spike
([`tier6-vaapi-decode/main.c`](../tier6-vaapi-decode/), see its own README for the full six-bug
trail to bit-exact) into the persistent-state shape this daemon needs: `decode_h264_init()` (once,
at startup) and `decode_h264_frame()` (once per request — parses whatever SPS/PPS/IDR NALs are in
the buffer it's given, decodes, de-tiles via the same Vulkan technique this project's own NVENC
encode work uses, and hands back tightly-packed NV12 plus the width/height it read out of the
SPS). `decode-test-client.c` is decode's own standalone checkpoint, the same role `test-client.c`
plays for encode.

**Verified on two real hosts in the same session**: on a GTX 1050 Ti (no AMD/Intel GPU at all),
the daemon correctly disabled encode and served decode — a fresh `ffmpeg`-generated H.264 stream
decoded through the real socket protocol came back bit-exact against software decode (`ffmpeg`'s
own PSNR filter: `y:inf u:inf v:inf average:inf`). On an AMD Renoir APU (no NVIDIA GPU), the
daemon correctly initialized encode and failed decode init cleanly (no `nvidia-vaapi-driver`
package there), and the `VAAPI_CMD_ENCODE` tag round-tripped correctly against the existing encode
path (confirmed via the daemon's own request log matching `test-client.c`'s real request fields
exactly) — proving the new tag/dispatch layer doesn't disturb encode's own wire format.

The Codec2 side lives in `codec2-component/VaapiDecComponent.{h,cpp}` — the structural mirror of
`VaapiEncComponent`, registered as `c2.hardware.decoder.h264`. See that pair of files' own header
comments for what differs from the encoder (an `::output` picture-size param instead of `::input`,
`C2PlanarLayout`-aware copying into whatever the real gralloc allocation for the output frame
turns out to be).

## What's next

The daemon-standalone and AOSP-build checkpoints for decode are both done (see Tier 7 above); the
remaining step is the same one Tier 5.6 was for encode: driving `VaapiDecComponent` through the
real `MediaCodec`/`Codec2Client` framework path against a real H.264-containing video source,
instead of a direct socket round-trip. `codec2-component/component_test.cpp`/`client_test.cpp` are
the encode-side precedents to model a decode-side equivalent on.

## Runtime options (environment variables)

These names kept the `REDROID_FORGE_` prefix they were given while this code lived only inside
the `redroid-forge` integration (same binary, same compiled behaviour either way) — not renamed
here to avoid touching tested, working source for a cosmetic reason.

| Variable | Effect |
|---|---|
| `REDROID_FORGE_DRM_NODE` | DRM render node to use (default `/dev/dri/renderD128`). |
| `REDROID_FORGE_VAAPI_SOCKET` | Socket path (default `/dev/vaapi-helper/socket`). |
| `REDROID_FORGE_ENCODE_BACKEND` | `legacy` (default, 5.2–5.13's hand-rolled bitstream) or `ffmpeg` (5.16, libavcodec `h264_vaapi`). |
| `REDROID_FORGE_ENCODE_IDR_PERIOD` | Legacy backend only (5.14). Frames per IDR; > 1 turns P frames on. Default 1: all-intra. |
| `REDROID_FORGE_ENCODE_INTRA_ONLY` | Legacy backend only. `1` forces all-intra even if a period is set. |
| `REDROID_FORGE_ENCODE_P_ON_INTEL` | Legacy backend only. `1` forces P frames on Intel despite the known-broken decode (5.14) — for whoever wants to debug it. |
| `REDROID_FORGE_ENCODE_STATS` | If set, prints the real encoded bitrate (against the target) every 5 s, and the IDR/P frame counts. |
| `REDROID_FORGE_HWDEC_DOWNLOAD` | 5.15 only. How a decoded frame is brought from the GPU to RAM: `derive-sse` (default), `derive`, `getimage`, or `ffmpeg`. The first frame of every session is cross-checked against the ffmpeg path regardless; a mismatch falls that whole session back to it. |
| `REDROID_FORGE_HWDEC_STATS` | 5.15 only. Prints per-stage timing (send, GPU wait, download, copy) per session, plus daemon-wide wait/queue/socket averages. |
| `REDROID_FORGE_HWDEC_DEBUG` | 5.15 only. Logs the first bytes of every access unit received, to see how Android delivered it. |
