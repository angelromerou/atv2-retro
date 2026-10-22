// doomgeneric platform layer for the Apple TV 2 (iOS 6 UIKit app launched by the ATVLaunch tweak).
// Doom runs on its own thread; frames are handed to a CALayer on the main thread.
// Input: Apple remote (forwarded by the tweak) or a PC keyboard via tools/atvkeys.py, both over UDP.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <sys/time.h>
#include <sys/stat.h>
#include "doomgeneric.h"
#include "doomkeys.h"
#include "../../sdk/atvremote.h"

static CALayer *screenLayer;
static int remoteFd = -1;

// ---- input ----

static unsigned char keyQueue[64][2];  // [pressed, doomkey]
static int qHead, qTail;
static uint8_t held[0x10000 >> 3];     // per page/usage "is down" bits, to drop the remote's key repeats

static void pushKey(int pressed, unsigned char key) {
    int next = (qTail + 1) % 64;
    if (next == qHead) return;  // full: drop
    keyQueue[qTail][0] = pressed; keyQueue[qTail][1] = key; qTail = next;
}

// HID keyboard page (0x07) usage -> doom key, for the PC keyboard.
static unsigned char hidKeyToDoom(uint32_t u) {
    if (u >= 0x04 && u <= 0x1d) return 'a' + (u - 0x04);
    if (u >= 0x1e && u <= 0x26) return '1' + (u - 0x1e);
    switch (u) {
        case 0x27: return '0';           case 0x28: return KEY_ENTER;
        case 0x29: return KEY_ESCAPE;    case 0x2a: return KEY_BACKSPACE;
        case 0x2b: return KEY_TAB;       case 0x2c: return KEY_USE;      // space
        case 0x2d: return KEY_MINUS;     case 0x2e: return KEY_EQUALS;
        case 0x4f: return KEY_RIGHTARROW; case 0x50: return KEY_LEFTARROW;
        case 0x51: return KEY_DOWNARROW;  case 0x52: return KEY_UPARROW;
        case 0xe0: case 0xe4: return KEY_FIRE;    // ctrl
        case 0xe1: case 0xe5: return KEY_RSHIFT;  // shift = run
        case 0xe2: case 0xe6: return KEY_RALT;    // alt = strafe
    }
    return 0;
}

static void pollRemote(void) {
    int button, down; uint32_t page, usage;
    while (atvremote_poll(remoteFd, &button, &down, &page, &usage)) {
        uint32_t bit = ((page & 0xff) << 8) | (usage & 0xff);
        int was = (held[bit >> 3] >> (bit & 7)) & 1;
        if (down == was) continue;  // auto-repeat or stray up
        held[bit >> 3] ^= 1 << (bit & 7);

        if (page == 0x07) { unsigned char k = hidKeyToDoom(usage); if (k) pushKey(down, k); continue; }
        if (atvpad_player(page) >= 0) {  // Bluetooth gamepad (any player controls the game)
            switch (usage) {
                case ATVPAD_UP:    case ATVPAD_RS_UP:   pushKey(down, KEY_UPARROW); break;
                case ATVPAD_DOWN:  case ATVPAD_RS_DOWN: pushKey(down, KEY_DOWNARROW); break;
                case ATVPAD_LEFT:  pushKey(down, KEY_LEFTARROW); break;
                case ATVPAD_RIGHT: pushKey(down, KEY_RIGHTARROW); break;
                case ATVPAD_L1: case ATVPAD_RS_LEFT:  pushKey(down, KEY_STRAFE_L); break;
                case ATVPAD_R1: case ATVPAD_RS_RIGHT: pushKey(down, KEY_STRAFE_R); break;
                case ATVPAD_A: pushKey(down, KEY_USE); pushKey(down, KEY_ENTER); pushKey(down, 'y'); break;  // use / select / yes
                case ATVPAD_B: pushKey(down, KEY_BACKSPACE); pushKey(down, 'n'); break;                  // menu back / no
                case ATVPAD_X: case ATVPAD_R2: pushKey(down, KEY_FIRE); break;
                case ATVPAD_Y: pushKey(down, ']'); break;  // next weapon (bound in DG_Init)
                case ATVPAD_L2: pushKey(down, KEY_RSHIFT); break;  // run
                case ATVPAD_START:  pushKey(down, KEY_ESCAPE); break;
                case ATVPAD_SELECT: pushKey(down, KEY_TAB); break;  // automap
            }
            continue;
        }
        switch (button) {  // the remote has only 7 buttons, so some do double duty
            case ATV_UP:    pushKey(down, KEY_UPARROW); break;
            case ATV_DOWN:  pushKey(down, KEY_DOWNARROW); break;
            case ATV_LEFT:  pushKey(down, KEY_LEFTARROW); break;
            case ATV_RIGHT: pushKey(down, KEY_RIGHTARROW); break;
            case ATV_SELECT:    pushKey(down, KEY_FIRE); pushKey(down, KEY_ENTER); break;  // fire / menu select
            case ATV_PLAYPAUSE: pushKey(down, KEY_USE); pushKey(down, 'y'); break;        // open doors / confirm
            case ATV_MENU:      pushKey(down, KEY_ESCAPE); break;  // hold Menu = quit app (tweak)
        }
    }
}

int DG_GetKey(int *pressed, unsigned char *key) {
    pollRemote();
    if (qHead == qTail) return 0;
    *pressed = keyQueue[qHead][0]; *key = keyQueue[qHead][1];
    qHead = (qHead + 1) % 64;
    return 1;
}

// ---- video / timing ----

extern int key_nextweapon, key_prevweapon;

// Runs after the config is loaded, so these bindings win over a saved 0 (= unbound).
void DG_Init(void) {
    remoteFd = atvremote_open();
    key_nextweapon = ']'; key_prevweapon = '[';
}

void DG_DrawFrame(void) {
    static CGColorSpaceRef rgb;
    if (!rgb) rgb = CGColorSpaceCreateDeviceRGB();
    size_t bytes = DOOMGENERIC_RESX * DOOMGENERIC_RESY * 4;
    CFDataRef data = CFDataCreate(NULL, (const UInt8 *)DG_ScreenBuffer, bytes);
    CGDataProviderRef prov = CGDataProviderCreateWithCFData(data);
    // buffer is 0x00RRGGBB per uint32, little-endian
    CGImageRef img = CGImageCreate(DOOMGENERIC_RESX, DOOMGENERIC_RESY, 8, 32, DOOMGENERIC_RESX * 4, rgb,
                                   kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst, prov, NULL, false,
                                   kCGRenderingIntentDefault);
    CGDataProviderRelease(prov); CFRelease(data);
    dispatch_async(dispatch_get_main_queue(), ^{
        [CATransaction begin]; [CATransaction setDisableActions:YES];
        screenLayer.contents = (id)img;
        [CATransaction commit];
        CGImageRelease(img);
    });
}

void DG_SleepMs(uint32_t ms) { usleep(ms * 1000); }

uint32_t DG_GetTicksMs(void) {
    struct timeval tv; gettimeofday(&tv, NULL);
    return (uint32_t)(tv.tv_sec * 1000 + tv.tv_usec / 1000);
}

void DG_SetWindowTitle(const char *title) {}

// ---- app ----

@interface DoomVC : UIViewController @end
@implementation DoomVC
- (void)viewDidLoad {
    self.view.backgroundColor = [UIColor blackColor];
    screenLayer = [CALayer layer];
    screenLayer.magnificationFilter = kCAFilterNearest;
    [self.view.layer addSublayer:screenLayer];
}
- (void)viewDidLayoutSubviews {
    CGSize s = self.view.bounds.size;
    CGFloat h = s.height, w = h * 4 / 3;  // Doom's 320x200 was shown at 4:3
    if (w > s.width) { w = s.width; h = w * 3 / 4; }
    screenLayer.frame = CGRectMake((s.width - w) / 2, (s.height - h) / 2, w, h);
}
- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)o { return UIInterfaceOrientationIsLandscape(o); }
@end

@interface AD : UIResponder <UIApplicationDelegate> @property (nonatomic, retain) UIWindow *window; @end
@implementation AD
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.window = [[[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds] autorelease];
    self.window.rootViewController = [[DoomVC new] autorelease];
    [self.window makeKeyAndVisible];
    [NSThread detachNewThreadSelector:@selector(runDoom) toTarget:self withObject:nil];
    return YES;
}
- (void)runDoom {
    @autoreleasepool {
        NSString *wad = [[NSBundle mainBundle] pathForResource:@"doom1" ofType:@"wad"];
        char *argv[] = { "doom", "-iwad", (char *)wad.fileSystemRepresentation, NULL };
        doomgeneric_Create(3, argv);
        for (;;) doomgeneric_Tick();
    }
}
@end

int main(int argc, char **argv) {
    // app bundle is read-only for "mobile": keep config + savegames in a writable dir
    const char *dir = "/var/mobile/Documents/doom";
    mkdir("/var/mobile/Documents", 0755); mkdir(dir, 0755);
    chdir(dir); setenv("HOME", dir, 1);
    freopen("/tmp/doom.log", "w", stdout); freopen("/tmp/doom.log", "a", stderr);
    setvbuf(stdout, NULL, _IOLBF, 0);
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, @"AD"); }
}
