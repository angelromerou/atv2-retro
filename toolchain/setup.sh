#!/bin/bash
# One-time setup of the Apple TV 2 (armv7, iOS 6.1) cross toolchain in WSL Ubuntu or Ubuntu/Debian Linux.
# Run inside WSL or Linux: bash toolchain/setup.sh   (asks for sudo once for apt packages)
# Produces: ~/atv/toolchain (ld64/cctools), ~/atv/sdks/iPhoneOS6.1.sdk. Compile with toolchain/atv-cc.
set -e
sudo apt-get install -y clang lld llvm cmake autoconf automake libtool libxml2-dev libbsd-dev libblocksruntime-dev \
  sshpass python3-pil fonts-dejavu-core  # deploys from WSL/Linux (tools/atv-ssh.sh), tools/make-menu.py
mkdir -p ~/atv && cd ~/atv
D=$HOME/atv/deps

# libdispatch (needed by ld64, not packaged by Ubuntu)
[ -d swift-corelibs-libdispatch ] || git clone -q --depth 1 https://github.com/swiftlang/swift-corelibs-libdispatch.git
cmake -S swift-corelibs-libdispatch -B swift-corelibs-libdispatch/build -DCMAKE_C_COMPILER=clang \
  -DCMAKE_CXX_COMPILER=clang++ -DCMAKE_INSTALL_PREFIX=$D -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build swift-corelibs-libdispatch/build -j$(nproc) >/dev/null && cmake --install swift-corelibs-libdispatch/build >/dev/null

# ld64 + cctools
[ -d cctools-port ] || git clone -q --depth 1 https://github.com/tpoechtrager/cctools-port.git
cd cctools-port/cctools
./configure --prefix=$HOME/atv/toolchain --target=arm-apple-darwin11 CC=clang CXX=clang++ \
  CFLAGS="-I$D/include" CXXFLAGS="-I$D/include" LDFLAGS="-L$D/lib -Wl,-rpath,$D/lib" >/dev/null
make -j$(nproc) >/dev/null && make install >/dev/null
cd ~/atv

# iPhoneOS 6.1 SDK (only that folder of a large repo)
if [ ! -d sdks/iPhoneOS6.1.sdk ]; then
  git clone -q --depth 1 --filter=blob:none --sparse https://github.com/dilbrent/iOS_SDKs.git sdks
  git -C sdks sparse-checkout set iPhoneOS6.1.sdk
fi
echo "toolchain ready"
