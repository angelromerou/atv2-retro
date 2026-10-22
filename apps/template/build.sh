#!/bin/bash
# Run inside WSL: bash apps/template/build.sh
set -e
cd "$(dirname "$0")"
../../toolchain/atv-cc -O2 main.m -framework UIKit -framework Foundation -framework CoreGraphics -o Hello.app/Hello
echo built Hello.app
