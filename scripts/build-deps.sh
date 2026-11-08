#!/bin/bash
# Builds libusb and libmtp as static libraries for macOS 14+ (arm64 + x86_64)
# into build/deps, so the app doesn't depend on Homebrew on the user's Mac.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
PREFIX=$ROOT/build/deps
SRC=$ROOT/build/deps-src
MIN=14.0

if [[ -f $PREFIX/lib/libmtp.a && -f $PREFIX/lib/libusb-1.0.a && "${1:-}" != "--force" ]]; then
  echo "deps: already built ($PREFIX)"; exit 0
fi

brew fetch --build-from-source libusb libmtp >/dev/null
USB_TGZ=$(brew --cache --build-from-source libusb)
MTP_TGZ=$(brew --cache --build-from-source libmtp)

rm -rf "$SRC" "$PREFIX"; mkdir -p "$SRC" "$PREFIX"
export MACOSX_DEPLOYMENT_TARGET=$MIN
export CFLAGS="-arch arm64 -arch x86_64 -mmacosx-version-min=$MIN -O2"
export LDFLAGS="-arch arm64 -arch x86_64 -mmacosx-version-min=$MIN"
export PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig
JOBS=$(sysctl -n hw.ncpu)

echo "deps: libusb"
tar -xf "$USB_TGZ" -C "$SRC"
(cd "$SRC"/libusb-*/ && ./configure --prefix="$PREFIX" --disable-shared --enable-static --disable-dependency-tracking >/dev/null \
  && make -j"$JOBS" >/dev/null && make install >/dev/null)

echo "deps: libmtp"
tar -xf "$MTP_TGZ" -C "$SRC"
(cd "$SRC"/libmtp-*/ && ./configure --prefix="$PREFIX" --disable-shared --enable-static --disable-dependency-tracking \
  --disable-mtpz --with-udev=no >/dev/null \
  && make -j"$JOBS" -C src >/dev/null && make -C src install >/dev/null && make install-data-am >/dev/null 2>&1 || true)
test -f "$PREFIX/lib/libmtp.a"
cp "$SRC"/libmtp-*/src/libmtp.h "$PREFIX/include/" 2>/dev/null || true
echo "deps: done"
lipo -info "$PREFIX/lib/libmtp.a" "$PREFIX/lib/libusb-1.0.a"
