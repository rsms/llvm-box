#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/config.sh"
#
# Manual first steps:
# 1. Download all SDKs you'd like to import from
#    https://developer.apple.com/download/all/?q=command%20line
#    Note that you can search for specific OS versions, e.g.
#    https://developer.apple.com/download/all/?q=command%20line%2010.13
# 2. Mount all downloaded disk images,
#    so that you have e.g. "/Volumes/Command Line Developer Tools"
# 3. Run this script
#
CLT_PKG="/Volumes/Command Line Developer Tools/Command Line Tools.pkg"
PBZX=$BUILD_DIR/pbzx  # https://github.com/NiklasRosenstein/pbzx
CC=$STAGE2_CC ; [ -x "$CC" ] || CC=$STAGE1_CC
CLT_TMP_DIR="$BUILD_DIR/apple-clt-tmp"
SDKS=()
SDK_VERSIONS=()

_pbzx() {
  if [ ! -x "$PBZX" ]; then
    echo clang -llzma -lxar -I /usr/local/include pbzx.c -o "$PBZX"
         clang -llzma -lxar -I /usr/local/include pbzx.c -o "$PBZX"
  fi
  "$PBZX" "$@"
}

_sdk_version() { # <sdkpath>
  local re='Mac[a-zA-Z]+([0-9]+\.[0-9]+)'
  while [[ $1 =~ $re ]]; do
    echo ${BASH_REMATCH[1]}
    return 0
  done
}

_add_sdks() { # <path> ...
  local d
  local found
  local ver
  local path
  for d in "$@"; do
    # Resolve symlinks since some versioned SDK dirs point to unversioned dirs, e.g.
    #   MacOSX10.13.sdk -> MacOSX.sdk
    # For newer versions it's the other way around and this has no effect.
    path="$(realpath "$d")"
    [ -d "$path" ] || continue
    ver=$(_sdk_version "$d" || true)
    [ -n "$ver" ] || _err "invalid version in '$d'"
    found=
    for v in "${SDK_VERSIONS[@]:-}"; do
      if [ "$v" = "$ver" ]; then
        found=1
        break
      fi
    done
    if [ -z "$found" ]; then
      SDKS+=( "$ver:$path" )
      SDK_VERSIONS+=( "$ver" )
    fi
  done
}

_import_headers() { # <sdk-dir> <sysroot-name> <arch>
  local sdkdir=$1
  local sysroot_name=$2
  local arch=$2
  local dst_incdir="$SYSROOT_TEMPLATE/libc/include/$sysroot_name"
  mkdir -p "$dst_incdir"
  local tmpfile="$BUILD_DIR/libc-headers-tmp"

  "$CC" --sysroot="$sdkdir" --target=$arch-apple-darwin \
        -o "$tmpfile" "$PROJECT/headers.c" -MD -MV -MF "$tmpfile.d"

  # printf "  cp"
  while read -r line; do
    [[ "$line" != *":"* ]] || continue        # ignore first line
    [[ "$line" != *"/clang/"* ]] || continue  # ignore clang builtins like immintrin.h
    path=${line/ \\/}                         # "foo \" => "foo"
    name="${path/*\/usr\/include\//}"         # /a/b/usr/include/foo/bar.h => foo/bar.h
    [[ "$name" != "/"* ]] || _err "expected path to contain /usr/include/: '$line'"
    # printf " $name"
    ( mkdir -p "$(dirname "$dst_incdir/$name")" &&
      install -m 0644 "$path" "$dst_incdir/$name" ) &
  done < "$tmpfile.d"
  wait
  # echo
}

_import_sdk() { # <path> <version>
  local sdkdir=$1
  local sysver=$2
  local sysroot_name="$HOST_ARCH-macos.$sysver"
  echo "importing $sysroot_name"

  [ -d "$sdkdir" ] || _err "'$sdkdir' is not a directory"
  [[ "$(basename "$sdkdir" .sdk)" == "MacOSX"* ]] ||
    _err "SDK doesn't start with 'MacOSX'; bailing out ($sdkdir)"

  _import_headers "$sdkdir" "$sysroot_name" "$HOST_ARCH"
}

# ———————————————————————————————————————————————————————————————————————————————————

mkdir -p "$CLT_TMP_DIR"

# extract mounted "Command Line Developer Tools" installers
for d in "/Volumes/Command Line Developer Tools"*; do
  ID=
  DISK_IMAGE="$(hdiutil info | grep -B20 "$d" | grep image-path |
    awk '{print $3 $4 $5 $6 $7}' || true)"
  if [ -f "$DISK_IMAGE" ]; then
    ID=$(sha1sum "$DISK_IMAGE" | cut -d' ' -f1)
  else
    ID=$(sha1sum <<< "$d" | cut -d' ' -f1)
  fi
  SUBDIR="$CLT_TMP_DIR/$ID"
  if [ -d "$SUBDIR" ]; then
    # echo "skipping already-processed $(_relpath "$SUBDIR")"
    continue
  fi
  echo "extracting $(_relpath "$d")"
  mkdir -p "$SUBDIR"
  _pushd "$SUBDIR"
  pkg="$(echo "$d/Command Line Tools"*.pkg)"
  if [ -f "$pkg" ]; then
    # extra .pkg wrapper
    echo "  xar -xf $pkg"
    xar -xf "$pkg"
  else
    # pre 10.14 SDKs didn't have that wrapper
    echo "  cp" "$d"/*_SDK_macOS*.pkg "."
    cp -a "$d"/*_SDK_macOS*.pkg .
  fi
  for f in *_mac*_SDK.pkg *_SDK_macOS*.pkg; do
    [ -e "$f" ] || continue
    payload_file="$f/Payload"
    if [ -f "$f" ]; then
      echo "  xar -xf $f"
      xar -xf "$f"
      payload_file="Payload"
    fi
    echo "  $PBZX -n $payload_file | cpio -i"
    _pbzx -n "$payload_file" | cpio -i 2>/dev/null &
  done
  printf "  ..." ; wait ; echo
  rm -rf Payload Bom PackageInfo Distribution Resources *.pkg
  _popd
done

# add SDKs from extracted "Command Line Developer Tools" installers
_add_sdks $CLT_TMP_DIR/*/Library/Developer/CommandLineTools/SDKs/MacOSX*.*.sdk

# add system-installed SDKs from well-known paths
_add_sdks /Library/Developer/CommandLineTools/SDKs/MacOSX*.*.sdk
_add_sdks /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX*.*.sdk

# add system-installed SDKs from xcrun
if command -v xcrun >/dev/null; then
  _add_sdks "$(xcrun --show-sdk-path)"
  _add_sdks "$(xcrun -sdk macosx --show-sdk-path)"
fi

# print what will be imported
echo "Importing ${#SDKS[@]} macOS SDKs:"
for d in "${SDKS[@]}"; do
  IFS=: read -r ver path <<< "$d"
  if [[ "$path" == "$CLT_TMP_DIR/"* ]]; then
    SUBDIR="${path:$(( ${#CLT_TMP_DIR} + 1 ))}"
    SUBDIR="$CLT_TMP_DIR/${SUBDIR%%/*}"
  else
    SUBDIR="$path"
  fi
  printf -- "- %- 5s  %-15s  %s\n" \
    "$ver" "$(basename "$path")" "$(_relpath "$SUBDIR")"
done

# actually import
for d in "${SDKS[@]}"; do
  IFS=: read -r ver path <<< "$d"
  _import_sdk "$path" "$ver"
done
