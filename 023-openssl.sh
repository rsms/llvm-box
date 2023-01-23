#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/config.sh"

_fetch_source_tar \
  https://www.openssl.org/source/openssl-$OPENSSL_VERSION.tar.gz \
  "$OPENSSL_SHA256" "$OPENSSL_SRC"

_pushd "$OPENSSL_SRC"

CC=$STAGE2_CC \
LD=$STAGE2_LD \
AR=$STAGE2_AR \
CFLAGS="${STAGE2_CFLAGS[@]}" \
LDFLAGS="${STAGE2_LDFLAGS[@]}" \
./config \
  --prefix=/ \
  --libdir=lib \
  --openssldir=/etc/ssl \
  no-shared \
  no-zlib \
  no-async \
  no-comp \
  no-idea \
  no-mdc2 \
  no-rc5 \
  no-ec2m \
  no-sm2 \
  no-sm4 \
  no-ssl2 \
  no-ssl3 \
  no-seed \
  no-weak-ssl-ciphers \
  -Wa,--noexecstack

make -j$(nproc)

rm -rf "$LLVMBOX_SYSROOT"
mkdir -p "$LLVMBOX_SYSROOT"
make DESTDIR="$LLVMBOX_SYSROOT" install_sw

_popd
rm -rf "$OPENSSL_SRC"
