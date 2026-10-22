// Usage: atvopen <bundle-id>    asks AppleTV.app (via the ATVLaunch tweak) to launch an app
//        atvopen --screenshot   saves what's on the TV to ATVSHOT_FILE and prints the path
//        atvopen --press <up|down|left|right|select|menu|play>   presses a remote button (in the open app, or on the home screen)
#include <arpa/inet.h>
#include "../sdk/atvremote.h"

int main(int argc, char **argv) {
    if (argc == 3 && !strcmp(argv[1], "--press")) {
        if (atvremote_press(argv[2]) == 0) return 0;
        fprintf(stderr, "atvopen: unknown button %s\n", argv[2]);
        return 1;
    }
    if (argc != 2) { fprintf(stderr, "usage: atvopen <bundle-id> | --screenshot | --press <button>\n"); return 1; }
    if (!strcmp(argv[1], "--screenshot")) {
        if (atvremote_screenshot() != 0) { fprintf(stderr, "atvopen: no screenshot (is the ATVLaunch tweak loaded?)\n"); return 1; }
        puts(ATVSHOT_FILE);
        return 0;
    }
    if (atvremote_launch(argv[1]) != 0) { perror("atvopen"); return 1; }
    return 0;
}
