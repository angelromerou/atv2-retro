// Loaded into AppleTV.app (com.apple.lowtide) by MobileSubstrate.
// 1. On Darwin notification ATVLAUNCH_NOTIFICATION, launches the bundle id stored in ATVLAUNCH_FILE.
// 2. While an atvdev app is running (live pid in ATVREMOTE_PIDFILE), forwards Apple remote
//    events to it over UDP and hides them from the AppleTV UI. Holding Menu kills the app.
// 3. Packets sent to 127.0.0.1:ATVREMOTE_INJECT_PORT (by atvpadd for gamepads) are posted to the
//    UI as remote button events, so a controller can drive the home screen.
// 4. On ATVSHOT_NOTIFICATION, saves a screenshot of whatever is on the TV to ATVSHOT_FILE (atvopen --screenshot).
// 5. Keeps the screensaver countdown from running out while an atvdev app is open.
// 6. Adds main-menu items for our apps: AppleTV.app only loads appliance plists whose principal class
//    is one of its five built-in ones, so plists with FRPrincipalClass = APP_APPLIANCE_CLASS are loaded
//    here as a runtime subclass of BRBaseAppliance and shown in the top row (ATVDEVTopRow) or the grid below it;
//    selecting one launches the bundle id in its ATVDEVLaunchID key. (tools/deploy.sh installs an app's <App>.app/ATVMenu/ files into AppleTV.app.)
//    On iOS 8 (ATV3) the stock home screen is kept: our items join its grid and only the loading/launching hooks apply.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <notify.h>
#include <dlfcn.h>
#include <arpa/inet.h>
#include <mach/mach_time.h>
#include "../sdk/atvremote.h"

#define MENU_HOLD_KILL 1.5  // seconds

typedef struct __IOHIDEvent *IOHIDEventRef;
int IOHIDEventGetType(IOHIDEventRef);
int IOHIDEventGetIntegerValue(IOHIDEventRef, int field);
enum { kIOHIDEventTypeKeyboard = 3, kKbdPage = 3 << 16, kKbdUsage = (3 << 16) | 1, kKbdDown = (3 << 16) | 2 };

@interface UIApplication (BR)
- (void)activateApplicationWithIdentifier:(NSString *)ident;
- (void)postEvent:(id)brEvent;
@end
@interface NSObject (BR)
+ (id)defaultWorkspace;
+ (id)eventWithAction:(int)action value:(int)value atTime:(double)time originator:(unsigned)originator;
- (BOOL)openApplicationWithBundleID:(NSString *)ident;
- (NSString *)principalClassName;
+ (id)eventWithPage:(unsigned short)page usage:(unsigned short)usage value:(int)value;
+ (id)infoForApplianceDescription:(NSDictionary *)description;
- (id)initWithApplianceInfo:(id)info;
+ (id)imageWithPath:(NSString *)path;
- (void)setCustomLogoControl:(id)control;
- (void)setState:(long)state;
@end

#define APP_APPLIANCE_CLASS "ATVDEVAppAppliance"
static Class appAppliance;
static NSMutableDictionary *launchIds;    // appliance key -> bundle id to launch
static NSMutableSet *topRowKeys;          // appliances whose plist sets ATVDEVTopRow
static NSMutableDictionary *shelfImages;  // appliance key -> path of its ATVDEVShelfImage (in AppleTV.app)
static IMP origLoadAppliance, origPushController;

static void launchApp(NSString *ident) {
    UIApplication *app = [UIApplication sharedApplication];
    if ([app respondsToSelector:@selector(activateApplicationWithIdentifier:)]) [app activateApplicationWithIdentifier:ident];
    else [[objc_getClass("LSApplicationWorkspace") defaultWorkspace] openApplicationWithBundleID:ident];  // iOS 8 (ATV3)
}

// -[BRApplianceManager _loadApplianceAtPath:]
static id hookedLoadAppliance(id self, SEL _cmd, NSString *path) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
    NSString *launchId = [d objectForKey:@"ATVDEVLaunchID"], *key = [d objectForKey:@"FRApplianceIdentifier"];
    if ([[d objectForKey:@"FRPrincipalClass"] isEqual:@APP_APPLIANCE_CLASS] && launchId) {
        id info = [objc_getClass("BRApplianceInfo") infoForApplianceDescription:d];
        if (!info) return nil;
        [launchIds setObject:launchId forKey:key];
        if ([[d objectForKey:@"ATVDEVTopRow"] boolValue]) [topRowKeys addObject:key];
        NSString *shelf = [d objectForKey:@"ATVDEVShelfImage"];
        if (shelf) [shelfImages setObject:[[path stringByDeletingLastPathComponent] stringByAppendingPathComponent:shelf] forKey:key];
        return [[[appAppliance alloc] initWithApplianceInfo:info] autorelease];
    }
    return ((id (*)(id, SEL, NSString *))origLoadAppliance)(self, _cmd, path);
}

// iOS 8 (ATV3): -[BRApplianceManager _loadApplianceWithInfo:] gets the parsed appliance plist. The items land in the
// stock grid, where the user arranges or hides them like Apple's; ATVDEVTopRow and ATVDEVShelfImage are not used.
static IMP origLoadApplianceWithInfo;
static id hookedLoadApplianceWithInfo(id self, SEL _cmd, id info) {
    if ([[info principalClassName] isEqual:@APP_APPLIANCE_CLASS]) {
        NSString *launchId = [[info performSelector:@selector(info)] objectForKey:@"ATVDEVLaunchID"];
        if (!launchId) return nil;
        [launchIds setObject:launchId forKey:[info performSelector:@selector(key)]];
        return [[[appAppliance alloc] initWithApplianceInfo:info] autorelease];
    }
    return ((id (*)(id, SEL, id))origLoadApplianceWithInfo)(self, _cmd, info);
}

// -[ATVMainMenuController _pushControllerForApplianceOrMerchant:] (iOS 8: _pushControllerForAppliance:)
static void hookedPushController(id self, SEL _cmd, id item) {
    if ([item isKindOfClass:appAppliance]) {
        NSString *launchId = [launchIds objectForKey:[[item performSelector:@selector(applianceInfo)] performSelector:@selector(key)]];
        if (launchId) launchApp(launchId);
        return;
    }
    ((void (*)(id, SEL, id))origPushController)(self, _cmd, item);
}

static NSString *applianceKey(id a) { return [[a performSelector:@selector(applianceInfo)] performSelector:@selector(key)]; }

// The top shelf above the top row: a BRTopShelfView showing a logo in place of Apple's.
@interface ATVDEVShelf : NSObject { id _view; }
@end
@implementation ATVDEVShelf
- (id)initWithImagePath:(NSString *)path {
    if ((self = [super init])) {
        _view = [[objc_getClass("BRTopShelfView") alloc] init];
        id logo = [[objc_getClass("BRImageControl") alloc] init];
        [logo setImage:[objc_getClass("BRImage") imageWithPath:path]];
        [_view setCustomLogoControl:logo];
        [logo release];
        [_view setState:1];  // 0 shows Apple's logo, 1 the custom one (stretched over the whole shelf)
    }
    return self;
}
- (void)dealloc { [_view release]; [super dealloc]; }
- (id)mainMenuShelfView { return _view; }
- (void)refresh {}
- (void)selectCategoryWithIdentifier:(id)ident {}
@end

// -[ATVDEVAppAppliance topShelfController]
static id appTopShelfController(id self, SEL _cmd) {
    static NSMutableDictionary *shelves;
    if (!shelves) shelves = [NSMutableDictionary new];
    NSString *key = applianceKey(self), *img = [shelfImages objectForKey:key];
    id s = [shelves objectForKey:key];
    if (!s && img) {
        s = [[[ATVDEVShelf alloc] initWithImagePath:img] autorelease];
        [shelves setObject:s forKey:key];
    }
    return s;
}

// The top row keeps the ATVDEVTopRow appliances. Every other main-menu item goes in the lower,
// scrolling grid (MainMenuLayout.plist "grid"), where the internet apps used to be (Apple's
// merchant list is empty now). Computers is hidden. The grid shows [[item info] menuTitle] and asks
// _imageForMerchant: for the icon, so the appliances moved there answer like merchants.
#define HIDDEN_APPLIANCE @"com.apple.frontrow.appliance.computers"
static NSArray *gridAppliances = nil;  // in the menu's sort order (FRAppliancePreferedOrderValue)
static IMP origSetAppliances, origSetMerchants, origImageForMerchant, origCacheMerchantImage;

static BOOL inGrid(id o) { return [gridAppliances indexOfObjectIdenticalTo:o] != NSNotFound; }

// merchant-like accessors for the appliance classes in the grid
static id applianceSelf(id self, SEL _cmd) { return self; }
static id applianceMenuTitle(id self, SEL _cmd) { return [[self performSelector:@selector(applianceInfo)] performSelector:@selector(name)]; }
static id applianceIdentifier(id self, SEL _cmd) { return applianceKey(self); }
static long applianceBadgeCount(id self, SEL _cmd) { return 0; }
static void makeMerchantLike(Class c) {
    class_addMethod(c, @selector(info), (IMP)applianceSelf, "@@:");
    class_addMethod(c, @selector(menuTitle), (IMP)applianceMenuTitle, "@@:");
    class_addMethod(c, @selector(identifier), (IMP)applianceIdentifier, "@@:");
    class_addMethod(c, @selector(iconBadgeCount), (IMP)applianceBadgeCount, "l@:");
}

// -[ATVMainMenuController setInternetMerchants:]: Apple's merchants (if any) then the appliances
static void hookedSetMerchants(id self, SEL _cmd, NSArray *merchants) {
    NSArray *apple = [merchants filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id o, NSDictionary *b) { return !inGrid(o); }]];
    ((void (*)(id, SEL, id))origSetMerchants)(self, _cmd, [apple arrayByAddingObjectsFromArray:gridAppliances]);
}

// -[ATVMainMenuController setAppliances:]: split the appliances between the top row and the grid
static void hookedSetAppliances(id self, SEL _cmd, NSArray *appliances) {
    NSMutableArray *top = [NSMutableArray array], *grid = [NSMutableArray array];
    for (id a in appliances) {
        NSString *key = applianceKey(a);
        if ([key isEqual:HIDDEN_APPLIANCE]) continue;
        if ([topRowKeys containsObject:key]) { [top addObject:a]; continue; }
        makeMerchantLike(object_getClass(a));
        [grid addObject:a];
    }
    [gridAppliances release]; gridAppliances = [grid copy];
    ((void (*)(id, SEL, id))origSetAppliances)(self, _cmd, top);
    hookedSetMerchants(self, @selector(setInternetMerchants:), [self performSelector:@selector(internetMerchants)]);
}

// -[ATVMainMenuController _imageForMerchant:]: an appliance's icon is <key with . -> _>@720.png in
// AppleTV.app. It is loaded directly because _imageForAppliance: prefers the image cache, which has
// a FireCore logo for Settings.
static id hookedImageForMerchant(id self, SEL _cmd, id m) {
    if (inGrid(m)) {
        NSString *file = [[applianceKey(m) stringByReplacingOccurrencesOfString:@"." withString:@"_"] stringByAppendingString:@"@720.png"];
        NSString *path = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:file];
        id img = [[NSFileManager defaultManager] fileExistsAtPath:path] ? [objc_getClass("BRImage") imageWithPath:path] : nil;
        return img ? img : [self performSelector:@selector(_imageForAppliance:) withObject:m];
    }
    return ((id (*)(id, SEL, id))origImageForMerchant)(self, _cmd, m);
}

// -[ATVMainMenuController _cacheImageForMerchant:] downloads the merchant's icon URL; appliances have none
static void hookedCacheMerchantImage(id self, SEL _cmd, id m) {
    if (!inGrid(m)) ((void (*)(id, SEL, id))origCacheMerchantImage)(self, _cmd, m);
}

static IMP swap(Class c, SEL sel, IMP imp) {
    Method m = class_getInstanceMethod(c, sel);
    return m ? method_setImplementation(m, imp) : NULL;
}

static void installMenuInMerchantGrid(void) {
    Class mm = objc_getClass("ATVMainMenuController");
    if (!class_getInstanceMethod(mm, @selector(setAppliances:)) || !class_getInstanceMethod(mm, @selector(setInternetMerchants:)) ||
        !class_getInstanceMethod(mm, @selector(_imageForMerchant:)) || !class_getInstanceMethod(mm, @selector(_cacheImageForMerchant:))) {
        NSLog(@"atvlaunch: merchant grid methods missing, items stay in the top row"); return;
    }
    origSetAppliances = swap(mm, @selector(setAppliances:), (IMP)hookedSetAppliances);
    origSetMerchants = swap(mm, @selector(setInternetMerchants:), (IMP)hookedSetMerchants);
    origImageForMerchant = swap(mm, @selector(_imageForMerchant:), (IMP)hookedImageForMerchant);
    origCacheMerchantImage = swap(mm, @selector(_cacheImageForMerchant:), (IMP)hookedCacheMerchantImage);
}

static void installAppAppliances(void) {
    Class base = objc_getClass("BRBaseAppliance");
    Class mgr = objc_getClass("BRApplianceManager"), mm = objc_getClass("ATVMainMenuController");
    Method load = class_getInstanceMethod(mgr, @selector(_loadApplianceAtPath:));
    Method loadInfo = class_getInstanceMethod(mgr, @selector(_loadApplianceWithInfo:));  // iOS 8
    Method push = class_getInstanceMethod(mm, @selector(_pushControllerForApplianceOrMerchant:));
    if (!push) push = class_getInstanceMethod(mm, @selector(_pushControllerForAppliance:));  // iOS 8
    if (!base || !(load || loadInfo) || !push) { NSLog(@"atvlaunch: main menu classes missing, no app items"); return; }
    launchIds = [NSMutableDictionary new];
    topRowKeys = [NSMutableSet new];
    shelfImages = [NSMutableDictionary new];
    appAppliance = objc_allocateClassPair(base, APP_APPLIANCE_CLASS, 0);
    class_addMethod(appAppliance, @selector(topShelfController), (IMP)appTopShelfController, "@@:");
    objc_registerClassPair(appAppliance);
    Protocol *shelfProto = objc_getProtocol("BRTopShelfController");
    if (shelfProto) class_addProtocol([ATVDEVShelf class], shelfProto);
    if (load) origLoadAppliance = method_setImplementation(load, (IMP)hookedLoadAppliance);
    else origLoadApplianceWithInfo = method_setImplementation(loadInfo, (IMP)hookedLoadApplianceWithInfo);
    origPushController = method_setImplementation(push, (IMP)hookedPushController);
    if (load) installMenuInMerchantGrid();  // iOS 6 (ATV2) layout only
}

UIImage *_UICreateScreenUIImage(void);

static void saveScreenshot(void) {
    UIImage *img = _UICreateScreenUIImage();
    [UIImagePNGRepresentation(img) writeToFile:@ATVSHOT_FILE atomically:YES];
    [img release];
}

static IMP origProcess;
static SEL processSel;  // processHIDEvent: (iOS 6) or _processHIDEvent: (iOS 8)
static int sock = -1;
static CFAbsoluteTime menuDownAt;

// ATVHIDSystemClient sees every HID event (the UI gets its navigation through UIKit separately),
// which makes it the place to divert the remote to a running app.
static void hookedProcess(id self, SEL _cmd, IOHIDEventRef e) {
    pid_t pid;
    if (IOHIDEventGetType(e) == kIOHIDEventTypeKeyboard && (pid = atvremote_active_pid())) {
        uint32_t pkt[3] = { IOHIDEventGetIntegerValue(e, kKbdPage), IOHIDEventGetIntegerValue(e, kKbdUsage),
                            IOHIDEventGetIntegerValue(e, kKbdDown) };
        struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(ATVREMOTE_PORT), .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
        sendto(sock, pkt, sizeof pkt, 0, (struct sockaddr *)&a, sizeof a);
        if (atvremote_button(pkt[0], pkt[1]) == ATV_MENU) {
            // a held button repeats "down" events, so only the first one starts the timer
            if (pkt[2] && !menuDownAt) menuDownAt = CFAbsoluteTimeGetCurrent();
            if (menuDownAt && CFAbsoluteTimeGetCurrent() - menuDownAt > MENU_HOLD_KILL) {
                atvremote_close_active(); menuDownAt = 0;
            }
            if (!pkt[2]) menuDownAt = 0;
        }
        return;  // the app owns the remote; don't let the AppleTV UI react underneath it
    }
    ((void (*)(id, SEL, IOHIDEventRef))origProcess)(self, _cmd, e);
}

// iOS 8: post the BREvent the real remote produces (logged from ATVHIDSystemClient), so plugins with their
// own key handling (Kodi) see a normal remote. Its arrows send down and up, everything else only down.
// BRHIDEvent's page/usage mapping gave Kodi other actions and endless presses.
static void postRemoteAction(uint32_t page, uint32_t usage, uint32_t down) {
    enum { MENU = 1, TOP_MENU = 2, UP, DOWN, PLAY_PAUSE_SELECT, LEFT, RIGHT, PLAY_PAUSE = 10 };
    int action = 0;
    if (page == 0x01) switch (usage) {
        case 0x8c: action = UP; break;    case 0x8d: action = DOWN; break;
        case 0x8b: action = LEFT; break;  case 0x8a: action = RIGHT; break;
        case 0x89: action = PLAY_PAUSE_SELECT; break;  case 0x86: action = MENU; break;
    }
    if (page == 0x0c && usage == 0xcd) action = PLAY_PAUSE;
    if (page == 0x0c && usage == 0x223) action = TOP_MENU;  // AC Home: atvpadd sends it for PS, to leave Kodi
    bool arrow = action >= UP && action <= RIGHT && action != PLAY_PAUSE_SELECT;
    if (!action || (!down && !arrow)) return;
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    double now = (double)mach_absolute_time() * tb.numer / tb.denom / 1e9;  // BREvent time is seconds of mach time
    id ev = [objc_getClass("BREvent") eventWithAction:action value:down atTime:now originator:1];
    if (ev) [[UIApplication sharedApplication] postEvent:ev];
}

static void startInjectListener(void) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(ATVREMOTE_INJECT_PORT), .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    if (fd < 0 || bind(fd, (struct sockaddr *)&a, sizeof a) < 0) { NSLog(@"atvlaunch: inject bind failed"); return; }
    fcntl(fd, F_SETFL, O_NONBLOCK);
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(src, ^{
        uint32_t p[3];
        while (recv(fd, p, sizeof p, 0) == sizeof p) {
            if (processSel == @selector(_processHIDEvent:)) { postRemoteAction(p[0], p[1], p[2]); continue; }  // iOS 8
            // arrows auto-repeat until their release arrives; select/menu/play treat a release as another press
            bool arrow = p[0] == 0x01 && p[1] >= 0x8a && p[1] <= 0x8d;
            if (!p[2] && !arrow) continue;
            id ev = [objc_getClass("BRHIDEvent") eventWithPage:p[0] usage:p[1] value:p[2]];
            if (ev) [[UIApplication sharedApplication] postEvent:ev];
        }
    });
    dispatch_resume(src);
}

// Controllers and the remote page talk to our apps directly, so nothing sees input while one is open, and
// the screensaver started the moment the app closed. Two idle timers must be reset (tested: either alone
// still let it start): backboardd's user-event timer and AppleTV's screensaver countdown.
static void holdScreenSaverWhileAppOpen(void) {
    void (*resetUserEventTimer)(void) = dlsym(RTLD_DEFAULT, "BKSHIDServicesResetUserEventTimer");
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 0), 30 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(t, ^{
        if (!atvremote_active_pid()) return;
        if (resetUserEventTimer) resetUserEventTimer();
        id ss = [objc_getClass("ATVScreenSaverManager") performSelector:@selector(singleton)];
        if ([ss respondsToSelector:@selector(_updateActivity:)]) [ss performSelector:@selector(_updateActivity:) withObject:nil];
    });
    dispatch_resume(t);
}

__attribute__((constructor)) static void init(void) {
    sock = socket(AF_INET, SOCK_DGRAM, 0);
    processSel = @selector(processHIDEvent:);
    Method m = class_getInstanceMethod(objc_getClass("ATVHIDSystemClient"), processSel);
    if (!m) m = class_getInstanceMethod(objc_getClass("ATVHIDSystemClient"), processSel = @selector(_processHIDEvent:));  // iOS 8
    if (m) origProcess = method_setImplementation(m, (IMP)hookedProcess);
    startInjectListener();
    holdScreenSaverWhileAppOpen();
    installAppAppliances();
    int shotToken;
    notify_register_dispatch(ATVSHOT_NOTIFICATION, &shotToken, dispatch_get_main_queue(), ^(int t) { saveScreenshot(); });

    int token;
    notify_register_dispatch(ATVLAUNCH_NOTIFICATION, &token, dispatch_get_main_queue(), ^(int t) {
        NSString *ident = [[NSString stringWithContentsOfFile:@ATVLAUNCH_FILE encoding:NSUTF8StringEncoding error:NULL]
                           stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSLog(@"atvlaunch: activating %@", ident);
        if (ident.length) launchApp(ident);
    });
    NSLog(@"atvlaunch: loaded, hid hook %s", m ? "ok" : "MISSING");
}
