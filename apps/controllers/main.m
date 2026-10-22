// Controllers: pair Bluetooth gamepads and see which players are connected.
// Talks to atvpadd through ATVPAD_PAIR_NOTIFICATION and ATVPAD_STATUS_FILE. Select pairs, Menu exits.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include "../../sdk/atvremote.h"

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


// ---- controllers screen ----

@interface ControllersView : UIView
@property (nonatomic, retain) UILabel *status, *result, *button;
@property (nonatomic, retain) NSArray *players;
- (void)refresh;
@end

@implementation ControllersView
- (id)initWithFrame:(CGRect)f {
    if (!(self = [super initWithFrame:f])) return nil;
    self.backgroundColor = [rgb(0x0b0d12) colorWithAlphaComponent:0.97];
    CGFloat x = 120, w = f.size.width - 240;
    UILabel *title = label(CGRectMake(x, 60, w, 60), 44, YES, [UIColor whiteColor]);
    title.text = @"Controllers";
    [self addSubview:title];

    NSMutableArray *players = [NSMutableArray array];
    for (int i = 0; i < ATVPAD_MAX_PLAYERS; i++) {
        UILabel *p = label(CGRectMake(x, 150 + i * 46, w, 40), 26, NO, rgb(0xc8ccd6));
        [self addSubview:p];
        [players addObject:p];
    }
    self.players = players;

    UILabel *help = label(CGRectMake(x, 350, w, 150), 22, NO, rgb(0x9aa0ad));
    help.numberOfLines = 0;
    help.text = @"1. Put the controller in pairing mode:\n"
                 "     DualSense: hold Create + PS until the light blinks fast\n"
                 "     DualShock 4 (untested): hold Share + PS until the light double-blinks\n"
                 "2. Then select Pair new controller. Paired controllers reconnect with the PS button.";
    [self addSubview:help];

    self.button = label(CGRectMake(x, 520, 420, 70), 28, YES, [UIColor blackColor]);
    self.button.textAlignment = NSTextAlignmentCenter;
    self.button.backgroundColor = [UIColor whiteColor];
    self.button.layer.cornerRadius = 12;
    self.button.text = @"Pair new controller";
    [self addSubview:self.button];

    self.status = label(CGRectMake(x + 450, 520, w - 450, 36), 24, YES, rgb(0xffd166));
    self.result = label(CGRectMake(x + 450, 556, w - 450, 36), 22, NO, rgb(0xc8ccd6));
    [self addSubview:self.status];
    [self addSubview:self.result];

    UILabel *hint = label(CGRectMake(x, f.size.height - 80, w, 30), 20, NO, rgb(0x6b7280));
    hint.text = @"Select / Cross: pair     Menu / Circle: back to the home screen";
    [self addSubview:hint];
    [self refresh];
    return self;
}
- (void)dealloc { [_status release]; [_result release]; [_button release]; [_players release]; [super dealloc]; }

// Reads ATVPAD_STATUS_FILE (written by atvpadd).
- (void)refresh {
    NSString *s = [NSString stringWithContentsOfFile:@ATVPAD_STATUS_FILE encoding:NSUTF8StringEncoding error:NULL];
    BOOL pairing = NO;
    NSString *result = @"";
    for (int i = 0; i < ATVPAD_MAX_PLAYERS; i++) [[self.players objectAtIndex:i] setText:[NSString stringWithFormat:@"Player %d:  not connected", i + 1]];
    for (NSString *line in [s componentsSeparatedByString:@"\n"]) {
        NSArray *f = [line componentsSeparatedByString:@" "];
        NSString *key = f.count ? [f objectAtIndex:0] : @"";
        if ([key isEqualToString:@"pairing"]) pairing = [[f lastObject] intValue] != 0;
        else if ([key isEqualToString:@"result"]) result = [line length] > 7 ? [line substringFromIndex:7] : @"";
        else if ([key hasPrefix:@"player"] && f.count >= 3) {
            int n = [[key substringFromIndex:6] intValue];
            if (n >= 1 && n <= ATVPAD_MAX_PLAYERS)
                [[self.players objectAtIndex:n - 1] setText:[NSString stringWithFormat:@"Player %d:  %@ controller  (%@)", n,
                                                             [f objectAtIndex:2], [f objectAtIndex:1]]];
        }
    }
    if (!s) result = @"Controller service is not running";
    self.status.text = pairing ? @"Searching for controllers..." : @"";
    self.result.text = pairing ? @"" : result;
    self.button.alpha = pairing ? 0.4 : 1;
}

- (void)pair { notify_post(ATVPAD_PAIR_NOTIFICATION); }
@end


@interface ControllersVC : UIViewController
@end
@implementation ControllersVC {
    ControllersView *screen;
    int remote;
}
- (void)loadView {
    screen = [[ControllersView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.view = screen;
}
- (void)viewDidLoad {
    remote = atvremote_open();
    [NSTimer scheduledTimerWithTimeInterval:1 / 30.0 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [NSTimer scheduledTimerWithTimeInterval:0.5 target:screen selector:@selector(refresh) userInfo:nil repeats:YES];
}
- (void)tick {
    int button, down; uint32_t page, usage;
    while (atvremote_poll(remote, &button, &down, &page, &usage)) {
        if (!down) continue;
        if (button == ATV_SELECT || button == ATV_PLAYPAUSE) [screen pair];
        if (button == ATV_MENU) exit(0);  // back to the AppleTV home screen
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
    self.window.rootViewController = [[ControllersVC new] autorelease];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, @"AD"); }
}
