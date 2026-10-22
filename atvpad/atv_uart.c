#include "atv_uart.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/socket.h>

#define PF_NETGRAPH     32
#define NG_CONTROL      2
#define NG_NODE_IOCTL   0xC0644E03
#define UART_GETTERMIOS 0x402C7413   // 32-bit values
#define UART_SETTERMIOS 0x802C7414

struct sockaddr_ng { uint8_t sg_len, sg_family; uint16_t sg_subtype; uint32_t sg_node, sg_null; uint8_t sg_dummy[20]; };

int atv_uart_open(unsigned baud) {
    int fd = socket(PF_NETGRAPH, SOCK_STREAM, NG_CONTROL);
    if (fd < 0) { perror("uart socket"); return -1; }
    struct { uint32_t result; char name[96]; } node = {0};
    strcpy(node.name, "com.apple.uart.bluetooth");
    if (ioctl(fd, NG_NODE_IOCTL, &node) != 0) { perror("uart ioctl"); goto fail; }
    struct sockaddr_ng a = { sizeof a, PF_NETGRAPH, 2, node.result, 0 };
    if (connect(fd, (struct sockaddr *)&a, sizeof a) != 0) { perror("uart connect"); goto fail; }
    struct termios t; socklen_t len = sizeof t;
    if (getsockopt(fd, SO_ACCEPTCONN, UART_GETTERMIOS, &t, &len) != 0) { perror("uart getsockopt"); goto fail; }
    cfmakeraw(&t);
    cfsetspeed(&t, baud);
    t.c_iflag |= IGNPAR;
    t.c_cflag = 0x00038b00;  // CS8 | CREAD | CLOCAL | CRTSCTS, as BTServer sets it
    if (setsockopt(fd, SO_ACCEPTCONN, UART_SETTERMIOS, &t, len) != 0) { perror("uart setsockopt"); goto fail; }
    return fd;
fail:
    close(fd);
    return -1;
}
