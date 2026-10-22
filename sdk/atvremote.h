// Apple remote input for ATV2 apps. The ATVLaunch tweak (inside AppleTV.app) forwards remote
// buttons as UDP packets to port ATVREMOTE_PORT while this app's pid is in ATVREMOTE_PIDFILE.
// Packet: three little-endian uint32: HID usage page, usage, down (1) / up (0).
// The PC can send the same packets over the network (see tools/atvkeys.py).
// Bluetooth gamepads (atvpad/atvpadd) use page ATVPAD_PAGE + player (0-3) and usage = ATVPAD_* button.
#ifndef ATVREMOTE_H
#define ATVREMOTE_H
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <notify.h>
#include <sys/stat.h>
#include <netinet/in.h>
#include <sys/socket.h>

#define ATVREMOTE_PORT 37777
#define ATVREMOTE_PIDFILE "/tmp/atvdev.pid"
// Same packet format sent here (loopback) is injected into the AppleTV home screen as remote input.
#define ATVREMOTE_INJECT_PORT 37778
#define ATVLAUNCH_FILE "/var/mobile/atvlaunch.txt"
#define ATVLAUNCH_NOTIFICATION "com.atvdev.launch"
#define ATVSHOT_NOTIFICATION "com.atvdev.screenshot"  // ATVLaunch tweak saves the screen to ATVSHOT_FILE
#define ATVSHOT_FILE "/tmp/atvshot.png"
#define ATVGAME_ROM_DIR "/var/mobile/Media/ROMs"  // one subfolder per console (nes, snes, gb, gba, md)

// Logical buttons (decoded from page/usage by atvremote_poll).
enum { ATV_UP = 1, ATV_DOWN, ATV_LEFT, ATV_RIGHT, ATV_SELECT, ATV_MENU, ATV_PLAYPAUSE };

// Gamepad buttons. A/B/X/Y are positions (south/east/west/north): on PlayStation pads A = Cross,
// B = Circle, X = Square, Y = Triangle; SELECT = Share/Create, START = Options.
// HOME = a tap on PS: closes the app, unless it opened input with ATVREMOTE_HANDLES_HOME (then it gets the event).
// The left stick doubles as the d-pad; the right stick is reported as RS_* directions.
#define ATVPAD_PAGE 0xF000
#define ATVPAD_PAIR_NOTIFICATION "com.atvdev.pad.pair"  // notify_post() this to start pairing (~30 s)
#define ATVPAD_STATUS_FILE "/tmp/atvpad.status"         // pairing/player status written by atvpadd
#define ATVPAD_MAX_PLAYERS 4
enum { ATVPAD_UP = 1, ATVPAD_DOWN, ATVPAD_LEFT, ATVPAD_RIGHT, ATVPAD_A, ATVPAD_B, ATVPAD_X, ATVPAD_Y,
       ATVPAD_L1, ATVPAD_R1, ATVPAD_L2, ATVPAD_R2, ATVPAD_SELECT, ATVPAD_START, ATVPAD_L3, ATVPAD_R3,
       ATVPAD_HOME, ATVPAD_RS_UP, ATVPAD_RS_DOWN, ATVPAD_RS_LEFT, ATVPAD_RS_RIGHT, ATVPAD_COUNT };

// Player index (0-3) for a gamepad packet's page, or -1 if the packet isn't from a gamepad.
static inline int atvpad_player(uint32_t page) {
    return (page >= ATVPAD_PAGE && page < ATVPAD_PAGE + ATVPAD_MAX_PLAYERS) ? (int)(page - ATVPAD_PAGE) : -1;
}

#define ATVREMOTE_HANDLES_HOME 1  // atvremote_open_flags: deliver PS taps to the app instead of closing it

// Opens the non-blocking listener and claims remote input. Returns fd or -1.
static int atvremote_open_flags(int flags) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in a; memset(&a, 0, sizeof a);
    a.sin_family = AF_INET; a.sin_port = htons(ATVREMOTE_PORT); a.sin_addr.s_addr = htonl(INADDR_ANY);
    int one = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    if (fd < 0 || bind(fd, (struct sockaddr *)&a, sizeof a) < 0) { if (fd >= 0) close(fd); return -1; }
    fcntl(fd, F_SETFL, O_NONBLOCK);
    FILE *f = fopen(ATVREMOTE_PIDFILE, "w");
    if (f) { fprintf(f, "%d %s %d", getpid(), getprogname(), flags); fclose(f); }
    return fd;
}
static int atvremote_open(void) { return atvremote_open_flags(0); }

// Pid of the app owning input if it is still alive, else 0; its atvremote_open_flags flags go to *flags.
static pid_t atvremote_active_app(int *flags) {
    FILE *f = fopen(ATVREMOTE_PIDFILE, "r");
    int pid = 0, fl = 0;
    char name[64];
    if (f) { if (fscanf(f, "%d %63s %d", &pid, name, &fl) < 1) pid = 0; fclose(f); }
    if (flags) *flags = fl;
    return (pid > 0 && kill(pid, 0) == 0) ? pid : 0;
}
static pid_t atvremote_active_pid(void) { return atvremote_active_app(NULL); }

// Asks AppleTV.app (ATVLaunch tweak) to launch an installed app by bundle id. Returns 0 on success.
static int atvremote_launch(const char *bundle_id) {
    unlink(ATVLAUNCH_FILE);  // may be owned by another user (root daemon vs mobile app)
    FILE *f = fopen(ATVLAUNCH_FILE, "w");
    if (!f) return -1;
    fputs(bundle_id, f); fclose(f);
    chmod(ATVLAUNCH_FILE, 0666);
    return notify_post(ATVLAUNCH_NOTIFICATION) == NOTIFY_STATUS_OK ? 0 : -1;
}

// Closes the app owning input (PS tap / holding Menu), back to the AppleTV home screen.
// Returns the closed pid or 0.
static pid_t atvremote_close_active(void) {
    pid_t pid = atvremote_active_pid();
    if (!pid) return 0;
    kill(pid, SIGKILL);
    unlink(ATVREMOTE_PIDFILE);
    return pid;
}

// Taps an Apple remote button by name (up down left right select menu play): the app owning input gets it,
// or the home screen when no app is open. Returns 0, or -1 for an unknown name.
static int atvremote_press(const char *name) {
    static const struct { const char *name; uint32_t page, usage; } keys[] = {
        { "up", 1, 0x8c }, { "down", 1, 0x8d }, { "left", 1, 0x8b }, { "right", 1, 0x8a },
        { "select", 1, 0x89 }, { "menu", 1, 0x86 }, { "play", 0x0c, 0xcd } };
    for (size_t i = 0; i < sizeof keys / sizeof *keys; i++) {
        if (strcmp(name, keys[i].name)) continue;
        int fd = socket(AF_INET, SOCK_DGRAM, 0);
        struct sockaddr_in a; memset(&a, 0, sizeof a);
        a.sin_family = AF_INET; a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        a.sin_port = htons(atvremote_active_pid() ? ATVREMOTE_PORT : ATVREMOTE_INJECT_PORT);
        uint32_t pkt[3] = { keys[i].page, keys[i].usage, 1 };
        sendto(fd, pkt, sizeof pkt, 0, (struct sockaddr *)&a, sizeof a);
        usleep(50000);
        pkt[2] = 0;  // release
        sendto(fd, pkt, sizeof pkt, 0, (struct sockaddr *)&a, sizeof a);
        close(fd);
        return 0;
    }
    return -1;
}

// Asks the ATVLaunch tweak to save the screen to ATVSHOT_FILE. Returns 0 once it is written, -1 after 5 s.
static int atvremote_screenshot(void) {
    unlink(ATVSHOT_FILE);
    notify_post(ATVSHOT_NOTIFICATION);
    for (int i = 0; i < 50; i++, usleep(100000)) if (access(ATVSHOT_FILE, R_OK) == 0) return 0;  // written atomically
    return -1;
}

// Maps a HID page/usage to a logical button, or 0 if unknown.
// Gamepads map too (d-pad, A = Select, B = Menu, Start = Play/Pause) so remote-only apps work with them.
static int atvremote_button(uint32_t page, uint32_t usage) {
    if (atvpad_player(page) >= 0) switch (usage) {
        case ATVPAD_UP: return ATV_UP;     case ATVPAD_DOWN: return ATV_DOWN;
        case ATVPAD_LEFT: return ATV_LEFT; case ATVPAD_RIGHT: return ATV_RIGHT;
        case ATVPAD_A: return ATV_SELECT;  case ATVPAD_B: return ATV_MENU; case ATVPAD_START: return ATV_PLAYPAUSE;
    }
    if (page == 0x01) switch (usage) {        // generic desktop (Apple IR remote)
        case 0x8c: return ATV_UP;   case 0x8d: return ATV_DOWN;
        case 0x8b: return ATV_LEFT; case 0x8a: return ATV_RIGHT;
        case 0x89: return ATV_SELECT; case 0x86: return ATV_MENU;
    }
    if (page == 0x0c) switch (usage) {        // consumer page
        case 0x42: return ATV_UP;   case 0x43: return ATV_DOWN;
        case 0x44: return ATV_LEFT; case 0x45: return ATV_RIGHT;
        case 0x41: return ATV_SELECT; case 0x40: return ATV_MENU; case 0xcd: return ATV_PLAYPAUSE;
    }
    return 0;
}

// Reads one pending event. Returns 1 and fills button/down, 0 when the queue is empty.
// button is 0 for page/usage pairs not in atvremote_button (raw values still in *page/*usage if non-NULL).
static int atvremote_poll(int fd, int *button, int *down, uint32_t *page, uint32_t *usage) {
    uint32_t p[3];
    if (recv(fd, p, sizeof p, 0) != sizeof p) return 0;
    *button = atvremote_button(p[0], p[1]); *down = p[2] != 0;
    if (page) *page = p[0];
    if (usage) *usage = p[1];
    return 1;
}
#endif
