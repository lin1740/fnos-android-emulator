# Port of tier5-vaapi-daemon (redroid-hwenc): AMD/Intel VA-API encode +
# NVIDIA NVDEC decode, a single host-side process. See this directory's
# README.md for the origin and why it runs outside the Android container.

# -D_FORTIFY_SOURCE=0 (-U is not enough): Alpine's gcc adds _FORTIFY_SOURCE by
# default via specs (a pattern like "%{!D_FORTIFY_SOURCE:-D_FORTIFY_SOURCE=2}" --
# it only checks whether a -D_FORTIFY_SOURCE was ALREADY passed, a -U does not count
# as "already specified" and the spec injects it anyway), and that throws wrappers
# __read_chk/__memcpy_chk/__fprintf_chk over the libc functions -- musl (Alpine's
# libc, where this image runs) never implemented those symbols in its libc.so. The
# binary linked fine but failed at runtime with "no such file or directory" (the
# /lib64/ld-linux... interpreter it asks for does not exist on Alpine either)
# followed by "symbol not found" when forcing the load -- confirmed live on 30/09
# running redroid-forge's Doctor against a freshly built image.
CC ?= gcc
CFLAGS ?= -O2 -Wall -D_FORTIFY_SOURCE=0
LDLIBS := -lva -lva-drm -lgbm -lEGL -ldl -lm

# The Makefile as its own prerequisite: without this, changing CFLAGS (e.g. the
# _FORTIFY_SOURCE fix above) does not trigger a recompilation if the binary already
# exists with a timestamp newer than the .c/.h files -- confirmed live on 30/09, it
# cost quite some debugging time to find out that "make" said "'daemon' is up to
# date" and silently ignored the fix.
# HWDEC=1 adds the vendor-agnostic hardware decode (hwdec.c, libavcodec + VA-API) and, since
# REDROID_FORGE_ENCODE_BACKEND=ffmpeg (ffmpeg_encode.c), the libavcodec h264_vaapi encode
# alternative to the hand-rolled one in daemon.c -- both share the same libavcodec/libavutil
# build (the ffmpeg-lgpl Dockerfile stage), so one flag covers both. NOT the default here: the
# current production build does not need FFmpeg until the image's own LGPL libavcodec exists
# (see docs/ROADMAP.md, Phase 2, step 5) -- the Dockerfile itself passes HWDEC=1.
HWDEC ?= 0
ifeq ($(HWDEC),1)
HWDEC_CFLAGS := -DHAVE_HWDEC $(shell pkg-config --cflags libavcodec libavutil)
HWDEC_SRCS := hwdec.c ffmpeg_encode.c
HWDEC_LIBS := $(shell pkg-config --libs libavcodec libavutil) -lpthread
endif

# libdrm's -I (pkg-config): see the comment of the drm_fourcc.h include in daemon.c.
LIBDRM_CFLAGS := $(shell pkg-config --cflags libdrm 2>/dev/null)

daemon: daemon.c decode_h264.c decode_h264.h protocol.h ratectl.h hwdec.c hwdec.h ffmpeg_encode.c ffmpeg_encode.h Makefile
	$(CC) $(CFLAGS) $(LIBDRM_CFLAGS) $(HWDEC_CFLAGS) -o daemon daemon.c decode_h264.c $(HWDEC_SRCS) $(LDLIBS) $(HWDEC_LIBS)

# Step 1 of hwdecode (docs/ROADMAP.md, Phase 2, step 5): a hardware decode session
# with libavcodec + VA-API, and its test client. Separate from the `daemon` target
# on purpose: it needs FFmpeg's headers (libavcodec/libavformat/libavutil) and libva.
FFMPEG_PKGS := libavcodec libavformat libavutil
hwdec-test: hwdec.c hwdec.h hwdec-test.c hwdec_client.c hwdec_client.h protocol.h Makefile
	$(CC) -O2 -Wall -o hwdec-test hwdec.c hwdec_client.c hwdec-test.c \
	  $(shell pkg-config --cflags --libs $(FFMPEG_PKGS) libva libva-drm)

clean:
	rm -f daemon hwdec-test

.PHONY: clean
