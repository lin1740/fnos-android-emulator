/*
 * Tier 7 checkpoint: host-side test client for the daemon's new decode
 * command. Proves the daemon's decode dispatch (command tag ->
 * DecodeRequest -> raw bitstream bytes -> DecodeResponse -> raw NV12 bytes)
 * works end to end before ever involving Codec2/Android - same "prove the
 * mechanism in isolation first" approach as test-client.c's own encode
 * checkpoint and tier6-vaapi-decode's own standalone spike.
 *
 * Reads a real Annex-B H.264 elementary stream from disk (SPS+PPS+IDR, same
 * shape tier6-vaapi-decode/README.md's own build steps produce) and sends
 * the whole thing as one DecodeRequest - the daemon does its own NAL
 * splitting/parsing internally (see decode_h264.c).
 */

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>

#include "protocol.h"

#define INPUT_FILE "/tmp/test.h264"
#define OUTPUT_FILE "/tmp/decoded_nv12_via_daemon.yuv"
#define WIDTH_HINT 640
#define HEIGHT_HINT 480

int main(void) {
    FILE *in = fopen(INPUT_FILE, "rb");
    if (!in) {
        perror("fopen " INPUT_FILE);
        fprintf(stderr,
                "Generate a test stream first, e.g.:\n"
                "  ffmpeg -y -f lavfi -i testsrc=size=%dx%d:rate=10:duration=2 \\\n"
                "    -c:v libx264 -profile:v baseline -pix_fmt yuv420p /tmp/test_h264.mp4\n"
                "  ffmpeg -y -i /tmp/test_h264.mp4 -c:v copy -bsf:v h264_mp4toannexb \\\n"
                "    -f h264 " INPUT_FILE "\n",
                WIDTH_HINT, HEIGHT_HINT);
        return 1;
    }
    fseek(in, 0, SEEK_END);
    long file_size = ftell(in);
    fseek(in, 0, SEEK_SET);
    unsigned char *bitstream = malloc((size_t)file_size);
    if (fread(bitstream, 1, (size_t)file_size, in) != (size_t)file_size) {
        perror("fread");
        return 1;
    }
    fclose(in);
    printf("Read %ld bytes of Annex-B H.264 from %s\n", file_size, INPUT_FILE);

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

    VaapiCommand cmd = VAAPI_CMD_DECODE;
    if (write(sock_fd, &cmd, sizeof(cmd)) != (ssize_t)sizeof(cmd)) {
        perror("write(command tag)");
        return 1;
    }

    DecodeRequest req = {
        .width = WIDTH_HINT,
        .height = HEIGHT_HINT,
        .bitstream_size = (uint32_t)file_size,
    };
    if (write(sock_fd, &req, sizeof(req)) != (ssize_t)sizeof(req)) {
        perror("write(DecodeRequest)");
        return 1;
    }
    size_t sent = 0;
    while (sent < (size_t)file_size) {
        ssize_t n = write(sock_fd, bitstream + sent, (size_t)file_size - sent);
        if (n <= 0) {
            perror("write(bitstream)");
            return 1;
        }
        sent += (size_t)n;
    }
    printf("Sent DecodeRequest + %ld bytes bitstream, waiting for response...\n", file_size);

    DecodeResponse resp;
    if (read(sock_fd, &resp, sizeof(resp)) != (ssize_t)sizeof(resp)) {
        perror("read(response header)");
        return 1;
    }
    if (resp.status != 0) {
        fprintf(stderr, "Daemon reported an error (status=%d)\n", resp.status);
        return 1;
    }

    unsigned char *frame = malloc(resp.frame_size);
    size_t got = 0;
    while (got < resp.frame_size) {
        ssize_t n = read(sock_fd, frame + got, resp.frame_size - got);
        if (n <= 0) {
            perror("read(response body)");
            return 1;
        }
        got += (size_t)n;
    }

    FILE *out = fopen(OUTPUT_FILE, "wb");
    fwrite(frame, 1, resp.frame_size, out);
    fclose(out);
    printf("\n*** Received %u bytes of NV12 from the daemon, wrote %s ***\n", resp.frame_size,
           OUTPUT_FILE);
    printf("Verify against software decode, e.g.:\n"
           "  ffmpeg -y -i %s -f rawvideo -pix_fmt nv12 -frames:v 1 /tmp/reference_nv12.yuv\n"
           "  ffmpeg -f rawvideo -pix_fmt nv12 -s %dx%d -i %s \\\n"
           "    -f rawvideo -pix_fmt nv12 -s %dx%d -i /tmp/reference_nv12.yuv \\\n"
           "    -lavfi psnr -f null -\n",
           INPUT_FILE, WIDTH_HINT, HEIGHT_HINT, OUTPUT_FILE, WIDTH_HINT, HEIGHT_HINT);

    free(frame);
    free(bitstream);
    close(sock_fd);
    return 0;
}
