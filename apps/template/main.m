// Starter Apple TV 2 app: shows which remote button you pressed.
// Build: wsl -d Ubuntu -- bash apps/template/build.sh   Deploy: tools/deploy.sh apps/template/Hello.app
#import <UIKit/UIKit.h>
#include "../../sdk/atvremote.h"

static const char *names[] = { "?", "Up", "Down", "Left", "Right", "Select", "Menu", "Play/Pause" };
static const char *padNames[] = { "?", "Up", "Down", "Left", "Right", "Cross / A", "Circle / B", "Square / X",
    "Triangle / Y", "L1", "R1", "L2", "R2", "Create / Select", "Options / Start", "L3", "R3", "PS / Home",
    "Right stick up", "Right stick down", "Right stick left", "Right stick right" };

@interface AD : UIResponder <UIApplicationDelegate>
@property (nonatomic, retain) UIWindow *window;
@property (nonatomic, retain) UILabel *label;
@end
@implementation AD { int remote; }
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.window = [[[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds] autorelease];
    self.window.rootViewController = [[UIViewController new] autorelease];
    UIView *v = self.window.rootViewController.view;
    v.backgroundColor = [UIColor darkGrayColor];
    self.label = [[[UILabel alloc] initWithFrame:v.bounds] autorelease];
    self.label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.label.textAlignment = NSTextAlignmentCenter;
    self.label.font = [UIFont boldSystemFontOfSize:60];
    self.label.textColor = [UIColor whiteColor];
    self.label.backgroundColor = [UIColor clearColor];
    self.label.text = @"Press a button (hold Menu to exit)";
    [v addSubview:self.label];
    [self.window makeKeyAndVisible];

    remote = atvremote_open();
    [NSTimer scheduledTimerWithTimeInterval:1 / 60.0 target:self selector:@selector(poll) userInfo:nil repeats:YES];
    return YES;
}
- (void)poll {
    int button, down; uint32_t page, usage;
    while (atvremote_poll(remote, &button, &down, &page, &usage))
        if (!down) continue;
        else if (atvpad_player(page) >= 0 && usage < ATVPAD_COUNT)
            self.label.text = [NSString stringWithFormat:@"Player %d: %s", atvpad_player(page) + 1, padNames[usage]];
        else self.label.text = [NSString stringWithFormat:@"%s  (page 0x%x usage 0x%x)", names[button], page, usage];
}
@end

int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, @"AD"); }
}
