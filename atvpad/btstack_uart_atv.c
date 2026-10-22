// BTstack block UART driver over the ATV2's netgraph Bluetooth UART socket (see atv_uart.c).
// The socket isn't a tty, so baud/parity/flow control are fixed at open time.
//
// The kernel drops incoming bytes if the socket isn't drained quickly (a short stall in the run loop,
// e.g. flash I/O while storing a link key, was enough to break H4 framing). So a dedicated thread
// does nothing but move bytes from the socket into a pipe, and the run loop reads from the pipe.
// Writes go straight to the socket.
//
// Bytes still get lost below us now and then (always during connection setup), which used to
// desynchronize BTstack's H4 parser and kill the daemon. So the reader thread frames H4 itself,
// sanity-checks each packet (atv_h4_frame) and on garbage skips ahead until packets line up again;
// only whole, plausible packets reach the pipe. A damaged packet costs one HID report.
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "btstack_uart.h"
#include "btstack_run_loop.h"
#include "btstack_debug.h"
#include "atv_uart.h"

static const btstack_uart_config_t *config;
static int uart_fd = -1;
static int pipe_fds[2] = { -1, -1 };
static btstack_data_source_t read_ds, write_ds;
static const uint8_t *write_data;
static uint16_t write_len;
static uint8_t *read_data;
static uint16_t read_len;
static void (*block_sent)(void);
static void (*block_received)(void);

// Length of the H4 packet at b (have bytes available): >0 complete packet, 0 need more bytes, -1 garbage.
int atv_h4_frame(const uint8_t *b, size_t have) {
    if (have < 1) return 0;
    if (b[0] == 0x04) {  // event: type, code, len
        if (have < 3) return 0;
        if (b[1] == 0x00 || (b[1] > 0x58 && b[1] != 0xff)) return -1;
        return have >= 3u + b[2] ? 3 + b[2] : 0;
    }
    if (b[0] == 0x02) {  // ACL: type, handle+flags (2), len (2), payload
        if (have < 5) return 0;
        unsigned len = b[3] | b[4] << 8, pb = (b[2] >> 4) & 3, bc = b[2] >> 6;
        if (len == 0 || len > 1021 || bc != 0) return -1;
        if (pb == 2) {  // first fragment starts with the L2CAP header: length, channel id
            if (len < 4) return -1;
            if (have < 9) return 0;
            unsigned l2len = b[5] | b[6] << 8, cid = b[7] | b[8] << 8;
            if (l2len + 4 < len || cid == 0) return -1;
        }
        return have >= 5 + len ? (int)(5 + len) : 0;
    }
    return -1;
}

static int write_all(int fd, const uint8_t *p, size_t n) {
    while (n) {
        ssize_t w = write(fd, p, n);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return -1;
        p += w; n -= w;
    }
    return 0;
}

static void *reader_thread(void *arg) {
    static uint8_t buf[8192];
    size_t have = 0, dropped = 0;
    for (;;) {
        ssize_t n = read(uart_fd, buf + have, sizeof buf - have);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { log_error("uart reader: %d", errno); break; }
        have += n;
        size_t pos = 0;
        for (;;) {
            int len = atv_h4_frame(buf + pos, have - pos);
            if (len == 0) break;
            if (len < 0) { pos++; dropped++; continue; }
            if (dropped) { fprintf(stderr, "uart: lost sync, skipped %zu bytes\n", dropped); dropped = 0; }
            if (write_all(pipe_fds[1], buf + pos, len) != 0) { log_error("uart pipe: %d", errno); return NULL; }
            pos += len;
        }
        memmove(buf, buf + pos, have - pos);
        have -= pos;
    }
    return NULL;
}

static void process_read(btstack_data_source_t *s, btstack_data_source_callback_type_t type) {
    if (!read_len) return;
    ssize_t n = read(s->source.fd, read_data, read_len);
    if (n <= 0) return;  // EAGAIN
    read_data += n; read_len -= n;
    if (read_len == 0) {
        btstack_run_loop_disable_data_source_callbacks(s, DATA_SOURCE_CALLBACK_READ);
        block_received();
    }
}

static void process_write(btstack_data_source_t *s, btstack_data_source_callback_type_t type) {
    if (!write_len) return;
    ssize_t n = write(s->source.fd, write_data, write_len);
    if (n <= 0) { if (n < 0 && errno != EAGAIN) log_error("uart write: %d", errno); return; }
    write_data += n; write_len -= n;
    if (write_len == 0) {
        btstack_run_loop_disable_data_source_callbacks(s, DATA_SOURCE_CALLBACK_WRITE);
        block_sent();
    }
}

static int uart_init(const btstack_uart_config_t *c) { config = c; return 0; }

static int uart_open(void) {
    uart_fd = atv_uart_open(config->baudrate);
    if (uart_fd < 0 || pipe(pipe_fds) != 0) return -1;
    fcntl(pipe_fds[0], F_SETFL, O_NONBLOCK);

    pthread_t t;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    struct sched_param prio = { .sched_priority = sched_get_priority_max(SCHED_FIFO) };
    pthread_attr_setschedpolicy(&attr, SCHED_FIFO);  // best effort: needs root, falls back silently
    pthread_attr_setschedparam(&attr, &prio);
    if (pthread_create(&t, &attr, reader_thread, NULL) != 0 && pthread_create(&t, NULL, reader_thread, NULL) != 0) return -1;
    pthread_detach(t);

    btstack_run_loop_set_data_source_fd(&read_ds, pipe_fds[0]);
    btstack_run_loop_set_data_source_handler(&read_ds, &process_read);
    btstack_run_loop_add_data_source(&read_ds);
    btstack_run_loop_set_data_source_fd(&write_ds, uart_fd);
    btstack_run_loop_set_data_source_handler(&write_ds, &process_write);
    btstack_run_loop_add_data_source(&write_ds);
    return 0;
}

static int uart_close(void) {
    // the daemon only closes the transport on exit; the reader thread dies with the process
    btstack_run_loop_remove_data_source(&read_ds);
    btstack_run_loop_remove_data_source(&write_ds);
    return 0;
}

static void set_block_received(void (*h)(void)) { block_received = h; }
static void set_block_sent(void (*h)(void)) { block_sent = h; }
static int set_baudrate(uint32_t baud) { return baud == config->baudrate ? 0 : -1; }
static int set_parity(int parity) { return parity ? -1 : 0; }
static int set_flowcontrol(int flowcontrol) { return 0; }

static void receive_block(uint8_t *buf, uint16_t len) {
    read_data = buf; read_len = len;
    btstack_run_loop_enable_data_source_callbacks(&read_ds, DATA_SOURCE_CALLBACK_READ);
}

static void send_block(const uint8_t *buf, uint16_t len) {
    write_data = buf; write_len = len;
    btstack_run_loop_enable_data_source_callbacks(&write_ds, DATA_SOURCE_CALLBACK_WRITE);
}

static const btstack_uart_t uart = {
    .init = uart_init, .open = uart_open, .close = uart_close,
    .set_block_received = set_block_received, .set_block_sent = set_block_sent,
    .set_baudrate = set_baudrate, .set_parity = set_parity, .set_flowcontrol = set_flowcontrol,
    .receive_block = receive_block, .send_block = send_block,
};

const btstack_uart_t *btstack_uart_atv_instance(void) { return &uart; }
