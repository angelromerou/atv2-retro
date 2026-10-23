// atvpadd: Bluetooth gamepad daemon for the Apple TV 2 and 3.
// Takes the Bluetooth chip over from Apple's BTServer, runs BTstack as a Classic HID host,
// pairs/accepts gamepads (DualShock 4, DualSense, most classic-BT pads) and forwards their
// buttons to the running atvdev app as UDP packets (sdk/atvremote.h). PS/Home quits the app.
//
// Usage: atvpadd [-d]    run the daemon (launchd does this); -d writes /tmp/atvpadd.pklg (HCI trace)
//        atvpadd pair    tell the running daemon to look for a controller in pairing mode (~30 s)
//        atvpadd selftest
#include <assert.h>
#include <stdarg.h>
#include <sys/time.h>
#include <fcntl.h>
#include <notify.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <arpa/inet.h>

#include "btstack_config.h"
#include "btstack_event.h"
#include "btstack_hid_parser.h"
#include "btstack_memory.h"
#include "btstack_run_loop.h"
#include "gap.h"
#include "hci.h"
#include "hci_dump.h"
#include "hci_transport_h4.h"
#include "l2cap.h"
#include "classic/hid_host.h"
#include "classic/sdp_server.h"
#include "btstack_run_loop_posix.h"
#include "btstack_tlv_posix.h"
#include "hci_dump_posix_fs.h"
#include "classic/btstack_link_key_db_tlv.h"
#include "../sdk/atvremote.h"

#define PAIR_NOTIFICATION ATVPAD_PAIR_NOTIFICATION
#define TLV_DIR "/var/mobile/Library/atvpad"
// BlueTool boots the chip at the device-tree 3 Mbaud; at that speed the UART occasionally overruns
// during connection setup (lost bytes break H4 framing), so bt_power_on() drops it to this.
#define UART_BAUD 921600
#define INQUIRY_SECONDS 30

const btstack_uart_t *btstack_uart_atv_instance(void);
int atv_h4_frame(const uint8_t *b, size_t have);

// printf with a wall-clock prefix (the log is how reconnect timing gets diagnosed)
static void logf_ts(const char *fmt, ...) {
    struct timeval tv; gettimeofday(&tv, NULL);
    struct tm tm; localtime_r(&tv.tv_sec, &tm);
    printf("%02d:%02d:%02d.%03d ", tm.tm_hour, tm.tm_min, tm.tm_sec, (int)(tv.tv_usec / 1000));
    va_list ap; va_start(ap, fmt); vprintf(fmt, ap); va_end(ap);
}

typedef struct {
    uint16_t cid;      // 0 = free slot
    bool sony;         // DualShock 4 / DualSense button order
    uint32_t buttons;  // bit n = ATVPAD button n held
    bool seen_report;  // first report only sets the baseline (the PS press that woke the pad isn't a press)
    bool have_descriptor;
    uint32_t connected_ms;
} pad_t;

static pad_t pads[ATVPAD_MAX_PLAYERS];
static uint8_t hid_descriptor_storage[4 * 512];
static btstack_packet_callback_registration_t hci_callback;
static btstack_tlv_posix_t tlv_context;
static btstack_data_source_t pair_source;
static bd_addr_t pair_target;
static bool pair_target_found;
static int udp_sock = -1;
// Fast page scan so a pad's reconnect page is heard quickly: interlaced, 160 ms interval, 22.5 ms window
// (mains powered, so the extra radio time is free; Wi-Fi shares the antenna, so not continuous).
// (gap_set_page_scan_* didn't reach the controller here, so these are sent after startup, chained.)
// Don't enable the chip's UART sleep mode (Broadcom 0xfc27) here: with it the kernel panicked
// ("PIO read timeout"), apparently touching the power-gated UART.
static bool page_scan_pending;
static const hci_cmd_t write_page_scan_activity = { 0x0c1c, "22" };
static const hci_cmd_t write_page_scan_type = { 0x0c47, "1" };
static const hci_cmd_t read_page_scan_activity = { 0x0c1b, "" };  // logged to verify
static bd_addr_t pad_addr[ATVPAD_MAX_PLAYERS];
static bool pairing;
static char pair_result[96] = "";

// Status for the launcher's Controllers screen, rewritten on every change:
//   pairing 0|1 / result <text> / player<N> <address> <layout> (or "-")
static void write_status(void) {
    FILE *f = fopen(ATVPAD_STATUS_FILE ".tmp", "w");
    if (!f) return;
    fprintf(f, "pairing %d\nresult %s\n", pairing, pair_result);
    for (int i = 0; i < ATVPAD_MAX_PLAYERS; i++) {
        if (pads[i].cid) fprintf(f, "player%d %s %s\n", i + 1, bd_addr_to_str(pad_addr[i]), pads[i].sony ? "PlayStation" : "Gamepad");
        else fprintf(f, "player%d -\n", i + 1);
    }
    fclose(f);
    chmod(ATVPAD_STATUS_FILE ".tmp", 0644);
    rename(ATVPAD_STATUS_FILE ".tmp", ATVPAD_STATUS_FILE);
}

// HID button number -> ATVPAD button. Sony: 1 Square 2 Cross 3 Circle 4 Triangle 5 L1 6 R1 7 L2 8 R2
// 9 Share/Create 10 Options 11 L3 12 R3 13 PS. Generic pads usually start with the south button.
static const uint8_t sony_map[] = { 0, ATVPAD_X, ATVPAD_A, ATVPAD_B, ATVPAD_Y, ATVPAD_L1, ATVPAD_R1, ATVPAD_L2,
    ATVPAD_R2, ATVPAD_SELECT, ATVPAD_START, ATVPAD_L3, ATVPAD_R3, ATVPAD_HOME };
static const uint8_t generic_map[] = { 0, ATVPAD_A, ATVPAD_B, ATVPAD_X, ATVPAD_Y, ATVPAD_L1, ATVPAD_R1, ATVPAD_L2,
    ATVPAD_R2, ATVPAD_SELECT, ATVPAD_START, ATVPAD_L3, ATVPAD_R3, ATVPAD_HOME };

#define BIT(b) (1u << (b))

// Stick axis -> direction bits (first = up/left button of the 4-button group: ATVPAD_UP or ATVPAD_RS_UP). The parser doesn't expose logical max, so the range comes from the field
// size: unsigned fields are centered at half range, signed ones at 0. Dead zone is half of the half-range.
static uint32_t axis_bits(int32_t value, int32_t logical_min, int size, bool vertical, int first) {
    if (size < 4 || size > 30) return 0;
    int32_t half = 1 << (size - 1), center = logical_min < 0 ? 0 : half - 1, dead = half / 2;
    // groups are ordered up, down, left, right
    if (value < center - dead) return BIT(first + (vertical ? 0 : 2));
    if (value > center + dead) return BIT(first + (vertical ? 1 : 3));
    return 0;
}

// Hat switch (0 = north, clockwise in 8 steps; anything else = centered) -> d-pad bits.
static uint32_t hat_bits(int32_t value, int32_t logical_min) {
    static const uint32_t dirs[8] = {
        BIT(ATVPAD_UP), BIT(ATVPAD_UP) | BIT(ATVPAD_RIGHT), BIT(ATVPAD_RIGHT), BIT(ATVPAD_DOWN) | BIT(ATVPAD_RIGHT),
        BIT(ATVPAD_DOWN), BIT(ATVPAD_DOWN) | BIT(ATVPAD_LEFT), BIT(ATVPAD_LEFT), BIT(ATVPAD_UP) | BIT(ATVPAD_LEFT) };
    int32_t h = value - logical_min;
    return (h >= 0 && h < 8) ? dirs[h] : 0;
}

static void send_event(int player, int button, int down) {
    int flags;
    pid_t pid = atvremote_active_app(&flags);
    uint32_t pkt[3] = { ATVPAD_PAGE + player, button, down };
    struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(ATVREMOTE_PORT), .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    if (button == ATVPAD_HOME) {
        // act on a short tap only: holding PS ~10 s powers the pad off and must not close the app
        static struct timeval pressed;
        struct timeval now; gettimeofday(&now, NULL);
        if (down) { pressed = now; return; }
        long held_ms = (now.tv_sec - pressed.tv_sec) * 1000 + (now.tv_usec - pressed.tv_usec) / 1000;
        if (held_ms > 1000 || !pid) return;
        if (!(flags & ATVREMOTE_HANDLES_HOME)) { logf_ts("home: closed app %d\n", atvremote_close_active()); return; }
        pkt[2] = 1;  // the app handles PS itself: deliver the tap as a press + release
        sendto(udp_sock, pkt, sizeof pkt, 0, (struct sockaddr *)&a, sizeof a);
        pkt[2] = 0;
        sendto(udp_sock, pkt, sizeof pkt, 0, (struct sockaddr *)&a, sizeof a);
        return;
    }
    if (!pid) {  // home screen: behave like the Apple remote (tweak injects these)
        static const uint16_t usages[ATVPAD_COUNT] = { [ATVPAD_UP] = 0x8c, [ATVPAD_DOWN] = 0x8d, [ATVPAD_LEFT] = 0x8b,
            [ATVPAD_RIGHT] = 0x8a, [ATVPAD_A] = 0x89, [ATVPAD_B] = 0x86, [ATVPAD_START] = 0xcd };
        if (!usages[button]) return;
        pkt[0] = button == ATVPAD_START ? 0x0c : 0x01;  // play/pause is on the consumer page
        pkt[1] = usages[button];
        a.sin_port = htons(ATVREMOTE_INJECT_PORT);
    }
    sendto(udp_sock, pkt, sizeof pkt, 0, (struct sockaddr *)&a, sizeof a);
}

static void set_buttons(int player, uint32_t buttons) {
    uint32_t changed = buttons ^ pads[player].buttons;
    pads[player].buttons = buttons;
    for (int b = 1; b < ATVPAD_COUNT; b++)
        if (changed & BIT(b)) send_event(player, b, (buttons >> b) & 1);
}

static void handle_report(int player, const uint8_t *report, uint16_t len) {
    if (len < 2 || report[0] != 0xa1) return;  // DATA | Input
    const uint8_t *map = pads[player].sony ? sony_map : generic_map;
    btstack_hid_parser_t parser;
    btstack_hid_parser_init(&parser, hid_descriptor_storage_get_descriptor_data(pads[player].cid),
                            hid_descriptor_storage_get_descriptor_len(pads[player].cid), HID_REPORT_TYPE_INPUT,
                            report + 1, len - 1);
    uint32_t buttons = 0;
    while (btstack_hid_parser_has_more(&parser)) {
        uint16_t page, usage; int32_t value;
        btstack_hid_parser_get_field(&parser, &page, &usage, &value);
        int32_t lmin = parser.descriptor_usage_item.global_logical_minimum;
        int size = parser.descriptor_usage_item.size;
        if (page == 0x09 && value && usage < sizeof sony_map) buttons |= BIT(map[usage]);
        else if (page == 0x01 && (usage == 0x30 || usage == 0x31))  // left stick: X, Y
            buttons |= axis_bits(value, lmin, size, usage == 0x31, ATVPAD_UP);
        else if (page == 0x01 && (usage == 0x32 || usage == 0x35))  // right stick: Z, Rz (Rx/Ry are Sony's analog triggers)
            buttons |= axis_bits(value, lmin, size, usage == 0x35, ATVPAD_RS_UP);
        else if (page == 0x01 && usage == 0x39) buttons |= hat_bits(value, lmin);
    }
    buttons &= ~BIT(0);
    if (!pads[player].seen_report) { pads[player].seen_report = true; pads[player].buttons = buttons; return; }
    set_buttons(player, buttons);
}

static int player_for_cid(uint16_t cid) {
    for (int i = 0; i < ATVPAD_MAX_PLAYERS; i++) if (pads[i].cid == cid) return i;
    return -1;
}

static void release_pad(int p) {
    set_buttons(p, 0);  // release anything held
    pads[p].cid = 0;
    logf_ts("player %d disconnected\n", p + 1);
    write_status();
}

// A pad that connected but never delivered its HID descriptor (e.g. an L2CAP timeout while the
// system was busy) would sit in its player slot producing no input; drop it so it reconnects.
#define DESCRIPTOR_TIMEOUT_MS 8000
static btstack_timer_source_t watchdog;
static void watchdog_tick(btstack_timer_source_t *t) {
    for (int p = 0; p < ATVPAD_MAX_PLAYERS; p++)
        if (pads[p].cid && !pads[p].have_descriptor &&
            btstack_run_loop_get_time_ms() - pads[p].connected_ms > DESCRIPTOR_TIMEOUT_MS) {
            logf_ts("player %d: descriptor timeout, disconnecting\n", p + 1);
            hid_host_disconnect(pads[p].cid);
            release_pad(p);
        }
    btstack_run_loop_set_timer(t, 2000);
    btstack_run_loop_add_timer(t);
}

static void start_pairing(void) {
    if (pairing) return;
    pairing = true;
    pair_result[0] = 0;
    write_status();
    pair_target_found = false;
    logf_ts("pairing: searching %ds - hold PS+Share (DS4) / PS+Create (DualSense) until the light flashes\n", INQUIRY_SECONDS);
    gap_inquiry_start(INQUIRY_SECONDS * 100 / 128);
}

static void packet_handler(uint8_t packet_type, uint16_t channel, uint8_t *packet, uint16_t size) {
    if (packet_type != HCI_EVENT_PACKET) return;
    bd_addr_t addr;
    if (page_scan_pending && hci_send_cmd(&write_page_scan_activity, 0x0100, 0x0024) == ERROR_CODE_SUCCESS)
        page_scan_pending = false;
    switch (hci_event_packet_get_type(packet)) {
    case BTSTACK_EVENT_STATE:
        if (btstack_event_state_get_state(packet) != HCI_STATE_WORKING) break;
        mkdir(TLV_DIR, 0755);
        const btstack_tlv_t *tlv = btstack_tlv_posix_init_instance(&tlv_context, TLV_DIR "/atvpad.tlv");
        btstack_tlv_set_instance(tlv, &tlv_context);
        hci_set_link_key_db(btstack_link_key_db_tlv_get_instance(tlv, &tlv_context));
        page_scan_pending = hci_send_cmd(&write_page_scan_activity, 0x0100, 0x0024) != ERROR_CODE_SUCCESS;
        gap_local_bd_addr(addr);
        logf_ts("ready, local address %s\n", bd_addr_to_str(addr));
        write_status();
        break;

    case HCI_EVENT_COMMAND_COMPLETE:
        if (hci_event_command_complete_get_command_opcode(packet) == 0x0c1b) {  // Read_Page_Scan_Activity
            const uint8_t *r = hci_event_command_complete_get_return_parameters(packet);
            logf_ts("page scan: status 0x%02x interval 0x%04x window 0x%04x\n", r[0], little_endian_read_16(r, 1), little_endian_read_16(r, 3));
        }
        if (hci_event_command_complete_get_command_opcode(packet) == write_page_scan_activity.opcode)
            hci_send_cmd(&write_page_scan_type, 1);
        if (hci_event_command_complete_get_command_opcode(packet) == write_page_scan_type.opcode)
            hci_send_cmd(&read_page_scan_activity);
        break;

    case HCI_EVENT_CONNECTION_REQUEST:
        hci_event_connection_request_get_bd_addr(packet, addr);
        logf_ts("link request from %s\n", bd_addr_to_str(addr));
        break;
    case HCI_EVENT_CONNECTION_COMPLETE:
        logf_ts("link up, status 0x%02x\n", hci_event_connection_complete_get_status(packet));
        break;
    case HCI_EVENT_DISCONNECTION_COMPLETE:
        logf_ts("link down, reason 0x%02x\n", hci_event_disconnection_complete_get_reason(packet));
        break;

    case HCI_EVENT_PIN_CODE_REQUEST:  // legacy (pre-2.1) pads
        hci_event_pin_code_request_get_bd_addr(packet, addr);
        gap_pin_code_response(addr, "0000");
        break;

    case HCI_EVENT_USER_CONFIRMATION_REQUEST:  // SSP "just works": nothing to show the user, so accept
        hci_event_user_confirmation_request_get_bd_addr(packet, addr);
        gap_ssp_confirmation_response(addr);
        break;

    case GAP_EVENT_INQUIRY_RESULT: {
        uint32_t cod = gap_event_inquiry_result_get_class_of_device(packet);
        gap_event_inquiry_result_get_bd_addr(packet, addr);
        // major class "peripheral" with the joystick or gamepad minor bits
        bool gamepad = ((cod >> 8) & 0x1f) == 0x05 && (cod & 0x0c);
        logf_ts("found %s class %06x%s\n", bd_addr_to_str(addr), (unsigned)cod, gamepad ? " (gamepad)" : "");
        if (gamepad && !pair_target_found) {
            bd_addr_copy(pair_target, addr);
            pair_target_found = true;
            gap_inquiry_stop();
        }
        break;
    }

    case GAP_EVENT_INQUIRY_COMPLETE:
        if (!pair_target_found) {
            logf_ts("pairing: no controller found\n");
            pairing = false;
            snprintf(pair_result, sizeof pair_result, "No controller found");
            write_status();
            break;
        }
        uint16_t cid;
        uint8_t status = hid_host_connect(pair_target, HID_PROTOCOL_MODE_REPORT, &cid);
        logf_ts("pairing: connecting to %s (status 0x%02x)\n", bd_addr_to_str(pair_target), status);
        if (status != ERROR_CODE_SUCCESS) {
            pairing = false;
            snprintf(pair_result, sizeof pair_result, "Could not connect (0x%02x)", status);
            write_status();
        }
        break;

    case HCI_EVENT_HID_META:
        switch (hci_event_hid_meta_get_subevent_code(packet)) {
        case HID_SUBEVENT_INCOMING_CONNECTION:  // a paired pad woke up (PS button)
            hid_host_accept_connection(hid_subevent_incoming_connection_get_hid_cid(packet), HID_PROTOCOL_MODE_REPORT);
            break;
        case HID_SUBEVENT_CONNECTION_OPENED: {
            uint16_t cid = hid_subevent_connection_opened_get_hid_cid(packet);
            hid_subevent_connection_opened_get_bd_addr(packet, addr);
            if (hid_subevent_connection_opened_get_status(packet) != ERROR_CODE_SUCCESS) {
                logf_ts("connect %s failed 0x%02x\n", bd_addr_to_str(addr), hid_subevent_connection_opened_get_status(packet));
                int stale = player_for_cid(cid);
                if (stale >= 0) release_pad(stale);
                if (pairing && bd_addr_cmp(addr, pair_target) == 0) {
                    pairing = false;
                    snprintf(pair_result, sizeof pair_result, "Pairing failed - try again");
                    write_status();
                }
                break;
            }
            int p = player_for_cid(0);
            if (p < 0) { logf_ts("all %d player slots taken\n", ATVPAD_MAX_PLAYERS); hid_host_disconnect(cid); break; }
            pads[p] = (pad_t){ .cid = cid, .connected_ms = btstack_run_loop_get_time_ms() };
            bd_addr_copy(pad_addr[p], addr);
            logf_ts("player %d connected: %s\n", p + 1, bd_addr_to_str(addr));
            if (pairing && bd_addr_cmp(addr, pair_target) == 0) {
                pairing = false;
                snprintf(pair_result, sizeof pair_result, "Paired as player %d", p + 1);
            }
            write_status();
            break;
        }
        case HID_SUBEVENT_DESCRIPTOR_AVAILABLE: {
            uint16_t cid = hid_subevent_descriptor_available_get_hid_cid(packet);
            int p = player_for_cid(cid);
            if (p < 0) break;
            if (hid_subevent_descriptor_available_get_status(packet) != ERROR_CODE_SUCCESS) {
                // without a descriptor its reports can't be read; drop it so the pad reconnects
                logf_ts("player %d: no descriptor (0x%02x), disconnecting\n", p + 1, hid_subevent_descriptor_available_get_status(packet));
                hid_host_disconnect(cid);
                release_pad(p);
                break;
            }
            pads[p].have_descriptor = true;
            // Sony pads declare their vendor full reports (0x11 DS4, 0x31 DualSense) in the descriptor
            const uint8_t *d = hid_descriptor_storage_get_descriptor_data(cid);
            uint16_t dlen = hid_descriptor_storage_get_descriptor_len(cid);
            pads[p].sony = btstack_hid_report_id_valid(0x11, d, dlen) == HID_REPORT_ID_VALID ||
                           btstack_hid_report_id_valid(0x31, d, dlen) == HID_REPORT_ID_VALID;
            logf_ts("player %d descriptor %u bytes, %s layout\n", p + 1, dlen, pads[p].sony ? "PlayStation" : "generic");
            write_status();
            break;
        }
        case HID_SUBEVENT_REPORT: {
            int p = player_for_cid(hid_subevent_report_get_hid_cid(packet));
            if (p >= 0 && pads[p].have_descriptor)
                handle_report(p, hid_subevent_report_get_report(packet), hid_subevent_report_get_report_len(packet));
            break;
        }
        case HID_SUBEVENT_CONNECTION_CLOSED: {
            int p = player_for_cid(hid_subevent_connection_closed_get_hid_cid(packet));
            if (p >= 0) release_pad(p);
            break;
        }
        }
        break;
    }
}

static void pair_notified(btstack_data_source_t *ds, btstack_data_source_callback_type_t type) {
    int token;
    read(ds->source.fd, &token, sizeof token);
    start_pairing();
}

// Stops Apple's Bluetooth daemons and powers the chip up with firmware, leaving it at UART_BAUD.
static void bt_power_on(void) {
    system("launchctl unload /System/Library/LaunchDaemons/com.apple.BTServer.plist 2>/dev/null");
    system("launchctl unload /System/Library/LaunchDaemons/com.apple.BlueTool.plist 2>/dev/null");
    system("killall -9 BTServer BlueTool 2>/dev/null");
    // holding /dev/btwake open keeps the chip from sleeping (it's mains powered, so no cost);
    // on the ATV3 it must be held before BlueTool runs, or BlueTool hangs talking to a sleeping chip
    if (open("/dev/btwake", O_RDWR) < 0) perror("btwake");
    system("/usr/sbin/BlueTool -F boot >/dev/null 2>&1");
    char cmd[160];
    snprintf(cmd, sizeof cmd, "printf 'device -D -S\\nwake on\\nbcm -b %d\\nmsleep 200\\nwake off\\nquit\\n' | /usr/sbin/BlueTool >/dev/null 2>&1", UART_BAUD);
    system(cmd);
}

static void selftest(void) {
    assert(axis_bits(128, 0, 8, false, ATVPAD_UP) == 0);
    assert(axis_bits(0, 0, 8, false, ATVPAD_UP) == BIT(ATVPAD_LEFT));
    assert(axis_bits(255, 0, 8, true, ATVPAD_UP) == BIT(ATVPAD_DOWN));
    assert(axis_bits(-128, -127, 8, true, ATVPAD_UP) == BIT(ATVPAD_UP));
    assert(axis_bits(2048, 0, 12, false, ATVPAD_UP) == 0);
    assert(axis_bits(255, 0, 8, false, ATVPAD_RS_UP) == BIT(ATVPAD_RS_RIGHT));
    assert(axis_bits(0, 0, 8, true, ATVPAD_RS_UP) == BIT(ATVPAD_RS_UP));
    assert(ATVPAD_COUNT <= 32);
    assert(hat_bits(0, 0) == BIT(ATVPAD_UP));
    assert(hat_bits(3, 0) == (BIT(ATVPAD_DOWN) | BIT(ATVPAD_RIGHT)));
    assert(hat_bits(8, 0) == 0 && hat_bits(7, 1) == BIT(ATVPAD_LEFT));
    assert(sizeof sony_map == sizeof generic_map);
    // H4 framing, using real DualSense traffic: a good report, then the damaged ones from the crash dumps
    const uint8_t good[] = { 0x02, 0x0b, 0x20, 0x0f, 0x00, 0x0b, 0x00, 0x43, 0x00, 0xa1, 0x01, 0x82, 0x85, 0x7f, 0x7d, 0x08, 0x00, 0x1c, 0x00, 0x00 };
    assert(atv_h4_frame(good, sizeof good) == 20 && atv_h4_frame(good, 10) == 0);
    const uint8_t lost_head[] = { 0x02, 0x0b, 0x20, 0x0f, 0x00, 0x08, 0x00, 0x38, 0x00, 0x00, 0x02 };  // l2cap len 8 != 15 - 4
    assert(atv_h4_frame(lost_head, sizeof lost_head) == -1);
    const uint8_t mid_stream[] = { 0x00, 0x0b, 0x00, 0x43 };
    assert(atv_h4_frame(mid_stream, sizeof mid_stream) == -1);
    const uint8_t evt[] = { 0x04, 0x0e, 0x04, 0x01, 0x03, 0x0c, 0x00 };
    assert(atv_h4_frame(evt, sizeof evt) == 7 && atv_h4_frame(evt, 3) == 0);
    puts("selftest ok");
}

int main(int argc, char **argv) {
    if (argc > 1 && !strcmp(argv[1], "pair")) {
        notify_post(PAIR_NOTIFICATION);
        puts("pairing started: hold PS+Share (DS4) or PS+Create (DualSense) until the light flashes fast");
        return 0;
    }
    if (argc > 1 && !strcmp(argv[1], "selftest")) { selftest(); return 0; }

    setvbuf(stdout, NULL, _IOLBF, 0);
    signal(SIGPIPE, SIG_IGN);
    udp_sock = socket(AF_INET, SOCK_DGRAM, 0);
    bt_power_on();

    btstack_memory_init();
    btstack_run_loop_init(btstack_run_loop_posix_get_instance());
    if (argc > 1 && !strcmp(argv[1], "-d")) {
        hci_dump_posix_fs_open("/tmp/atvpadd.pklg", HCI_DUMP_PACKETLOGGER);
        hci_dump_init(hci_dump_posix_fs_get_instance());
    }
    static hci_transport_config_uart_t uart_config = { HCI_TRANSPORT_CONFIG_UART, UART_BAUD, 0, 1, NULL };
    hci_init(hci_transport_h4_instance_for_uart(btstack_uart_atv_instance()), &uart_config);

    l2cap_init();
    sdp_init();
    hid_host_init(hid_descriptor_storage, sizeof hid_descriptor_storage);
    hid_host_register_packet_handler(packet_handler);
    hci_callback.callback = packet_handler;
    hci_add_event_handler(&hci_callback);

    gap_set_local_name("Apple TV");
    gap_set_class_of_device(0x2c0100);  // computer
    gap_ssp_set_io_capability(SSP_IO_CAPABILITY_NO_INPUT_NO_OUTPUT);
    gap_set_default_link_policy_settings(LM_LINK_POLICY_ENABLE_SNIFF_MODE | LM_LINK_POLICY_ENABLE_ROLE_SWITCH);
    hci_set_master_slave_policy(HCI_ROLE_MASTER);
    gap_connectable_control(1);  // paired pads reconnect on their own

    int pair_fd, token;
    if (notify_register_file_descriptor(PAIR_NOTIFICATION, &pair_fd, 0, &token) == NOTIFY_STATUS_OK) {
        btstack_run_loop_set_data_source_fd(&pair_source, pair_fd);
        btstack_run_loop_set_data_source_handler(&pair_source, &pair_notified);
        btstack_run_loop_enable_data_source_callbacks(&pair_source, DATA_SOURCE_CALLBACK_READ);
        btstack_run_loop_add_data_source(&pair_source);
    }

    btstack_run_loop_set_timer_handler(&watchdog, watchdog_tick);
    btstack_run_loop_set_timer(&watchdog, 2000);
    btstack_run_loop_add_timer(&watchdog);

    hci_power_control(HCI_POWER_ON);
    btstack_run_loop_execute();
    return 0;
}
