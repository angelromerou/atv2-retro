#!/bin/bash
# Installs/updates the system pieces on the Apple TV: ATVLaunch tweak, atvopen, atvpadd and atvromsd (+ launchd jobs),
# and the console-logo screensaver photos (build/screensaver, from tools/make-menu.py).
# Restarts the AppleTV UI and the controller service. Usage (Git Bash): tools/install-system.sh
set -e
HOST=${ATV_HOST:-192.168.0.101}; PASS=${ATV_PASS:-alpine}
cd "$(dirname "$0")/.."
pscp -batch -q -pw "$PASS" -scp atvlaunch/ATVLaunch.dylib atvlaunch/ATVLaunch.plist atvlaunch/atvopen \
  atvpad/atvpadd atvpad/com.atvdev.atvpadd.plist atvroms/atvromsd atvroms/com.atvdev.atvromsd.plist   atvroms/index.html atvroms/remote.html root@$HOST:/tmp/
pscp -batch -q -pw "$PASS" -scp -r build/screensaver root@$HOST:/tmp/
plink -batch -ssh -pw "$PASS" root@$HOST '
  cd /tmp
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
  P=/Applications/AppleTV.app/DefaultNaturePhotos B=/var/mobile/Library/atvdev/DefaultNaturePhotos.orig
  [ -d $B ] || { mkdir -p ${B%/*} && cp -a $P $B; }  # keep Apple'"'"'s photos once, for uninstall
  rm -f $P/* && mv screensaver/*.jpg $P/ && rm -rf screensaver
  killall AppleTV
  launchctl load /Library/LaunchDaemons/com.atvdev.atvpadd.plist
  echo installed'
