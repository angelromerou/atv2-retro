#!/bin/bash
# Run inside WSL: bash apps/controllers/build.sh
set -e
cd "$(dirname "$0")"
../../toolchain/atv-cc -O2 main.m -framework UIKit -framework Foundation -framework QuartzCore -framework CoreGraphics -o Controllers.app/Controllers
echo built Controllers.app
