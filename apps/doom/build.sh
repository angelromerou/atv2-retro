#!/bin/bash
# Builds Doom.app for the Apple TV 2. Run inside WSL: bash apps/doom/build.sh
set -e
cd "$(dirname "$0")"
DG=$HOME/atv/doomgeneric/doomgeneric
[ -d "$DG" ] || git clone -q --depth 1 https://github.com/ozkl/doomgeneric.git "$HOME/atv/doomgeneric"
SRC=$(sed -n 's/^SRC_DOOM = //p' "$DG/Makefile" | sed 's/\.o/.c/g; s/doomgeneric_xlib\.c//')
mkdir -p obj
OBJS=""
for f in $SRC; do
  o=obj/${f%.c}.o; OBJS="$OBJS $o"
  [ "$o" -nt "$DG/$f" ] || ../../toolchain/atv-cc -O2 -w -DDOOMGENERIC_RESX=320 -DDOOMGENERIC_RESY=200 -c "$DG/$f" -o "$o" &
done
wait
../../toolchain/atv-cc -O2 -DDOOMGENERIC_RESX=320 -DDOOMGENERIC_RESY=200 -I"$DG" doomgeneric_atv.m $OBJS \
  -framework UIKit -framework Foundation -framework QuartzCore -framework CoreGraphics -o Doom.app/Doom
echo built Doom.app
