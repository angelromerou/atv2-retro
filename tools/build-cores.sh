#!/bin/bash
# Builds the libretro emulator cores for the Apple TV 2 into build/cores/ (packed by build-consoles.sh).
# Run inside WSL: bash tools/build-cores.sh [core ...]   (default: all)
# Sources are cloned into ~/atv/cores; each core's own Makefile is used with platform=ios and our compilers.
cd "$(dirname "$0")/.."
OUT=$PWD/build/cores
TC=$PWD/toolchain
mkdir -p "$OUT" ~/atv/cores

#    name       repo                         makefile             extra compiler flags (appended last, so they beat the makefile's)
# snes9x2010: ARM mode + -O3 is ~35% faster than the default Thumb -O2, measured on the ATV2 (it can't hold 60 fps without it)
CORES="fceumm     libretro-fceumm              Makefile.libretro    -
snes9x2010 snes9x2010                   Makefile             -O3 -marm -mcpu=cortex-a8
gambatte   gambatte-libretro            Makefile             -
gpsp       gpsp                         Makefile             -
picodrive  picodrive                    Makefile.libretro    -"

build() {  # name repo makefile cflags
    local name=$1 repo=$2 mk=$3 cflags=$4; [ "$cflags" = - ] && cflags=
    local dir=~/atv/cores/$repo
    [ -d "$dir" ] || git clone -q --depth 1 --recurse-submodules --shallow-submodules https://github.com/libretro/$repo.git "$dir" || return 1
    # clean first: objects left from a build with other flags wouldn't be rebuilt
    (cd "$dir" && make -f $mk platform=ios clean >/dev/null 2>&1; ATV_CFLAGS="$cflags" make -f $mk platform=ios IOSSDK=/unused \
        CC="$TC/atv-cc" CXX="$TC/atv-c++" LD="$TC/atv-c++" AR=llvm-ar -j$(nproc) > /tmp/core-$name.log 2>&1) || { echo "$name: build failed, see /tmp/core-$name.log"; grep -m5 -E "error" /tmp/core-$name.log; return 1; }
    local lib=$(ls -t "$dir"/*_libretro_ios.dylib 2>/dev/null | head -1)
    [ -n "$lib" ] || { echo "$name: no dylib produced"; return 1; }
    cp "$lib" "$OUT/$name.dylib" && echo "$name: ok ($(du -h "$OUT/$name.dylib" | cut -f1))"
}

echo "$CORES" | while read -r name repo mk cflags; do
    [ $# -eq 0 ] || [[ " $* " == *" $name "* ]] || continue
    build "$name" "$repo" "$mk" "$cflags"
done
