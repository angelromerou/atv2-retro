#!/bin/bash
# Builds the Retro frontend binary (shared by all console apps). Run inside WSL: bash apps/retro/build.sh
# tools/build-consoles.sh then packs it with a core into each apps/consoles/<Console>.app.
set -e
cd "$(dirname "$0")"
mkdir -p build
../../toolchain/atv-cc -O2 main.m -framework UIKit -framework Foundation -framework OpenGLES \
  -framework AudioToolbox -framework QuartzCore -framework CoreGraphics -o build/Retro
echo built Retro
