# atv2-retro

Turns a jailbroken Apple TV 2 into a retro game console.

Target: a jailbroken Apple TV 2 (iOS 6.1.4 / ATV 5.3, Seas0nPass), reached at `root@192.168.0.101` with password `alpine`. **Apple TV 2 only.** The Apple TV 3 has no easy jailbreak, and the Bluetooth daemon and menu tweak are written for the ATV2's chip and software.

**Change that password first.** Every jailbroken Apple TV ships with `alpine`, so anyone on your network can log in as root. Run `ssh root@<apple tv>`, then `passwd`. The scripts in `tools/` read the address and password from `ATV_HOST` and `ATV_PASS` (e.g. `export ATV_HOST=192.168.1.50 ATV_PASS=yournewpassword`).

## What's on it

**Home-screen apps**
- Doom.
- NES, SNES, Game Boy (also plays Game Boy Color), GBA and Genesis. Each one opens a grid of its games.
- Controllers, for pairing Bluetooth pads.

**Controls**
- The Apple remote, Bluetooth controllers (up to 4 players), and the PC keyboard via `python tools/atvkeys.py`. The DualSense is tested. The DualShock 4 and other classic-Bluetooth pads should work but are **untested**.
- For testing without being in front of the TV: **http://192.168.0.101/remote** shows a screenshot of the TV with remote buttons (d-pad, OK, Menu, Play/Pause, Close app) and also takes arrow keys/Enter/Esc. It works in apps and on the home screen. It's for the home network only, since it has no password.
- PS steps back one level: game → that console's game list → home screen. Apps that don't handle PS themselves (Doom) close straight to the home screen.
- Holding Menu on the remote for 1.5 s always closes the current app.
- The screensaver's default photos are replaced with the console logos (made by `tools/make-menu.py`, installed by `tools/install-system.sh`).
- On the Apple TV home screen a controller works like the remote: d-pad/left stick to move, Cross to select, Circle to go back, Options for play/pause.

## Adding games

Open **http://192.168.0.101** in a browser on any phone or computer on the same network, then drop ROM files onto the page or tap **Choose files**. (Each console's game list on the TV shows this address in its top-right corner.)

- The console is picked from the file type. For an ambiguous file, pick the console on the page first.
- Zipped ROMs are unpacked for you.
- The page lists the games already on the Apple TV, each with a **Delete** button. Deleting keeps the game's battery save. Reopen a console on the TV to see changes.
- From Git Bash you can also run `tools/add-roms.sh snes "Some Game (USA).sfc"` (consoles: nes snes gb gba md).

- ROMs live in `/var/mobile/Media/ROMs/<console>/`.
- Tags like `(USA)` and `[!]` are hidden from game titles.
- Battery saves go to `/var/mobile/Documents/retro/saves/<console>/`. They are written within about 2 s of changing, so closing with PS is safe.
- In-game controls use the SNES button layout by position: Cross = B, Circle = A, Square = Y, Triangle = X, plus L1/R1/L2/R2, Create = Select and Options = Start.

## Pairing a controller

1. Open **Controllers**.
2. Put the pad in pairing mode: DualSense = hold Create + PS, DualShock 4 (untested) = hold Share + PS, until the light blinks fast.
3. Select **Pair new controller**.

Paired pads reconnect when you press PS. Xbox Series and current Xbox One pads can't work, because the ATV2's BCM4329 radio has no Bluetooth Low Energy.

## How it works

| Piece | What it does |
|---|---|
| `atvlaunch/` (MobileSubstrate tweak in AppleTV.app) | Launches apps (`atvopen <bundle-id>`), forwards the remote to the running app over UDP 37777, replays controller input on the home screen (UDP 37778, posted as `BRHIDEvent`s), puts the consoles in the stock top row (each with its logo on the top shelf, from `downloads/logos/`) and Controllers, Doom and Settings in the grid below (Computers hidden), takes screenshots (`atvopen --screenshot`), and holds off the screensaver countdown while an app is open |
| `atvpad/atvpadd` (launchd daemon) | Replaces Apple's BTServer: powers the chip with BlueTool at 921600 baud and runs [BTstack](https://github.com/bluekitchen/btstack) as a Classic HID host over the kernel's netgraph UART socket. A reader thread frames and sanity-checks H4 packets, because the UART drops bytes now and then. Pairings are kept in `/var/mobile/Library/atvpad/`, the log is `/tmp/atvpadd.log`, and `atvpadd -d` writes an HCI trace to `/tmp/atvpadd.pklg` |
| `atvroms/atvromsd` (launchd daemon) | The add-games web page on port 80, plus the test remote at `/remote` (`remote.html`): serves `index.html`, saves uploads into the ROM folders (unzipping `.zip` files), and reads the console list from the console apps' Info.plists. It runs as `mobile` once port 80 is open and only accepts POSTs from its own pages (`X-ATV` header). The log is `/tmp/atvromsd.log` |
| `apps/retro/` | The libretro frontend that every console app runs: ROM grid, OpenGL ES video, AudioQueue sound, input |
| `sdk/atvremote.h` | The input protocol and helpers shared by every app and daemon |

## Building and deploying

Builds run in WSL Ubuntu and deploys run in Git Bash. Run `toolchain/setup.sh` once first.

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
tools/screenshot.sh shot.png                     # see the TV from the PC (or open http://192.168.0.101/remote)
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

On the Apple TV (`ssh root@192.168.0.101`):

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
