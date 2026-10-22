#!/bin/bash
# Builds the console apps (apps/consoles/<Console>.app): the Retro frontend binary plus that console's
# libretro core as core.dylib. Info.plists and menu icons come from tools/make-menu.py (run that first).
# Run inside WSL: bash tools/build-consoles.sh      (cores: bash tools/build-cores.sh)
set -e
cd "$(dirname "$0")/.."
bash apps/retro/build.sh
for app in apps/consoles/*.app; do
    core=$(python3 -c "import plistlib,sys; print(plistlib.load(open(sys.argv[1],'rb'))['RetroCore'])" "$app/Info.plist")
    [ -f "build/cores/$core.dylib" ] || { echo "missing core $core (run tools/build-cores.sh)"; exit 1; }
    cp apps/retro/build/Retro "$app/Retro"
    cp "build/cores/$core.dylib" "$app/core.dylib"
    echo "$(basename "$app"): $core"
done
