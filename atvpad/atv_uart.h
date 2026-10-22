// Opens the Apple TV 2 Bluetooth UART the way BTServer does on iOS 4+: through a
// PF_NETGRAPH socket bound to the "com.apple.uart.bluetooth" node (values reversed by BTstack's old iOS port).
// Returns a read/write fd configured raw at `baud` with RTS/CTS, or -1.
#ifndef ATV_UART_H
#define ATV_UART_H
int atv_uart_open(unsigned baud);
#endif
