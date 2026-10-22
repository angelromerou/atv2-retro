#!/bin/bash
# Copies ROMs to the Apple TV so they show up in their console app (or use the web page at http://<apple tv>/).
# Usage (Git Bash): tools/add-roms.sh <system> <rom files...>
#   systems: nes snes gb gba md   (gb also takes .gbc; md = Genesis / Mega Drive)
set -e
SYSTEMS="nes snes gb gba md"
SYS=$1; shift || true
[[ " $SYSTEMS " == *" $SYS "* ]] && [ $# -gt 0 ] || { echo "usage: $0 <$(echo $SYSTEMS | tr ' ' '|')> <rom files...>" >&2; exit 1; }
HOST=${ATV_HOST:-192.168.0.101}; PASS=${ATV_PASS:-alpine}
DIR=/var/mobile/Media/ROMs/$SYS
plink -batch -ssh -pw "$PASS" root@$HOST "mkdir -p $DIR"
pscp -batch -q -pw "$PASS" -scp "$@" root@$HOST:$DIR/
plink -batch -ssh -pw "$PASS" root@$HOST "chown -R mobile:mobile /var/mobile/Media/ROMs; ls $DIR | wc -l | sed 's/^ */$SYS: /;s/\$/ ROMs/'"
