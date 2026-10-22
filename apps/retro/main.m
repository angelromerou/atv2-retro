// Retro: a minimal libretro frontend for the Apple TV 2, built into one app per console
// (NES.app, SNES.app, ...; see tools/make-menu.py and tools/build-consoles.sh).
// The app's Info.plist names its console (RetroSystem, RetroTitle, RetroExtensions, RetroColor); its
// bundle holds the libretro core as core.dylib. It opens on a grid of that console's ROMs
// (ATVGAME_ROM_DIR/<system>); a game runs in-process at the display rate (CADisplayLink + OpenGL ES)
// with audio through an AudioQueue, and the Apple remote, Bluetooth gamepads and the PC keyboard
// (tools/atvkeys.py) drive libretro joypads. PS or Menu leaves the game back to the grid, and from the
// grid back to the home screen. Battery saves (SRAM) are written whenever they change.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#import <AudioToolbox/AudioToolbox.h>
#include <dlfcn.h>
#include <ifaddrs.h>
#include <arpa/inet.h>
#include <pthread.h>
#include <sys/stat.h>
#include "libretro.h"
#include "../../sdk/atvremote.h"

#define DATA_DIR "/var/mobile/Documents/retro"
#define MAX_PLAYERS 4

static FILE *logfile;
#define LOG(...) do { fprintf(logfile, __VA_ARGS__); fputc('\n', logfile); fflush(logfile); } while (0)

static UIColor *rgb(int hex) {
    return [UIColor colorWithRed:((hex >> 16) & 255) / 255.0 green:((hex >> 8) & 255) / 255.0 blue:(hex & 255) / 255.0 alpha:1];
}

static UILabel *label(CGRect frame, CGFloat size, BOOL bold, UIColor *color) {
    UILabel *l = [[[UILabel alloc] initWithFrame:frame] autorelease];
    l.font = bold ? [UIFont boldSystemFontOfSize:size] : [UIFont systemFontOfSize:size];
    l.textColor = color;
    l.backgroundColor = [UIColor clearColor];
    return l;
}

// the page that adds games (atvroms/atvromsd) is served at http://<this address>/
static NSString *addGamesURL(void) {
    struct ifaddrs *list, *i;
    NSString *url = nil;
    if (getifaddrs(&list)) return nil;
    for (i = list; i && !url; i = i->ifa_next)
        if (i->ifa_addr && i->ifa_addr->sa_family == AF_INET && !strncmp(i->ifa_name, "en", 2))
            url = [NSString stringWithFormat:@"http://%s", inet_ntoa(((struct sockaddr_in *)i->ifa_addr)->sin_addr)];
    freeifaddrs(list);
    return url;
}

// ---- console config (from the app's Info.plist) ----

static NSString *systemDir, *systemTitle, *corePath;
static NSArray *extensions;
static int systemColor;

static void loadConfig(void) {
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    systemDir = [[info objectForKey:@"RetroSystem"] retain];
    systemTitle = [[info objectForKey:@"RetroTitle"] retain];
    extensions = [[info objectForKey:@"RetroExtensions"] retain];
    unsigned c = 0x404040;
    [[NSScanner scannerWithString:[[info objectForKey:@"RetroColor"] substringFromIndex:1]] scanHexInt:&c];
    systemColor = c;
    corePath = [[[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"core.dylib"] retain];
}

// ---- core ----

static struct {
    void (*init)(void);
    void (*deinit)(void);
    void (*get_system_info)(struct retro_system_info *);
    void (*get_system_av_info)(struct retro_system_av_info *);
    void (*set_environment)(retro_environment_t);
    void (*set_video_refresh)(retro_video_refresh_t);
    void (*set_audio_sample)(retro_audio_sample_t);
    void (*set_audio_sample_batch)(retro_audio_sample_batch_t);
    void (*set_input_poll)(retro_input_poll_t);
    void (*set_input_state)(retro_input_state_t);
    void (*set_controller_port_device)(unsigned, unsigned);
    void (*run)(void);
    bool (*load_game)(const struct retro_game_info *);
    void (*unload_game)(void);
    void *(*get_memory_data)(unsigned);
    size_t (*get_memory_size)(unsigned);
} core;
static bool coreLoaded;

static enum retro_pixel_format pixelFormat = RETRO_PIXEL_FORMAT_0RGB1555;
static struct retro_system_av_info av;

// ---- video: the core's frame is copied into a contiguous staging buffer, uploaded on draw ----

static uint8_t *frame;  // staging, max_width * max_height * bytes per pixel
static unsigned frameW, frameH;
static bool frameDirty;

static unsigned bytesPerPixel(void) { return pixelFormat == RETRO_PIXEL_FORMAT_XRGB8888 ? 4 : 2; }

static void video_refresh(const void *data, unsigned w, unsigned h, size_t pitch) {
    if (!data) return;  // dupe: keep the previous frame
    if (w > av.geometry.max_width) w = av.geometry.max_width;
    if (h > av.geometry.max_height) h = av.geometry.max_height;
    unsigned bpp = bytesPerPixel();
    for (unsigned y = 0; y < h; y++) {
        const uint8_t *src = (const uint8_t *)data + y * pitch;
        uint8_t *dst = frame + y * w * bpp;
        if (pixelFormat == RETRO_PIXEL_FORMAT_0RGB1555) {  // GLES has no 1555 without alpha: convert to 565
            const uint16_t *s = (const uint16_t *)src; uint16_t *d = (uint16_t *)dst;
            for (unsigned x = 0; x < w; x++) d[x] = ((s[x] & 0x7fe0) << 1) | ((s[x] & 0x0200) >> 4) | (s[x] & 0x001f);
        } else memcpy(dst, src, w * bpp);
    }
    frameW = w; frameH = h; frameDirty = true;
}

// ---- audio: cores push samples into a ring buffer, the AudioQueue thread pulls ----

#define RING_FRAMES 16384
#define AQ_BUFFERS 3
#define AQ_FRAMES 1024
static int16_t ring[RING_FRAMES * 2];
static unsigned ringRead, ringWrite;  // in frames, monotonically increasing
static pthread_mutex_t ringLock = PTHREAD_MUTEX_INITIALIZER;
static AudioQueueRef queue;

static size_t audio_batch(const int16_t *data, size_t frames) {
    pthread_mutex_lock(&ringLock);
    for (size_t i = 0; i < frames; i++) {
        if (ringWrite - ringRead >= RING_FRAMES) ringRead++;  // full: drop the oldest frame
        unsigned slot = ringWrite++ % RING_FRAMES;
        ring[slot * 2] = data[i * 2]; ring[slot * 2 + 1] = data[i * 2 + 1];
    }
    pthread_mutex_unlock(&ringLock);
    return frames;
}

static void audio_sample(int16_t l, int16_t r) { int16_t s[2] = { l, r }; audio_batch(s, 1); }

static void fillBuffer(void *ud, AudioQueueRef q, AudioQueueBufferRef buf) {
    int16_t *out = buf->mAudioData;
    pthread_mutex_lock(&ringLock);
    for (unsigned i = 0; i < AQ_FRAMES; i++) {
        if (ringRead < ringWrite) {
            unsigned slot = ringRead++ % RING_FRAMES;
            out[i * 2] = ring[slot * 2]; out[i * 2 + 1] = ring[slot * 2 + 1];
        } else out[i * 2] = out[i * 2 + 1] = 0;  // underrun: silence
    }
    pthread_mutex_unlock(&ringLock);
    buf->mAudioDataByteSize = AQ_FRAMES * 4;
    AudioQueueEnqueueBuffer(q, buf, 0, NULL);
}

static void startAudio(double rate) {
    static bool session;
    if (!session) {
        AudioSessionInitialize(NULL, NULL, NULL, NULL);
        UInt32 category = kAudioSessionCategory_MediaPlayback;
        AudioSessionSetProperty(kAudioSessionProperty_AudioCategory, sizeof category, &category);
        AudioSessionSetActive(true);
        session = true;
    }
    ringRead = ringWrite = 0;
    AudioStreamBasicDescription f = { .mSampleRate = rate, .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
        .mBytesPerPacket = 4, .mFramesPerPacket = 1, .mBytesPerFrame = 4, .mChannelsPerFrame = 2, .mBitsPerChannel = 16 };
    if (AudioQueueNewOutput(&f, fillBuffer, NULL, NULL, NULL, 0, &queue) != noErr) { LOG("audio: queue failed"); queue = NULL; return; }
    for (int i = 0; i < AQ_BUFFERS; i++) {
        AudioQueueBufferRef b;
        AudioQueueAllocateBuffer(queue, AQ_FRAMES * 4, &b);
        fillBuffer(NULL, queue, b);
    }
    AudioQueueStart(queue, NULL);
}

static void stopAudio(void) {
    if (!queue) return;
    AudioQueueStop(queue, true);
    AudioQueueDispose(queue, true);
    queue = NULL;
}

// ---- input ----

static uint16_t pads[MAX_PLAYERS];  // bit = RETRO_DEVICE_ID_JOYPAD_*
static int remoteFd = -1;
static bool wantExitGame;  // PS / Menu pressed during a game

// Positional mapping: south/east/west/north on the pad = B/A/Y/X on a SNES-layout libretro joypad.
static int padToRetro(int b) {
    switch (b) {
        case ATVPAD_UP: return RETRO_DEVICE_ID_JOYPAD_UP;       case ATVPAD_DOWN: return RETRO_DEVICE_ID_JOYPAD_DOWN;
        case ATVPAD_LEFT: return RETRO_DEVICE_ID_JOYPAD_LEFT;   case ATVPAD_RIGHT: return RETRO_DEVICE_ID_JOYPAD_RIGHT;
        case ATVPAD_A: return RETRO_DEVICE_ID_JOYPAD_B;         case ATVPAD_B: return RETRO_DEVICE_ID_JOYPAD_A;
        case ATVPAD_X: return RETRO_DEVICE_ID_JOYPAD_Y;         case ATVPAD_Y: return RETRO_DEVICE_ID_JOYPAD_X;
        case ATVPAD_L1: return RETRO_DEVICE_ID_JOYPAD_L;        case ATVPAD_R1: return RETRO_DEVICE_ID_JOYPAD_R;
        case ATVPAD_L2: return RETRO_DEVICE_ID_JOYPAD_L2;       case ATVPAD_R2: return RETRO_DEVICE_ID_JOYPAD_R2;
        case ATVPAD_L3: return RETRO_DEVICE_ID_JOYPAD_L3;       case ATVPAD_R3: return RETRO_DEVICE_ID_JOYPAD_R3;
        case ATVPAD_SELECT: return RETRO_DEVICE_ID_JOYPAD_SELECT; case ATVPAD_START: return RETRO_DEVICE_ID_JOYPAD_START;
    }
    return -1;
}

// PC keyboard (HID page 7) as player 1: arrows, Z/X = B/A, A/S = Y/X, Q/W = L/R, Enter = Start, Shift = Select.
static int keyToRetro(uint32_t usage) {
    switch (usage) {
        case 0x52: return RETRO_DEVICE_ID_JOYPAD_UP;    case 0x51: return RETRO_DEVICE_ID_JOYPAD_DOWN;
        case 0x50: return RETRO_DEVICE_ID_JOYPAD_LEFT;  case 0x4f: return RETRO_DEVICE_ID_JOYPAD_RIGHT;
        case 0x1d: return RETRO_DEVICE_ID_JOYPAD_B;     case 0x1b: return RETRO_DEVICE_ID_JOYPAD_A;     // z x
        case 0x04: return RETRO_DEVICE_ID_JOYPAD_Y;     case 0x16: return RETRO_DEVICE_ID_JOYPAD_X;     // a s
        case 0x14: return RETRO_DEVICE_ID_JOYPAD_L;     case 0x1a: return RETRO_DEVICE_ID_JOYPAD_R;     // q w
        case 0x28: return RETRO_DEVICE_ID_JOYPAD_START; case 0xe1: case 0xe5: return RETRO_DEVICE_ID_JOYPAD_SELECT;
    }
    return -1;
}

// Apple remote as player 1: arrows, Select = A, Play/Pause = Start (Menu leaves the game).
static int remoteToRetro(int button) {
    switch (button) {
        case ATV_UP: return RETRO_DEVICE_ID_JOYPAD_UP;      case ATV_DOWN: return RETRO_DEVICE_ID_JOYPAD_DOWN;
        case ATV_LEFT: return RETRO_DEVICE_ID_JOYPAD_LEFT;  case ATV_RIGHT: return RETRO_DEVICE_ID_JOYPAD_RIGHT;
        case ATV_SELECT: return RETRO_DEVICE_ID_JOYPAD_A;   case ATV_PLAYPAUSE: return RETRO_DEVICE_ID_JOYPAD_START;
    }
    return -1;
}

static void input_poll(void) {
    int button, down; uint32_t page, usage;
    while (atvremote_poll(remoteFd, &button, &down, &page, &usage)) {
        int player = atvpad_player(page), id;
        if ((player >= 0 && usage == ATVPAD_HOME) || (player < 0 && page != 0x07 && button == ATV_MENU)) {
            if (down) wantExitGame = true;
            continue;
        }
        if (player >= 0) id = padToRetro(usage);
        else if (page == 0x07) { player = 0; id = keyToRetro(usage); }
        else { player = 0; id = remoteToRetro(button); }
        if (id < 0 || player >= MAX_PLAYERS) continue;
        if (down) pads[player] |= 1 << id; else pads[player] &= ~(1 << id);
    }
}

static int16_t input_state(unsigned port, unsigned device, unsigned index, unsigned id) {
    if (port >= MAX_PLAYERS || (device & RETRO_DEVICE_MASK) != RETRO_DEVICE_JOYPAD) return 0;
    if (id == RETRO_DEVICE_ID_JOYPAD_MASK) return pads[port];
    return (pads[port] >> id) & 1;
}

// ---- environment ----

static void core_log(enum retro_log_level level, const char *fmt, ...) {
    va_list ap; va_start(ap, fmt); vfprintf(logfile, fmt, ap); va_end(ap); fflush(logfile);
}

static bool environment(unsigned cmd, void *data) {
    switch (cmd) {
        case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY: *(const char **)data = DATA_DIR "/system"; return true;
        case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY: *(const char **)data = DATA_DIR "/saves"; return true;
        case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT: {
            enum retro_pixel_format f = *(const enum retro_pixel_format *)data;
            if (f == RETRO_PIXEL_FORMAT_XRGB8888 || f == RETRO_PIXEL_FORMAT_RGB565 || f == RETRO_PIXEL_FORMAT_0RGB1555) { pixelFormat = f; return true; }
            return false;
        }
        case RETRO_ENVIRONMENT_GET_LOG_INTERFACE: ((struct retro_log_callback *)data)->log = core_log; return true;
        case RETRO_ENVIRONMENT_GET_CAN_DUPE: *(bool *)data = true; return true;
        case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE: *(bool *)data = false; return true;
        case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
        case RETRO_ENVIRONMENT_SET_CONTROLLER_INFO:
        case RETRO_ENVIRONMENT_SET_PERFORMANCE_LEVEL: return true;
    }
    return false;  // everything else: core defaults
}

// ---- saves ----

static NSString *sramPath;
static uint32_t sramHash;

static uint32_t fnv(const uint8_t *p, size_t n) { uint32_t h = 2166136261u; while (n--) h = (h ^ *p++) * 16777619u; return h; }

static void loadSram(void) {
    uint8_t *mem = core.get_memory_data(RETRO_MEMORY_SAVE_RAM);
    size_t size = core.get_memory_size(RETRO_MEMORY_SAVE_RAM);
    if (!mem || !size) return;
    NSData *d = [NSData dataWithContentsOfFile:sramPath];
    if (d) memcpy(mem, d.bytes, MIN(size, d.length));
    sramHash = fnv(mem, size);
}

static void saveSramIfChanged(void) {
    uint8_t *mem = core.get_memory_data(RETRO_MEMORY_SAVE_RAM);
    size_t size = core.get_memory_size(RETRO_MEMORY_SAVE_RAM);
    if (!mem || !size) return;
    uint32_t h = fnv(mem, size);
    if (h == sramHash) return;
    if ([[NSData dataWithBytes:mem length:size] writeToFile:sramPath atomically:YES]) sramHash = h;
}

// ---- game lifecycle ----

static NSData *romData;  // kept alive while the game runs: some cores keep pointing at game.data

// Loads the core (once per process) and starts a game. Returns nil or an error message.
static NSString *startGame(NSString *romPath) {
    if (!coreLoaded) {
        void *lib = dlopen(corePath.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
        if (!lib) return [NSString stringWithFormat:@"Can't load the emulator core:\n%s", dlerror()];
#define SYM(field, name) if (!(*(void **)&core.field = dlsym(lib, "retro_" #name))) return @"Emulator core is missing retro_" #name;
        SYM(init, init) SYM(deinit, deinit) SYM(get_system_info, get_system_info) SYM(get_system_av_info, get_system_av_info)
        SYM(set_environment, set_environment) SYM(set_video_refresh, set_video_refresh) SYM(set_audio_sample, set_audio_sample)
        SYM(set_audio_sample_batch, set_audio_sample_batch) SYM(set_input_poll, set_input_poll) SYM(set_input_state, set_input_state)
        SYM(set_controller_port_device, set_controller_port_device) SYM(run, run) SYM(load_game, load_game)
        SYM(unload_game, unload_game) SYM(get_memory_data, get_memory_data) SYM(get_memory_size, get_memory_size)
        coreLoaded = true;
    }
    // libretro cores must support init/deinit cycles, so every game gets a fresh core state
    core.set_environment(environment);
    core.init();
    core.set_video_refresh(video_refresh);
    core.set_audio_sample(audio_sample);
    core.set_audio_sample_batch(audio_batch);
    core.set_input_poll(input_poll);
    core.set_input_state(input_state);

    struct retro_system_info sys = {0};
    core.get_system_info(&sys);
    struct retro_game_info game = { .path = romPath.fileSystemRepresentation };
    if (!sys.need_fullpath) {
        romData = [[NSData alloc] initWithContentsOfFile:romPath];
        if (!romData) { core.deinit(); return [NSString stringWithFormat:@"Can't read %@", romPath.lastPathComponent]; }
        game.data = romData.bytes; game.size = romData.length;
    }
    if (!core.load_game(&game)) {
        core.deinit();
        [romData release]; romData = nil;
        return [NSString stringWithFormat:@"%s couldn't load %@", sys.library_name, romPath.lastPathComponent];
    }
    for (unsigned p = 0; p < MAX_PLAYERS; p++) core.set_controller_port_device(p, RETRO_DEVICE_JOYPAD);
    core.get_system_av_info(&av);
    LOG("%s %s: %s %ux%u (max %ux%u) %.2f fps %.0f Hz", sys.library_name, sys.library_version, romPath.lastPathComponent.UTF8String,
        av.geometry.base_width, av.geometry.base_height, av.geometry.max_width, av.geometry.max_height, av.timing.fps, av.timing.sample_rate);
    frame = calloc(av.geometry.max_width * av.geometry.max_height, 4);
    frameW = frameH = 0;
    memset(pads, 0, sizeof pads);
    wantExitGame = false;

    NSString *saves = [NSString stringWithFormat:@DATA_DIR "/saves/%@", systemDir];
    mkdir(saves.fileSystemRepresentation, 0755);
    [sramPath release];
    sramPath = [[saves stringByAppendingPathComponent:[romPath.lastPathComponent.stringByDeletingPathExtension stringByAppendingPathExtension:@"srm"]] retain];
    loadSram();
    startAudio(av.timing.sample_rate);
    return nil;
}

static void stopGame(void) {
    stopAudio();
    saveSramIfChanged();
    core.unload_game();
    core.deinit();
    free(frame); frame = NULL;
    [romData release]; romData = nil;
}

// ---- game view: CAEAGLLayer + CADisplayLink (the Apple TV's iOS has no GLKit) ----

static GLuint compileShader(GLenum type, const char *src) {
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, NULL);
    glCompileShader(s);
    return s;
}

@interface GameView : UIView
@property (nonatomic, copy) void (^onExit)(void);
- (void)stop;
@end

@implementation GameView {
    EAGLContext *context;
    GLuint framebuffer, renderbuffer, texture, program;
    GLint bufW, bufH;
    CADisplayLink *link;
    unsigned saveCounter;
}

+ (Class)layerClass { return [CAEAGLLayer class]; }

- (id)initWithFrame:(CGRect)f {
    if (!(self = [super initWithFrame:f])) return nil;
    self.backgroundColor = [UIColor blackColor];
    ((CAEAGLLayer *)self.layer).opaque = YES;
    context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    [EAGLContext setCurrentContext:context];
    glGenFramebuffers(1, &framebuffer);
    glGenRenderbuffers(1, &renderbuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glBindRenderbuffer(GL_RENDERBUFFER, renderbuffer);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, renderbuffer);

    program = glCreateProgram();
    glAttachShader(program, compileShader(GL_VERTEX_SHADER,
        "attribute vec2 pos; attribute vec2 uv; varying vec2 v;"
        "void main() { gl_Position = vec4(pos, 0.0, 1.0); v = uv; }"));
    glAttachShader(program, compileShader(GL_FRAGMENT_SHADER,
        "precision mediump float; varying vec2 v; uniform sampler2D tex;"
        "void main() { gl_FragColor = texture2D(tex, v); }"));
    glBindAttribLocation(program, 0, "pos");
    glBindAttribLocation(program, 1, "uv");
    glLinkProgram(program);
    glUseProgram(program);

    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    if (pixelFormat == RETRO_PIXEL_FORMAT_XRGB8888)
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, av.geometry.max_width, av.geometry.max_height, 0, GL_BGRA_EXT, GL_UNSIGNED_BYTE, NULL);
    else
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB, av.geometry.max_width, av.geometry.max_height, 0, GL_RGB, GL_UNSIGNED_SHORT_5_6_5, NULL);

    link = [[CADisplayLink displayLinkWithTarget:self selector:@selector(step)] retain];
    [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    return self;
}

- (void)stop {
    [link invalidate]; [link release]; link = nil;
    [EAGLContext setCurrentContext:context];
    glDeleteTextures(1, &texture);
    glDeleteProgram(program);
    glDeleteRenderbuffers(1, &renderbuffer);
    glDeleteFramebuffers(1, &framebuffer);
    [EAGLContext setCurrentContext:nil];
    [context release]; context = nil;
}

- (void)dealloc { [_onExit release]; [super dealloc]; }

- (void)layoutSubviews {
    if (!context) return;
    [EAGLContext setCurrentContext:context];
    glBindRenderbuffer(GL_RENDERBUFFER, renderbuffer);
    [context renderbufferStorage:GL_RENDERBUFFER fromDrawable:(CAEAGLLayer *)self.layer];
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &bufW);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &bufH);
}

- (void)step {
    core.run();
    if (wantExitGame) {  // tear down after this frame callback has returned
        wantExitGame = false;
        void (^exitBlock)(void) = [[self.onExit copy] autorelease];
        dispatch_async(dispatch_get_main_queue(), exitBlock);
        return;
    }
    if (++saveCounter % 120 == 0) saveSramIfChanged();  // every ~2 s
    if (!bufW || !frameW) return;

    [EAGLContext setCurrentContext:context];
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glViewport(0, 0, bufW, bufH);
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);
    glBindTexture(GL_TEXTURE_2D, texture);
    if (frameDirty) {
        if (pixelFormat == RETRO_PIXEL_FORMAT_XRGB8888)
            glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, frameW, frameH, GL_BGRA_EXT, GL_UNSIGNED_BYTE, frame);
        else
            glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, frameW, frameH, GL_RGB, GL_UNSIGNED_SHORT_5_6_5, frame);
        frameDirty = false;
    }
    // fit the core's aspect ratio inside the screen (in normalized device coordinates)
    GLfloat aspect = av.geometry.aspect_ratio > 0 ? av.geometry.aspect_ratio : (GLfloat)frameW / frameH;
    GLfloat w = (GLfloat)bufH * aspect / bufW, h = 1;
    if (w > 1) { h = 1 / w; w = 1; }
    GLfloat u = (GLfloat)frameW / av.geometry.max_width, v = (GLfloat)frameH / av.geometry.max_height;
    GLfloat quad[] = { -w, h, 0, 0,   w, h, u, 0,   -w, -h, 0, v,   w, -h, u, v };
    glEnableVertexAttribArray(0);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 16, quad);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 16, quad + 2);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glBindRenderbuffer(GL_RENDERBUFFER, renderbuffer);
    [context presentRenderbuffer:GL_RENDERBUFFER];
}
@end

// ---- ROM grid ----

#define COLS 4
#define TILE_W 250
#define TILE_H 140
#define GAP 34
#define REPEAT_DELAY 0.4
#define REPEAT_EVERY 0.12

// "Super Mario Bros. (USA) [!].nes" -> "Super Mario Bros."
static NSString *romTitle(NSString *file) {
    static NSRegularExpression *tags;
    if (!tags) tags = [[NSRegularExpression alloc] initWithPattern:@"\\s*[\\(\\[][^\\)\\]]*[\\)\\]]" options:0 error:NULL];
    NSString *name = file.stringByDeletingPathExtension;
    NSString *clean = [tags stringByReplacingMatchesInString:name options:0 range:NSMakeRange(0, name.length) withTemplate:@""];
    return clean.length ? clean : name;
}

@interface BrowserVC : UIViewController
@end

@implementation BrowserVC {
    NSArray *roms;             // full paths
    NSMutableArray *tiles;     // views
    UIView *grid;
    UILabel *message;
    GameView *game;
    int focus;
    NSTimer *timer;
    int heldButton;
    NSTimeInterval heldSince, lastRepeat;
}

- (void)viewDidLoad {
    CGSize size = self.view.bounds.size;
    self.view.backgroundColor = rgb(0x12151c);
    UIView *band = [[[UIView alloc] initWithFrame:CGRectMake(0, 0, size.width, 8)] autorelease];
    band.backgroundColor = rgb(systemColor);
    [self.view addSubview:band];
    UILabel *title = label(CGRectMake(80, 40, 900, 60), 46, YES, [UIColor whiteColor]);
    title.text = systemTitle;
    [self.view addSubview:title];
    NSString *url = addGamesURL();
    UILabel *add = label(CGRectMake(size.width - 80 - 600, 58, 600, 30), 22, NO, rgb(0x9aa3b2));
    add.textAlignment = NSTextAlignmentRight;
    add.text = url ? [@"Add games: " stringByAppendingString:url] : @"";
    [self.view addSubview:add];
    UILabel *hint = label(CGRectMake(80, size.height - 70, size.width - 160, 30), 20, NO, rgb(0x6b7280));
    hint.text = @"Select / Cross: play     Menu / Circle / PS: home     In a game, PS or Menu comes back here";
    [self.view addSubview:hint];
    message = label(CGRectMake(80, 140, size.width - 160, 300), 26, NO, rgb(0xc8ccd6));
    message.numberOfLines = 0;
    [self.view addSubview:message];

    UIView *viewport = [[[UIView alloc] initWithFrame:CGRectMake(0, 120, size.width, size.height - 120 - 80)] autorelease];
    viewport.clipsToBounds = YES;
    [self.view addSubview:viewport];
    grid = [[UIView alloc] initWithFrame:viewport.bounds];
    [viewport addSubview:grid];

    NSString *dir = [@ATVGAME_ROM_DIR stringByAppendingPathComponent:systemDir];
    NSMutableArray *found = [NSMutableArray array];
    for (NSString *f in [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)])
        if ([extensions containsObject:f.pathExtension.lowercaseString]) [found addObject:[dir stringByAppendingPathComponent:f]];
    roms = [found retain];
    if (!roms.count)
        message.text = [NSString stringWithFormat:@"No %@ games yet.\n\nTo add some, open %@ in a browser on your phone or computer and drop the ROM files there.", systemTitle, url ? url : @"this Apple TV's address"];

    tiles = [NSMutableArray new];
    CGFloat left = (size.width - (COLS * TILE_W + (COLS - 1) * GAP)) / 2;
    for (NSUInteger i = 0; i < roms.count; i++) {
        UIView *v = [[[UIView alloc] initWithFrame:CGRectMake(left + (i % COLS) * (TILE_W + GAP), 20 + (i / COLS) * (TILE_H + GAP), TILE_W, TILE_H)] autorelease];
        v.backgroundColor = rgb(systemColor);
        v.layer.cornerRadius = 14;
        v.layer.borderColor = [UIColor whiteColor].CGColor;
        UILabel *t = label(CGRectMake(16, 14, TILE_W - 32, TILE_H - 28), 25, YES, [UIColor whiteColor]);
        t.numberOfLines = 3;
        t.text = romTitle([[roms objectAtIndex:i] lastPathComponent]);
        [v addSubview:t];
        [grid addSubview:v];
        [tiles addObject:v];
    }
    [self showFocus];
    timer = [NSTimer scheduledTimerWithTimeInterval:1 / 60.0 target:self selector:@selector(tick) userInfo:nil repeats:YES];
}

- (void)showFocus {
    for (NSUInteger i = 0; i < tiles.count; i++) {
        UIView *v = [tiles objectAtIndex:i];
        BOOL on = (int)i == focus;
        [UIView animateWithDuration:0.15 animations:^{
            v.transform = on ? CGAffineTransformMakeScale(1.08, 1.08) : CGAffineTransformIdentity;
            v.alpha = on ? 1 : 0.7;
        }];
        v.layer.borderWidth = on ? 4 : 0;
    }
    if (!tiles.count) return;
    // keep the focused row inside the viewport
    CGFloat viewportH = grid.superview.bounds.size.height, top = 20 + (focus / COLS) * (TILE_H + GAP) - 10;
    CGFloat bottom = top + TILE_H + 20, y = grid.frame.origin.y;
    if (top + y < 0) y = -top;
    if (bottom + y > viewportH) y = viewportH - bottom;
    [UIView animateWithDuration:0.2 animations:^{ grid.frame = CGRectMake(0, y, grid.frame.size.width, grid.frame.size.height); }];
}

- (void)play {
    if (!roms.count) return;
    NSString *error = startGame([roms objectAtIndex:focus]);
    if (error) { message.text = error; LOG("%s", error.UTF8String); return; }
    message.text = @"";
    [timer invalidate]; timer = nil;
    game = [[GameView alloc] initWithFrame:self.view.bounds];
    __block BrowserVC *me = self;
    game.onExit = ^{ [me endGame]; };
    [self.view addSubview:game];
}

- (void)endGame {
    [game stop];
    stopGame();
    [game removeFromSuperview];
    [game release]; game = nil;
    heldButton = 0;
    timer = [NSTimer scheduledTimerWithTimeInterval:1 / 60.0 target:self selector:@selector(tick) userInfo:nil repeats:YES];
}

- (void)press:(int)button {
    int n = (int)tiles.count, f = focus;
    switch (button) {
        case ATV_LEFT: if (f % COLS) f--; break;
        case ATV_RIGHT: if (f % COLS < COLS - 1 && f + 1 < n) f++; break;
        case ATV_UP: if (f >= COLS) f -= COLS; break;
        case ATV_DOWN: if (f + COLS < n) f += COLS; else if (f / COLS < (n - 1) / COLS) f = n - 1; break;
        case ATV_SELECT: case ATV_PLAYPAUSE: [self play]; return;
        case ATV_MENU: exit(0);  // back to the AppleTV home screen
    }
    if (f != focus) { focus = f; [self showFocus]; }
}

- (void)tick {
    int button, down; uint32_t page, usage;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    while (atvremote_poll(remoteFd, &button, &down, &page, &usage)) {
        bool pad = atvpad_player(page) >= 0;
        if (pad && usage == ATVPAD_HOME) { if (down) exit(0); continue; }
        if (!button) continue;
        if (down) [self press:button];
        if (game) return;  // a game started: it reads the rest of the input
        // gamepads only send press/release, so repeat held directions here (the remote repeats by itself)
        if (pad && button <= ATV_RIGHT) { heldButton = down ? button : 0; heldSince = lastRepeat = now; }
    }
    if (heldButton && now - heldSince > REPEAT_DELAY && now - lastRepeat > REPEAT_EVERY) {
        lastRepeat = now;
        [self press:heldButton];
    }
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)o { return UIInterfaceOrientationIsLandscape(o); }
@end

@interface AD : UIResponder <UIApplicationDelegate>
@property (nonatomic, retain) UIWindow *window;
@end
@implementation AD
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.window = [[[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds] autorelease];
    self.window.rootViewController = [[BrowserVC new] autorelease];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        logfile = fopen("/tmp/retro.log", "w");
        mkdir(DATA_DIR, 0755); mkdir(DATA_DIR "/system", 0755); mkdir(DATA_DIR "/saves", 0755);
        loadConfig();
        remoteFd = atvremote_open_flags(ATVREMOTE_HANDLES_HOME);  // PS: game -> list -> home, handled here
        return UIApplicationMain(argc, argv, nil, @"AD");
    }
}
