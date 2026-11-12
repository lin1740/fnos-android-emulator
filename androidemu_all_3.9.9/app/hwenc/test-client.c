/*
 * Tier 5.2 checkpoint: host-side test client for the VA-API encode daemon.
 * Proves the socket protocol works end to end (dma-buf fd passed via
 * SCM_RIGHTS, encode happens on the daemon side, bytes come back) before
 * ever involving Android -- same "prove the mechanism in isolation first"
 * approach as tier2/tier3.
 *
 * Uses the same synthetic DRM dumb buffer as tier3-dmabuf-import to avoid
 * needing a real gralloc buffer for this checkpoint; the flat fill value
 * matches tier2's so the expected decoded pixel value (130, from QP26
 * quantization) is already known.
 */

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>

#include <xf86drm.h>
#include <xf86drmMode.h>

#include "protocol.h"

#define WIDTH 320
#define HEIGHT 240
#define FILL_VALUE 128
#define DRM_PRIMARY_DEVICE "/dev/dri/card0"
#define OUTPUT_FILE "out.h264"

int main(void) {
    int drm_fd = open(DRM_PRIMARY_DEVICE, O_RDWR);
    if (drm_fd < 0) {
        perror("open " DRM_PRIMARY_DEVICE);
        return 1;
    }

    uint32_t handle = 0, stride0 = 0;
    uint64_t dumb_size = 0;
    if (drmModeCreateDumbBuffer(drm_fd, WIDTH, HEIGHT * 3 / 2, 8, 0, &handle, &stride0, &dumb_size) != 0) {
        perror("drmModeCreateDumbBuffer");
        return 1;
    }
    int dmabuf_fd = -1;
    if (drmPrimeHandleToFD(drm_fd, handle, DRM_CLOEXEC | DRM_RDWR, &dmabuf_fd) != 0) {
        perror("drmPrimeHandleToFD");
        return 1;
    }

    uint32_t offset_uv = stride0 * HEIGHT;
    void *map = mmap(NULL, dumb_size, PROT_READ | PROT_WRITE, MAP_SHARED, dmabuf_fd, 0);
    if (map == MAP_FAILED) {
        perror("mmap");
        return 1;
    }
    for (unsigned int row = 0; row < HEIGHT; row++)
        memset((unsigned char *)map + row * stride0, FILL_VALUE, WIDTH);
    for (unsigned int row = 0; row < HEIGHT / 2; row++)
        memset((unsigned char *)map + offset_uv + row * stride0, FILL_VALUE, WIDTH);
    munmap(map, dumb_size);

    printf("Test buffer: %dx%d NV12, stride=%u, dma-buf fd=%d, size=%lu\n",
           WIDTH, HEIGHT, stride0, dmabuf_fd, (unsigned long)dumb_size);

    int sock_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sock_fd < 0) {
        perror("socket");
        return 1;
    }
    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, VAAPI_DAEMON_SOCKET_PATH, sizeof(addr.sun_path) - 1);
    if (connect(sock_fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        perror("connect");
        fprintf(stderr, "Is the daemon running (listening on %s)?\n", VAAPI_DAEMON_SOCKET_PATH);
        return 1;
    }

    /* Tier 7: every connection now starts with a 4-byte command tag, read by
     * the daemon via a plain read() before it touches either command's own
     * request struct - see protocol.h's own top comment. */
    VaapiCommand cmd = VAAPI_CMD_ENCODE;
    if (write(sock_fd, &cmd, sizeof(cmd)) != (ssize_t)sizeof(cmd)) {
        perror("write(command tag)");
        return 1;
    }

    EncodeRequest req = {
        .width = WIDTH,
        .height = HEIGHT,
        .stride_y = stride0,
        .stride_uv = stride0,
        .offset_uv = offset_uv,
        .dmabuf_size = (uint32_t)dumb_size,
    };

    char cmsg_buf[CMSG_SPACE(sizeof(int))];
    struct iovec iov = {.iov_base = &req, .iov_len = sizeof(req)};
    struct msghdr msg = {0};
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = cmsg_buf;
    msg.msg_controllen = sizeof(cmsg_buf);

    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
    cmsg->cmsg_level = SOL_SOCKET;
    cmsg->cmsg_type = SCM_RIGHTS;
    cmsg->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(cmsg), &dmabuf_fd, sizeof(int));

    if (sendmsg(sock_fd, &msg, 0) < 0) {
        perror("sendmsg");
        return 1;
    }
    printf("Sent EncodeRequest + dma-buf fd to daemon, waiting for response...\n");

    EncodeResponse resp;
    if (read(sock_fd, &resp, sizeof(resp)) != (ssize_t)sizeof(resp)) {
        perror("read(response header)");
        return 1;
    }
    if (resp.status != 0) {
        fprintf(stderr, "Daemon reported an error (status=%d)\n", resp.status);
        return 1;
    }

    unsigned char *coded = malloc(resp.coded_size);
    size_t got = 0;
    while (got < resp.coded_size) {
        ssize_t n = read(sock_fd, coded + got, resp.coded_size - got);
        if (n <= 0) {
            perror("read(response body)");
            return 1;
        }
        got += n;
    }

    FILE *out = fopen(OUTPUT_FILE, "wb");
    fwrite(coded, 1, resp.coded_size, out);
    fclose(out);
    printf("\n*** Received %u bytes of H.264 from the daemon, wrote %s ***\n",
           resp.coded_size, OUTPUT_FILE);
    printf("Verify with: ffprobe %s && ffmpeg -i %s -f null -\n", OUTPUT_FILE, OUTPUT_FILE);

    free(coded);
    close(sock_fd);
    close(dmabuf_fd);
    return 0;
}
