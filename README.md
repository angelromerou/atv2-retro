# atv2-retro

Turns a jailbroken Apple TV 2 into a retro game console. The Apple TV 3 is partly supported (see [Apple TV 3](#apple-tv-3)).

Target: a jailbroken Apple TV 2 (iOS 6.1.4 / ATV 5.3, Seas0nPass), reached over SSH as `root`. The rest of this README describes the ATV2.

In this README, `<atv-ip>` means your Apple TV's address. Find it on the TV under **Settings → General → Network** (e.g. `192.168.1.50`). Giving the Apple TV a fixed address in your router's DHCP settings keeps the links below from changing.

**Change that password first.** Every jailbroken Apple TV ships with `alpine`, so anyone on your network can log in as root. Run `ssh root@<atv-ip>`, then `passwd`. The scripts in `tools/` read the address and password from `ATV_HOST` and `ATV_PASS` (e.g. `export ATV_HOST=192.168.1.50 ATV_PASS=yournewpassword`). Without them they use `192.168.0.101` and `alpine`.

## What's on it

**Home-screen apps**
- Doom.
- NES, SNES, Game Boy (also plays Game Boy Color), GBA and Genesis. Each one opens a grid of its games.
- Controllers, for pairing Bluetooth pads.

**Controls**
- The Apple remote, Bluetooth controllers (up to 4 players), and the PC keyboard via `python tools/atvkeys.py`. The DualSense is tested. The DualShock 4 and other classic-Bluetooth pads should work but are **untested**.
- For testing without being in front of the TV: `http://<atv-ip>/remote` shows a screenshot of the TV with remote buttons (d-pad, OK, Menu, Play/Pause, Close app) and also takes arrow keys/Enter/Esc. It works in apps and on the home screen. It's for the home network only, since it has no password.
- PS steps back one level: game → that console's game list → home screen. Apps that don't handle PS themselves (Doom) close straight to the home screen.
- Holding Menu on the remote for 1.5 s always closes the current app.
- The screensaver's default photos are replaced with the console logos (made by `tools/make-menu.py`, installed by `tools/install-system.sh`).
- On the Apple TV home screen a controller works like the remote: d-pad/left stick to move, Cross to select, Circle to go back, Options for play/pause.

## Adding games

Open `http://<atv-ip>` in a browser on any phone or computer on the same network, then drop ROM files onto the page or tap **Choose files**. (Each console's game list on the TV shows this address in its top-right corner.)

- The console is picked from the file type. For an ambiguous file, pick the console on the page first.
- Zipped ROMs are unpacked for you.
- The page lists the games already on the Apple TV, each with a **Delete** button. Deleting keeps the game's battery save. Reopen a console on the TV to see changes.
- From Git Bash, WSL or Linux you can also run `tools/add-roms.sh snes "Some Game (USA).sfc"` (consoles: nes snes gb gba md).

- ROMs live in `/var/mobile/Media/ROMs/<console>/`.
- Tags like `(USA)` and `[!]` are hidden from game titles.
- Battery saves go to `/var/mobile/Documents/retro/saves/<console>/`. They are written within about 2 s of changing, so closing with PS is safe.
- In-game controls use the SNES button layout by position: Cross = B, Circle = A, Square = Y, Triangle = X, plus L1/R1/L2/R2, Create = Select and Options = Start.

## Pairing a controller

1. Open **Controllers**.
2. Put the pad in pairing mode: DualSense = hold Create + PS, DualShock 4 (untested) = hold Share + PS, until the light blinks fast.
3. Select **Pair new controller**.

Paired pads reconnect when you press PS. Xbox Series and current Xbox One pads can't work, because the ATV2's BCM4329 radio has no Bluetooth Low Energy.

## Apple TV 3

Tested on an A1469 (AppleTV3,2) running iOS 8.4.4 (12H1006, the build Apple still signs). The ATV3 keeps its stock home screen: our apps are added as ordinary icons in its grid.

**Jailbreak** with [Blackb0x](https://github.com/NSSpiral/Blackb0x) from a Mac (untethered on 8.4.x). The A1427 (AppleTV3,1) first needs checkm8-A5 run from an Arduino; the A1469 does not. Blackb0x's first-boot script can fail its `apt-get update` (the network isn't up yet) and then silently skips MobileSubstrate and Kodi. If `/Library/Frameworks/CydiaSubstrate.framework` is missing, run on the Apple TV:

```bash
apt-get update
dpkg -i /var/cache/apt/archives/com.saurik.patcyh_1.2.0_iphoneos-arm-fixed.deb
apt-get install -y mobilesubstrate com.saurik.substrate.safemode
apt-get -y --force-yes install org.xbmc.kodi-atv2   # Kodi, optional
reboot
```

Blackb0x's script (`/etc/setup.sh`) runs again at every boot and runs `apt-get upgrade`.

**Differences from the ATV2**
- Arrange or hide any home-screen item, ours included, the stock way: hold Select until it jiggles, move it with the arrows, or press Play/Pause for **Hide This Item**. Hidden items come back under **Settings → Main Menu**.
- Apple's screensaver photos stay.
- Controllers work as on the ATV2 (tested with a DualSense). Its BCM4334 chip has Bluetooth LE, but `atvpadd` is Classic only, so Xbox pads still don't work.
- Screenshots (`atvopen --screenshot`, `/remote`) show the home screen, but come out black while an app is open.
- iOS 8 kills unsigned binaries: `tools/deploy.sh` and `tools/install-system.sh` sign everything with `ldid -S` on the Apple TV.
- Apps need `UIDeviceFamily` with 3 (Apple TV) in their Info.plist, or the home screen refuses to launch them ("App looks unsafe for use on the internet"). The apps here have it, and `tools/make-menu.py` adds it.
- Menu icons are 282x159 `@1080.png` files (the ATV2 uses 188x108 `@720.png`). `tools/make-menu.py` makes both.
- The SSH server needs `-o HostKeyAlgorithms=+ssh-rsa` from a current `ssh` (`tools/atv-ssh.sh` sets it).

## How it works

| Piece | What it does |
|---|---|
| `atvlaunch/` (MobileSubstrate tweak in AppleTV.app) | Launches apps (`atvopen <bundle-id>`), forwards the remote to the running app over UDP 37777, replays controller input on the home screen (UDP 37778, posted as `BRHIDEvent`s), puts the consoles in the stock top row (each with its logo on the top shelf, from `downloads/logos/`) and Controllers, Doom and Settings in the grid below (Computers hidden), takes screenshots (`atvopen --screenshot`), and holds off the screensaver countdown while an app is open |
| `atvpad/atvpadd` (launchd daemon) | Replaces Apple's BTServer: powers the chip with BlueTool at 921600 baud and runs [BTstack](https://github.com/bluekitchen/btstack) as a Classic HID host over the kernel's netgraph UART socket. A reader thread frames and sanity-checks H4 packets, because the UART drops bytes now and then. Pairings are kept in `/var/mobile/Library/atvpad/`, the log is `/tmp/atvpadd.log`, and `atvpadd -d` writes an HCI trace to `/tmp/atvpadd.pklg` |
| `atvroms/atvromsd` (launchd daemon) | The add-games web page on port 80, plus the test remote at `/remote` (`remote.html`): serves `index.html`, saves uploads into the ROM folders (unzipping `.zip` files), and reads the console list from the console apps' Info.plists. It runs as `mobile` once port 80 is open and only accepts POSTs from its own pages (`X-ATV` header). The log is `/tmp/atvromsd.log` |
| `apps/retro/` | The libretro frontend that every console app runs: ROM grid, OpenGL ES video, AudioQueue sound, input |
| `sdk/atvremote.h` | The input protocol and helpers shared by every app and daemon |

## Building and deploying

Builds run in WSL Ubuntu or Ubuntu/Debian Linux. Deploys run in Git Bash (with PuTTY's `plink`/`pscp`), or in WSL/Linux with `ssh`/`scp` and `sshpass`. Run `toolchain/setup.sh` once first. On Linux, drop the `wsl -d Ubuntu --` prefix below.

```bash
wsl -d Ubuntu -- bash tools/build-cores.sh       # libretro cores -> build/cores/
python tools/make-menu.py                        # console Info.plists + home-screen items/icons
wsl -d Ubuntu -- bash tools/build-consoles.sh    # Retro + core -> apps/consoles/<Console>.app
wsl -d Ubuntu -- bash apps/doom/build.sh
wsl -d Ubuntu -- bash apps/controllers/build.sh
wsl -d Ubuntu -- bash atvpad/build.sh            # controller daemon
wsl -d Ubuntu -- bash -c 'cd atvroms && ../toolchain/atv-cc -O2 -Wall -Wno-unused-function atvromsd.c   -framework CoreFoundation -lz -o atvromsd'      # add-games web page
wsl -d Ubuntu -- bash -c 'cd atvlaunch && ../toolchain/atv-cc -O2 -dynamiclib Tweak.m -framework UIKit \
  -framework Foundation -framework IOKit -framework CoreGraphics -o ATVLaunch.dylib && ../toolchain/atv-cc -O2 atvopen.c -o atvopen'

tools/install-system.sh                          # tweak + atvopen + atvpadd + atvromsd
tools/deploy.sh --no-launch apps/doom/Doom.app apps/controllers/Controllers.app apps/consoles/*.app
tools/screenshot.sh shot.png                     # see the TV from the PC (or open http://<atv-ip>/remote)
```

Notes on `deploy.sh`:
- It copies each app's `ATVMenu/` (home-screen entry and icon) into AppleTV.app.
- It restarts the Apple TV menu only when an entry changed.

## Making a new app

1. Copy `apps/template`.
2. Set `CFBundleExecutable` and `CFBundleIdentifier` (`com.atvdev.*`).
3. Read input with `atvremote_open()` / `atvremote_poll()`. Pass `ATVREMOTE_HANDLES_HOME` to `atvremote_open_flags` if the app should handle PS itself.
4. For a home-screen icon, add an entry to `APPS` in `tools/make-menu.py`.

App rules:
- Use manual retain/release.
- Write files under `/var/mobile`.
- Log to `/tmp`.
- The Apple TV's iOS has no GLKit, so use OpenGL ES with `CAEAGLLayer`.

Toolchain notes:
- `toolchain/atv-cc` and `toolchain/atv-c++` wrap clang for `armv7-apple-ios6.0`. C++ is limited to C++98 (libstdc++ 4.2.1).
- `wsl.exe` expands `$VARS` in its arguments, so pass scripts as files or use `bash -s <<'EOF'`.

## Uninstall

On the Apple TV (`ssh root@<atv-ip>`):

```bash
launchctl unload /Library/LaunchDaemons/com.atvdev.atvpadd.plist
launchctl unload /Library/LaunchDaemons/com.atvdev.atvromsd.plist
rm -rf /Library/LaunchDaemons/com.atvdev.atvromsd.plist /usr/bin/atvromsd /usr/share/atvroms
rm /Library/LaunchDaemons/com.atvdev.atvpadd.plist /usr/bin/atvpadd /usr/bin/atvopen
rm -rf /var/mobile/Library/atvpad
launchctl load /System/Library/LaunchDaemons/com.apple.BlueTool.plist
launchctl load /System/Library/LaunchDaemons/com.apple.BTServer.plist
rm /Library/MobileSubstrate/DynamicLibraries/ATVLaunch.*
rm /Applications/AppleTV.app/com.atvdev.* /Applications/AppleTV.app/com_atvdev_*
rm -rf /Applications/AppleTV.app/DefaultNaturePhotos && mv /var/mobile/Library/atvdev/DefaultNaturePhotos.orig /Applications/AppleTV.app/DefaultNaturePhotos
cd /Applications && rm -rf Doom.app Controllers.app NES.app SNES.app GameBoy.app GBA.app Genesis.app Hello.app
su mobile -c uicache
killall AppleTV
```
