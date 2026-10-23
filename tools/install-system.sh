#!/bin/bash
# Installs/updates the system pieces on the Apple TV: ATVLaunch tweak, atvopen, atvpadd and atvromsd (+ launchd jobs),
# and the console-logo screensaver photos (build/screensaver, from tools/make-menu.py).
# On an ATV3 it keeps Apple's screensaver photos.
# Restarts the AppleTV UI and the controller service. Usage (Git Bash, WSL or Linux): tools/install-system.sh
set -e
cd "$(dirname "$0")/.."
. tools/atv-ssh.sh
atv_scp atvlaunch/ATVLaunch.dylib atvlaunch/ATVLaunch.plist atvlaunch/atvopen \
  atvpad/atvpadd atvpad/com.atvdev.atvpadd.plist atvroms/atvromsd atvroms/com.atvdev.atvromsd.plist   atvroms/index.html atvroms/remote.html root@$HOST:/tmp/
atv_scp -r build/screensaver root@$HOST:/tmp/
atv_ssh '
  cd /tmp
  case $(uname -m) in AppleTV2*) atv2=1 ;; *) atv2= ; rm -rf screensaver ;; esac
  ! command -v ldid >/dev/null || ldid -S ATVLaunch.dylib atvopen atvpadd atvromsd  # iOS 8 (ATV3) kills unsigned code
  mv ATVLaunch.dylib ATVLaunch.plist /Library/MobileSubstrate/DynamicLibraries/
  mv atvopen /usr/bin/ && chmod 755 /usr/bin/atvopen
  launchctl unload /Library/LaunchDaemons/com.atvdev.atvpadd.plist 2>/dev/null; killall atvpadd 2>/dev/null; sleep 2
  mv atvpadd /usr/bin/ && chmod 755 /usr/bin/atvpadd
  mv com.atvdev.atvpadd.plist /Library/LaunchDaemons/ && chown root:wheel /Library/LaunchDaemons/com.atvdev.atvpadd.plist
  atvpadd selftest
  launchctl unload /Library/LaunchDaemons/com.atvdev.atvromsd.plist 2>/dev/null
  mv atvromsd /usr/bin/ && chmod 755 /usr/bin/atvromsd
  chown -R mobile:mobile /var/mobile/Media/ROMs 2>/dev/null  # older installs ran the selftest as root, leaving it root-owned
  su mobile -c "atvromsd selftest"  # as root it would create the ROM folder that the mobile-run daemon must write to
  mkdir -p /usr/share/atvroms && mv index.html remote.html /usr/share/atvroms/
  mv com.atvdev.atvromsd.plist /Library/LaunchDaemons/ && chown root:wheel /Library/LaunchDaemons/com.atvdev.atvromsd.plist
  launchctl load /Library/LaunchDaemons/com.atvdev.atvromsd.plist
  if [ $atv2 ]; then
    P=/Applications/AppleTV.app/DefaultNaturePhotos B=/var/mobile/Library/atvdev/DefaultNaturePhotos.orig
    [ -d $B ] || { mkdir -p ${B%/*} && cp -a $P $B; }  # keep Apple'"'"'s photos once, for uninstall
    rm -f $P/* && mv screensaver/*.jpg $P/ && rm -rf screensaver
  fi
  killall AppleTV
  launchctl load /Library/LaunchDaemons/com.atvdev.atvpadd.plist
  echo installed'
