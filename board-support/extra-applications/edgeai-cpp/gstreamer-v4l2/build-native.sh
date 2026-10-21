#!/bin/bash
# Build the Debian 13 base-image V4L2 plugin with the negotiated-caps backport.
# Run natively on arm64, or inside the existing edgeai-cpp qemu chroot.
# Usage: bash build-native.sh SOURCE_ARCHIVE OUTPUT_DIRECTORY
set -euo pipefail
[[ $# == 2 ]] || { echo 'Usage: build-native.sh SOURCE_ARCHIVE OUTPUT_DIRECTORY' >&2; exit 2; }
self=$(cd "$(dirname "$0")" && pwd)
archive=$(realpath "$1")
mkdir -p "$2"
out=$(realpath "$2")
[[ $(dpkg --print-architecture) == arm64 ]] || { echo 'An arm64 Debian build environment is required.' >&2; exit 1; }
[[ $(pkg-config --modversion gstreamer-1.0) == 1.26.2 ]] || {
    echo 'This backport targets GStreamer 1.26.2; review it when changing the base image.' >&2; exit 1;
}
printf '%s  %s\n' d864b9aec28c3a80895468c909dd303e5f22f92d6e2b1137f80e2a1454584339 "$archive" | sha256sum -c -
work=$(mktemp -d "$out/build.XXXXXXXX")
tar -xf "$archive" -C "$work"
src="$work/gst-plugins-good-1.26.2"
patch --batch --forward -d "$src" -p1 < "$self/0001-v4l2-decoder-update-negotiated-caps.patch"
meson setup "$work/build" "$src" --buildtype=release --wrap-mode=nodownload \
    -Dauto_features=disabled -Dv4l2=enabled -Dv4l2-gudev=enabled \
    -Dtests=disabled -Dexamples=disabled -Ddoc=disabled
ninja -C "$work/build" -j "${JOBS:-2}" sys/v4l2/libgstvideo4linux2.so
install -m 644 "$work/build/sys/v4l2/libgstvideo4linux2.so" "$out/libgstvideo4linux2.so"
echo "Built $out/libgstvideo4linux2.so (build sources retained in $work)"
