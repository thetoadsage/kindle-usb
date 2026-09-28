#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD/.build/vendor"
prefix="$PWD/.build/dependencies"
mkdir -p "$root" "$prefix"
cd "$root"
[[ -f libusb.tar.bz2 ]] || curl -fL https://github.com/libusb/libusb/releases/download/v1.0.30/libusb-1.0.30.tar.bz2 -o libusb.tar.bz2
[[ -f libmtp.tar.gz ]] || curl -fL https://downloads.sourceforge.net/project/libmtp/libmtp/1.1.23/libmtp-1.1.23.tar.gz -o libmtp.tar.gz
printf '%s\n' 'fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf  libusb.tar.bz2' '74a2b6e8cb4a0304e95b995496ea3ac644c29371649b892b856e22f12a0bdeed  libmtp.tar.gz' | shasum -a 256 -c -
tar -xjf libusb.tar.bz2
tar -xzf libmtp.tar.gz
export MACOSX_DEPLOYMENT_TARGET=13.0
# Sandboxed macOS may deny sysctl kern.argmax; use a conservative command limit.
export lt_cv_sys_max_cmd_len=65536
export CFLAGS="-O2 -arch arm64 -mmacosx-version-min=13.0"
export LDFLAGS="-arch arm64 -mmacosx-version-min=13.0"
cd libusb-1.0.30
./configure --prefix="$prefix" --disable-static
make -j4
make install
cd ../libmtp-1.1.23
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"
export LIBUSB_CFLAGS="-I$prefix/include/libusb-1.0"
export LIBUSB_LIBS="-L$prefix/lib -lusb-1.0"
./configure --prefix="$prefix" --disable-static --disable-mtpz
make -j4
make install
mkdir -p "$prefix/licenses"
cp COPYING "$prefix/licenses/libmtp-COPYING"
cp ../libusb-1.0.30/COPYING "$prefix/licenses/libusb-COPYING"
printf 'Dependencies installed to %s\n' "$prefix"
