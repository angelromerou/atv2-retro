// Web page for adding games: http://<apple tv>/ serves index.html, which uploads ROMs here.
// The consoles come from the console apps' Info.plists (RetroSystem, RetroTitle, RetroExtensions),
// so a new console app shows up without changes here.
//   GET  /                                     index.html
//   GET  /api/consoles                         [{"system","title","exts":[..],"games":[..]}, ...]
//   POST /api/upload?name=<file>[&system=<s>]  body = the file; a .zip has its ROMs extracted.
//                                              Without system, the console is picked by extension.
//   POST /api/delete?system=<s>&name=<file>    deletes one game
//   GET  /remote                               remote.html: an on-screen Apple remote for testing from a phone/PC
//   POST /api/press?button=<up|down|left|right|select|menu|play>   taps a remote button
//   POST /api/close                            closes the open app (like holding Menu)
//   GET  /api/screenshot                       PNG of what's on the TV
// One forked process per connection, so an idle browser connection can't block the others.
// POSTs must carry an X-ATV header: other websites can't add one without CORS, so they can't drive the TV.
// Runs as mobile once port 80 is open. `atvromsd selftest` checks the zip and name handling.
#include <CoreFoundation/CoreFoundation.h>
#include <assert.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>
#include "../sdk/atvremote.h"

#define PORT 80
#define PAGE_DIR "/usr/share/atvroms/"
#define MAX_UPLOAD (64 << 20)  // the biggest GBA ROM is 32 MB
#define MOBILE_UID 501

// ---- consoles ----

typedef struct { char system[16], title[64], exts[12][8]; int nexts; } Console;
static Console consoles[16];
static int nconsoles;

static void cfstr(CFTypeRef s, char *out, size_t n) {
    out[0] = 0;
    if (s && CFGetTypeID(s) == CFStringGetTypeID()) CFStringGetCString(s, out, n, kCFStringEncodingUTF8);
}

static void loadConsoles(void) {
    DIR *d = opendir("/Applications");
    struct dirent *e;
    nconsoles = 0;
    while (d && (e = readdir(d)) && nconsoles < 16) {
        char path[512];
        snprintf(path, sizeof path, "/Applications/%s/Info.plist", e->d_name);
        CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (UInt8 *)path, strlen(path), false);
        CFReadStreamRef st = CFReadStreamCreateWithFile(NULL, url);
        CFPropertyListRef pl = NULL;
        if (st && CFReadStreamOpen(st)) {
            pl = CFPropertyListCreateWithStream(NULL, st, 0, kCFPropertyListImmutable, NULL, NULL);
            CFReadStreamClose(st);
        }
        if (st) CFRelease(st);
        CFRelease(url);
        if (!pl) continue;
        Console *c = &consoles[nconsoles];
        if (CFGetTypeID(pl) == CFDictionaryGetTypeID()) {
            cfstr(CFDictionaryGetValue(pl, CFSTR("RetroSystem")), c->system, sizeof c->system);
            cfstr(CFDictionaryGetValue(pl, CFSTR("RetroTitle")), c->title, sizeof c->title);
            CFArrayRef exts = CFDictionaryGetValue(pl, CFSTR("RetroExtensions"));
            c->nexts = 0;
            if (exts && CFGetTypeID(exts) == CFArrayGetTypeID())
                for (CFIndex i = 0; i < CFArrayGetCount(exts) && c->nexts < 12; i++)
                    cfstr(CFArrayGetValueAtIndex(exts, i), c->exts[c->nexts++], 8);
            if (c->system[0] && c->nexts) nconsoles++;
        }
        CFRelease(pl);
    }
    if (d) closedir(d);
}

static Console *consoleNamed(const char *system) {
    for (int i = 0; i < nconsoles; i++) if (!strcmp(consoles[i].system, system)) return &consoles[i];
    return NULL;
}

static const char *extOf(const char *name) { const char *dot = strrchr(name, '.'); return dot ? dot + 1 : ""; }

static int takesExt(Console *c, const char *ext) {
    for (int i = 0; i < c->nexts; i++) if (!strcasecmp(c->exts[i], ext)) return 1;
    return 0;
}

static Console *consoleForExt(const char *ext) {
    for (int i = 0; i < nconsoles; i++) if (takesExt(&consoles[i], ext)) return &consoles[i];
    return NULL;
}

// a plain file name: no folders, not hidden, no control characters
static int safeName(const char *n) {
    if (!n[0] || n[0] == '.' || strlen(n) > 200) return 0;
    for (const unsigned char *p = (const unsigned char *)n; *p; p++) if (*p < 32 || *p == '/' || *p == '\\') return 0;
    return 1;
}

// ---- responses ----

static void reply(int fd, const char *status, const char *type, const char *body, size_t len) {
    char h[256];
    int n = snprintf(h, sizeof h, "HTTP/1.0 %s\r\nContent-Type: %s\r\nContent-Length: %zu\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n", status, type, len);
    write(fd, h, n);
    if (len) write(fd, body, len);
}

static void replyFile(int fd, const char *path, const char *type) {
    int f = open(path, O_RDONLY);
    struct stat st;
    if (f < 0 || fstat(f, &st)) { if (f >= 0) close(f); reply(fd, "500 Internal Server Error", "text/plain", "file missing", 12); return; }
    char *body = malloc(st.st_size);
    ssize_t len = read(f, body, st.st_size);
    close(f);
    reply(fd, "200 OK", type, body, len > 0 ? len : 0);
    free(body);
}

static void replyJSON(int fd, const char *status, const char *json) { reply(fd, status, "application/json", json, strlen(json)); }

static void replyError(int fd, const char *msg) {
    char j[512];
    snprintf(j, sizeof j, "{\"error\":\"%s\"}", msg);  // msg is always one of our own literals plus a safe name
    replyJSON(fd, "400 Bad Request", j);
}

typedef struct { char *s; size_t len, cap; } Buf;
static void put(Buf *b, const char *s, size_t n) {
    if (b->len + n + 1 > b->cap) { b->cap = (b->len + n + 1) * 2; b->s = realloc(b->s, b->cap); }
    memcpy(b->s + b->len, s, n); b->len += n; b->s[b->len] = 0;
}
static void puts_(Buf *b, const char *s) { put(b, s, strlen(s)); }
static void putJSONString(Buf *b, const char *s) {
    puts_(b, "\"");
    for (; *s; s++) {
        char e[8];
        if (*s == '"' || *s == '\\') { e[0] = '\\'; e[1] = *s; put(b, e, 2); }
        else if ((unsigned char)*s < 32) { snprintf(e, sizeof e, "\\u%04x", *s); puts_(b, e); }
        else put(b, s, 1);
    }
    puts_(b, "\"");
}

static int byName(const void *a, const void *b) { return strcasecmp(*(char **)a, *(char **)b); }

static void listConsoles(int fd) {
    Buf b = {0};
    puts_(&b, "[");
    for (int i = 0; i < nconsoles; i++) {
        Console *c = &consoles[i];
        if (i) puts_(&b, ",");
        puts_(&b, "{\"system\":"); putJSONString(&b, c->system);
        puts_(&b, ",\"title\":"); putJSONString(&b, c->title);
        puts_(&b, ",\"exts\":[");
        for (int k = 0; k < c->nexts; k++) { if (k) puts_(&b, ","); putJSONString(&b, c->exts[k]); }
        puts_(&b, "],\"games\":[");
        char dir[256], *names[1024];
        int n = 0;
        snprintf(dir, sizeof dir, ATVGAME_ROM_DIR "/%s", c->system);
        DIR *d = opendir(dir);
        struct dirent *e;
        while (d && (e = readdir(d)) && n < 1024)
            if (e->d_name[0] != '.' && takesExt(c, extOf(e->d_name))) names[n++] = strdup(e->d_name);
        if (d) closedir(d);
        qsort(names, n, sizeof *names, byName);
        for (int k = 0; k < n; k++) { if (k) puts_(&b, ","); putJSONString(&b, names[k]); free(names[k]); }
        puts_(&b, "]}");
    }
    puts_(&b, "]");
    replyJSON(fd, "200 OK", b.s);
    free(b.s);
}

// ---- saving ----

static int ensureDir(Console *c, char *dir, size_t n) {
    snprintf(dir, n, ATVGAME_ROM_DIR "/%s", c->system);
    mkdir(ATVGAME_ROM_DIR, 0755);
    return !mkdir(dir, 0755) || errno == EEXIST;
}

// writes via a temp file so a half-finished upload never shows up as a game
static int saveFile(Console *c, const char *name, const void *data, size_t len) {
    char dir[256], tmp[512], path[512];
    if (!ensureDir(c, dir, sizeof dir)) return 0;
    snprintf(tmp, sizeof tmp, "%s/.upload-%d", dir, getpid());
    snprintf(path, sizeof path, "%s/%s", dir, name);
    int f = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (f < 0) return 0;
    int ok = write(f, data, len) == (ssize_t)len;
    ok = !close(f) && ok;
    if (ok) ok = !rename(tmp, path);
    if (!ok) unlink(tmp);
    return ok;
}

static uint16_t le16(const uint8_t *p) { return p[0] | p[1] << 8; }
static uint32_t le32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }

// Extracts the ROMs in a zip (stored or deflated entries) into the console's folder. With no console
// given, the first ROM picks it. Appends the saved names to *saved; returns the console or NULL.
// shortcut: no zip64 or encrypted entries; ROM zips never need them.
// Offsets come from the upload, so bounds checks are done in 64 bits: on the ATV2 size_t is 32 and offset + n could wrap.
static Console *saveZip(Console *c, const uint8_t *z, size_t len, Buf *saved, const char **err) {
    *err = c ? "That zip has no games for this console in it" : "That zip has no games in it";
    if (len < 22) { *err = "That zip is damaged"; return NULL; }
    size_t eocd = len - 22, stop = len > 65557 ? len - 65557 : 0;
    while (eocd > stop && le32(z + eocd) != 0x06054b50) eocd--;
    if (le32(z + eocd) != 0x06054b50) { *err = "That zip is damaged"; return NULL; }
    size_t p = le32(z + eocd + 16), count = le16(z + eocd + 10), nsaved = 0;
    for (size_t i = 0; i < count; i++) {
        if ((uint64_t)p + 46 > len || le32(z + p) != 0x02014b50) { *err = "That zip is damaged"; break; }
        int method = le16(z + p + 10), flags = le16(z + p + 8);
        size_t csize = le32(z + p + 20), usize = le32(z + p + 24), nlen = le16(z + p + 28);
        size_t next = p + 46 + nlen + le16(z + p + 30) + le16(z + p + 32), loc = le32(z + p + 42);
        if (p + 46 + nlen > len) { *err = "That zip is damaged"; break; }
        char full[512], *name;
        snprintf(full, sizeof full, "%.*s", (int)nlen, z + p + 46);
        name = strrchr(full, '/') ? strrchr(full, '/') + 1 : full;
        p = next;
        Console *target = c ? c : consoleForExt(extOf(name));
        if (!target || !takesExt(target, extOf(name)) || !safeName(name) || (flags & 1) || usize > MAX_UPLOAD) continue;
        if ((uint64_t)loc + 30 > len || le32(z + loc) != 0x04034b50) continue;
        size_t data = loc + 30 + le16(z + loc + 26) + le16(z + loc + 28);
        if ((uint64_t)data + csize > len) continue;
        uint8_t *out = malloc(usize ? usize : 1);
        int ok = 0;
        if (method == 0 && csize == usize) { memcpy(out, z + data, usize); ok = 1; }
        else if (method == 8) {
            z_stream s = {0};
            s.next_in = (Bytef *)(z + data); s.avail_in = csize; s.next_out = out; s.avail_out = usize;
            ok = inflateInit2(&s, -MAX_WBITS) == Z_OK && inflate(&s, Z_FINISH) == Z_STREAM_END && s.total_out == usize;
            inflateEnd(&s);
        }
        if (ok && saveFile(target, name, out, usize)) {
            c = target;
            if (nsaved++) puts_(saved, ",");
            putJSONString(saved, name);
        }
        free(out);
    }
    return nsaved ? c : NULL;
}

// ---- requests ----

static int hexval(int ch) { return ch >= '0' && ch <= '9' ? ch - '0' : (ch | 32) >= 'a' && (ch | 32) <= 'f' ? (ch | 32) - 'a' + 10 : -1; }

// copies query parameter `key` (url-decoded) into out; returns 1 if present
static int param(const char *query, const char *key, char *out, size_t n) {
    size_t kl = strlen(key);
    for (const char *p = query; p && *p; p = strchr(p, '&') ? strchr(p, '&') + 1 : NULL) {
        if (strncmp(p, key, kl) || p[kl] != '=') continue;
        size_t o = 0;
        for (p += kl + 1; *p && *p != '&' && o + 1 < n; p++) {
            if (*p == '%' && hexval(p[1]) >= 0 && hexval(p[2]) >= 0) { out[o++] = hexval(p[1]) * 16 + hexval(p[2]); p += 2; }
            else out[o++] = *p == '+' ? ' ' : *p;
        }
        out[o] = 0;
        return 1;
    }
    return 0;
}

static void upload(int fd, const char *query, size_t clen, const char *body, size_t have) {
    char name[256], system[32] = "";
    param(query, "system", system, sizeof system);
    if (!param(query, "name", name, sizeof name) || !safeName(name)) return replyError(fd, "Bad file name");
    if (clen == 0) return replyError(fd, "That file is empty");
    if (clen > MAX_UPLOAD) return replyError(fd, "Files over 64 MB can't be games for these consoles");
    Console *c = system[0] ? consoleNamed(system) : NULL;
    if (system[0] && !c) return replyError(fd, "Unknown console");
    int zip = !strcasecmp(extOf(name), "zip");
    if (!zip) {
        if (!c) c = consoleForExt(extOf(name));
        if (!c) return replyError(fd, "Can't tell which console this is for. Pick the console and try again.");
        if (!takesExt(c, extOf(name))) return replyError(fd, "That console can't play this kind of file");
    }
    // stream the body to a temp file: the ATV2 has 256 MB of RAM
    char tmp[256], dir[256], path[512];
    snprintf(tmp, sizeof tmp, ATVGAME_ROM_DIR "/.upload-%d", getpid());
    mkdir(ATVGAME_ROM_DIR, 0755);
    int f = open(tmp, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (f < 0) return replyError(fd, "Couldn't save the file on the Apple TV");
    int ok = write(f, body, have) == (ssize_t)have;
    char chunk[65536];
    for (size_t got = have; ok && got < clen;) {
        ssize_t r = read(fd, chunk, clen - got < sizeof chunk ? clen - got : sizeof chunk);
        if (r <= 0) { close(f); unlink(tmp); return; }  // the browser went away
        ok = write(f, chunk, r) == r;
        got += r;
    }
    Buf saved = {0};
    puts_(&saved, "[");
    const char *err = "Couldn't save the file on the Apple TV";
    if (!ok) c = NULL;
    else if (zip) {
        void *z = mmap(NULL, clen, PROT_READ, MAP_PRIVATE, f, 0);
        c = z == MAP_FAILED ? NULL : saveZip(c, z, clen, &saved, &err);
        if (z != MAP_FAILED) munmap(z, clen);
    } else if (ensureDir(c, dir, sizeof dir)) {
        snprintf(path, sizeof path, "%s/%s", dir, name);
        if (!rename(tmp, path)) putJSONString(&saved, name);
        else c = NULL;
    } else c = NULL;
    close(f);
    unlink(tmp);  // already gone if it was renamed into place
    puts_(&saved, "]");
    if (!c) { free(saved.s); return replyError(fd, err); }
    Buf b = {0};
    puts_(&b, "{\"system\":"); putJSONString(&b, c->system);
    puts_(&b, ",\"title\":"); putJSONString(&b, c->title);
    puts_(&b, ",\"saved\":"); puts_(&b, saved.s); puts_(&b, "}");
    replyJSON(fd, "200 OK", b.s);
    free(b.s); free(saved.s);
}

// only games the page lists can go: a plain name with one of the console's ROM extensions.
// Battery saves stay, so a game added back keeps its progress.
static void removeGame(int fd, const char *query) {
    char name[256], system[32], path[512];
    if (!param(query, "system", system, sizeof system) || !param(query, "name", name, sizeof name)) return replyError(fd, "Bad request");
    Console *c = consoleNamed(system);
    if (!c) return replyError(fd, "Unknown console");
    if (!safeName(name) || !takesExt(c, extOf(name))) return replyError(fd, "Bad file name");
    snprintf(path, sizeof path, ATVGAME_ROM_DIR "/%s/%s", c->system, name);
    if (unlink(path) && errno != ENOENT) return replyError(fd, "Couldn't delete the game");
    replyJSON(fd, "200 OK", "{}");
}

static void serve(int fd) {
    struct timeval tv = { 60, 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    char req[8193];
    size_t n = 0;
    char *end = NULL;
    while (n < sizeof req - 1 && !end) {
        ssize_t r = read(fd, req + n, sizeof req - 1 - n);
        if (r <= 0) return;
        n += r; req[n] = 0;
        end = strstr(req, "\r\n\r\n");
    }
    if (!end) return;
    *end = 0;
    char method[8], target[2048];
    if (sscanf(req, "%7s %2047s", method, target) != 2) return;
    char *query = strchr(target, '?');
    if (query) *query++ = 0;
    char *cl = strcasestr(req, "\r\nContent-Length:");
    size_t clen = cl ? strtoul(cl + 17, NULL, 10) : 0;
    loadConsoles();

    if (!strcmp(method, "POST") && !strcasestr(req, "\r\nX-ATV:")) {
        reply(fd, "403 Forbidden", "text/plain", "missing X-ATV header", 20);
    } else if (!strcmp(method, "GET") && !strcmp(target, "/")) {
        replyFile(fd, PAGE_DIR "index.html", "text/html; charset=utf-8");
    } else if (!strcmp(method, "GET") && !strcmp(target, "/remote")) {
        replyFile(fd, PAGE_DIR "remote.html", "text/html; charset=utf-8");
    } else if (!strcmp(method, "POST") && !strcmp(target, "/api/press")) {
        char button[16];
        if (!param(query, "button", button, sizeof button) || atvremote_press(button)) replyError(fd, "Unknown button");
        else replyJSON(fd, "200 OK", "{}");
    } else if (!strcmp(method, "POST") && !strcmp(target, "/api/close")) {
        atvremote_close_active();
        replyJSON(fd, "200 OK", "{}");
    } else if (!strcmp(method, "GET") && !strcmp(target, "/api/screenshot")) {
        if (atvremote_screenshot()) reply(fd, "503 Service Unavailable", "text/plain", "no screenshot", 13);
        else replyFile(fd, ATVSHOT_FILE, "image/png");
    } else if (!strcmp(method, "GET") && !strcmp(target, "/api/consoles")) {
        listConsoles(fd);
    } else if (!strcmp(method, "POST") && !strcmp(target, "/api/upload")) {
        size_t have = n - (end + 4 - req);
        upload(fd, query, clen, end + 4, have > clen ? clen : have);
    } else if (!strcmp(method, "POST") && !strcmp(target, "/api/delete")) {
        removeGame(fd, query);
    } else {
        reply(fd, "404 Not Found", "text/plain", "not found", 9);
    }
}

// ---- selftest ----

static void put16(uint8_t *p, unsigned v) { p[0] = v; p[1] = v >> 8; }
static void put32(uint8_t *p, uint32_t v) { put16(p, v); put16(p + 2, v >> 16); }

// A zip holding one uncompressed file; cdOffset 0 = the real central directory offset.
static size_t makeZip(uint8_t *z, const char *name, const char *data, uint32_t cdOffset) {
    size_t n = strlen(name), d = strlen(data), cd = 30 + n + d;
    memset(z, 0, cd + 46 + n + 22);
    put32(z, 0x04034b50); put32(z + 18, d); put32(z + 22, d); put16(z + 26, n);
    memcpy(z + 30, name, n); memcpy(z + 30 + n, data, d);
    uint8_t *c = z + cd;
    put32(c, 0x02014b50); put32(c + 20, d); put32(c + 24, d); put16(c + 28, n); memcpy(c + 46, name, n);
    uint8_t *e = c + 46 + n;
    put32(e, 0x06054b50); put16(e + 8, 1); put16(e + 10, 1); put32(e + 12, 46 + n); put32(e + 16, cdOffset ? cdOffset : cd);
    return cd + 46 + n + 22;
}

static void selftest(void) {
    assert(safeName("Game (USA).sfc") && !safeName(".hidden") && !safeName("a/b.nes") && !safeName("..") && !safeName(""));
    char v[16];
    assert(param("name=a%20b+c&x=1", "name", v, sizeof v) && !strcmp(v, "a b c") && !param("x=1", "name", v, sizeof v));
    Console c = { "selftest", "Self test", { "bin" }, 1 };
    uint8_t z[512];
    const char *err;
    Buf saved = {0};
    size_t len = makeZip(z, "dir/a.bin", "hello", 0);
    assert(saveZip(&c, z, len, &saved, &err) == &c && !strcmp(saved.s, "\"a.bin\""));
    char got[8] = "";
    FILE *f = fopen(ATVGAME_ROM_DIR "/selftest/a.bin", "r");
    assert(f && fgets(got, sizeof got, f) && !strcmp(got, "hello"));
    fclose(f);
    unlink(ATVGAME_ROM_DIR "/selftest/a.bin"); rmdir(ATVGAME_ROM_DIR "/selftest");
    len = makeZip(z, "a.txt", "hello", 0);  // not a ROM for this console
    assert(!saveZip(&c, z, len, &saved, &err) && strstr(err, "no games"));
    len = makeZip(z, "a.bin", "hello", 0xfffffff0);  // an offset that wraps around in 32 bits
    assert(!saveZip(&c, z, len, &saved, &err) && strstr(err, "damaged"));
    assert(!saveZip(&c, z, 10, &saved, &err) && strstr(err, "damaged"));
    free(saved.s);
    puts("selftest ok");
}

int main(int argc, char **argv) {
    if (argc > 1 && !strcmp(argv[1], "selftest")) { selftest(); return 0; }
    signal(SIGCHLD, SIG_IGN);  // children reap themselves
    signal(SIGPIPE, SIG_IGN);
    int s = socket(AF_INET, SOCK_STREAM, 0), one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(PORT), .sin_addr.s_addr = htonl(INADDR_ANY) };
    if (s < 0 || bind(s, (struct sockaddr *)&a, sizeof a) || listen(s, 16)) { perror("atvromsd: listen"); return 1; }
    if (setgid(MOBILE_UID) || setuid(MOBILE_UID)) { perror("atvromsd: setuid"); return 1; }  // only port 80 needed root
    fprintf(stderr, "atvromsd: listening on port %d\n", PORT);
    for (;;) {
        int fd = accept(s, NULL, NULL);
        if (fd < 0) continue;
        if (fork() == 0) { close(s); serve(fd); shutdown(fd, SHUT_WR); close(fd); _exit(0); }
        close(fd);
    }
}
