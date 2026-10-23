#!/bin/bash
# Builds atvpadd (Bluetooth gamepad daemon) for the Apple TV 2 and 3. Run inside WSL or Linux: bash atvpad/build.sh
set -e
cd "$(dirname "$0")"
B=$HOME/atv/btstack
[ -d "$B" ] || git clone -q https://github.com/bluekitchen/btstack.git "$B"
SRC="$B/src/btstack_memory.c $B/src/btstack_linked_list.c $B/src/btstack_memory_pool.c $B/src/btstack_run_loop.c
 $B/src/btstack_util.c $B/src/hci.c $B/src/hci_cmd.c $B/src/hci_dump.c $B/src/hci_event.c $B/src/l2cap.c
 $B/src/l2cap_signaling.c $B/src/btstack_tlv.c $B/src/ad_parser.c $B/src/btstack_hid_parser.c
 $B/src/btstack_hid.c $B/src/hci_transport_h4.c
 $B/src/classic/sdp_util.c $B/src/classic/sdp_server.c $B/src/classic/sdp_client.c $B/src/classic/hid_host.c
 $B/src/classic/btstack_link_key_db_tlv.c
 $B/platform/posix/btstack_run_loop_posix.c $B/platform/posix/btstack_tlv_posix.c $B/platform/posix/hci_dump_posix_fs.c"
INC="-include compat_ios6.h -I. -I$B/src -I$B/platform/posix -I$B/3rd-party/micro-ecc"
mkdir -p obj
OBJS=""
for f in $SRC; do
  o=obj/$(basename "${f%.c}").o; OBJS="$OBJS $o"
  [ "$o" -nt "$f" ] && [ "$o" -nt btstack_config.h ] || ../toolchain/atv-cc -O2 -w $INC -c "$f" -o "$o" &
done
wait
../toolchain/atv-cc -O2 -Wall -Wno-unused-function $INC atvpadd.c btstack_uart_atv.c atv_uart.c $OBJS -o atvpadd
echo built atvpadd
