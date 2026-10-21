#!/bin/bash
# build.sh - Build the C/C++ Edge AI runtime + SDK for Mo-62A via qemu-aarch64 chroot.
# Host x86 builds the aarch64 app_edgeai binary AND assembles an on-device SDK
# (headers + static libs + CMake package + examples), so customers can compile
# and debug their own inference programs directly on the board.
#   sudo bash build.sh                        # standalone -> out/app_edgeai
#   sudo bash build.sh --install <ROOTFS>     # also install app_edgeai + SDK into <ROOTFS>
#   sudo bash build.sh --install <ROOTFS> --base-tar <TARBALL>  # use a specific base rootfs
#   KEEP_CHROOT=1 sudo -E bash build.sh       # keep chroot for debug
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SDK_ROOT="$(cd "$SELF_DIR/../../.." && pwd)"
CHROOT="$SELF_DIR/.build-chroot"
OUT="$SELF_DIR/out"
QEMU="$(command -v qemu-aarch64-static || echo /usr/bin/qemu-aarch64-static)"

# Parallelism is bounded by RAM, not cores: an aarch64 cc1plus running under
# qemu-user costs roughly 1 GB once the emulator's own overhead is counted, and
# this box has been OOM-killed before when a build was allowed to fan out. So
# budget one job per GB of *available* memory (keeping 2 GB headroom) and clamp
# to the core count. Override with JOBS=<n>.
if [ -z "${JOBS:-}" ]; then
  _cores=$(nproc)
  _mem_gb=$(awk '/MemAvailable/{printf "%d", $2/1048576}' /proc/meminfo)
  _by_mem=$(( _mem_gb - 2 ))
  [ "$_by_mem" -lt 1 ] && _by_mem=1
  JOBS=$(( _cores < _by_mem ? _cores : _by_mem ))
  [ "$JOBS" -lt 1 ] && JOBS=1
fi
export JOBS       # the compile step runs inside chroot with `set -u`
echo "  build parallelism: -j$JOBS (cores=$(nproc), MemAvailable=$(awk '/MemAvailable/{printf "%.1fG", $2/1048576}' /proc/meminfo))"

# --- args ---
INSTALL_ROOTFS=""
BASE_TAR="$SDK_ROOT/filesystem/debian-13.5-edgeai-base-arm64.tar.xz"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --install)  INSTALL_ROOTFS="${2:-}"; shift 2 ;;
    --base-tar) BASE_TAR="${2:-}"; shift 2 ;;
    *) echo "ERROR: unknown arg: $1"; exit 1 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root (sudo)"; exit 1; }
[ -f "$BASE_TAR" ] || { echo "ERROR: base tar not found: $BASE_TAR"; exit 1; }
[ -x "$QEMU" ] || { echo "ERROR: qemu-aarch64-static missing (install qemu-user-static)"; exit 1; }
[ -z "$INSTALL_ROOTFS" ] || [ -d "$INSTALL_ROOTFS/usr" ] || { echo "ERROR: invalid ROOTFS: $INSTALL_ROOTFS"; exit 1; }

cleanup() {
  for m in tmp dev/pts dev proc sys; do umount -l "$CHROOT/$m" 2>/dev/null || true; done
  [ -n "${KEEP_CHROOT:-}" ] || rm -rf "$CHROOT"
}
trap cleanup EXIT

echo "[1/6] Extract base rootfs ($BASE_TAR)"
rm -rf "$CHROOT"; mkdir -p "$CHROOT"
tar -C "$CHROOT" --xattrs --xattrs-include='*' --numeric-owner -xpf "$BASE_TAR"

echo "[2/6] Set up qemu chroot"
cp "$QEMU" "$CHROOT/usr/bin/"
# The base may use a systemd-resolved symlink whose /run target is absent here.
cp --remove-destination -L /etc/resolv.conf "$CHROOT/etc/resolv.conf"
printf '#!/bin/sh\nexit 101\n' > "$CHROOT/usr/sbin/policy-rc.d"; chmod +x "$CHROOT/usr/sbin/policy-rc.d"
# base tar ships without empty mount-point dirs; create them before binding
mkdir -p "$CHROOT/proc" "$CHROOT/sys" "$CHROOT/dev/pts" "$CHROOT/tmp"
mount --bind /proc "$CHROOT/proc"; mount --bind /sys "$CHROOT/sys"
mount --bind /dev "$CHROOT/dev"; mount --bind /dev/pts "$CHROOT/dev/pts"
mount -t tmpfs tmpfs "$CHROOT/tmp"

echo "[3/6] Copy sources into chroot"
rm -rf "$CHROOT/opt/ecpp"; mkdir -p "$CHROOT/opt/ecpp"
cp -a "$SELF_DIR/src" "$CHROOT/opt/ecpp/"
cp -a "$SELF_DIR/include" "$CHROOT/opt/ecpp/"
cp -a "$SELF_DIR/prebuilt" "$CHROOT/opt/ecpp/"
cp -a "$SELF_DIR/gstreamer-v4l2" "$CHROOT/opt/ecpp/"
# The Debian base ships a V4L2 decoder caps bug; build the narrow backport
# in this same arm64 environment so future images include the tested fix.
mkdir -p "$OUT"
GST_ARCHIVE="$OUT/gst-plugins-good-1.26.2.tar.xz"
if [ ! -f "$GST_ARCHIVE" ]; then
  curl --fail --location --retry 3 \
    https://gstreamer.freedesktop.org/src/gst-plugins-good/gst-plugins-good-1.26.2.tar.xz \
    --output "$GST_ARCHIVE"
fi
printf '%s  %s\n' d864b9aec28c3a80895468c909dd303e5f22f92d6e2b1137f80e2a1454584339 "$GST_ARCHIVE" | sha256sum -c -
cp "$GST_ARCHIVE" "$CHROOT/opt/ecpp/"

# The base rootfs ships the TIDL runtime that matched the image it was built for.
# When the SDK is upgraded (e.g. TIDL 11_02_17_00 / ONNX Runtime 1.23) those .so
# files are stale: the app would link against the old libonnxruntime SONAME and
# the old libtivision_apps, then fail on-device. Override them here if the
# upgraded libraries are staged next to this script.
TIDL_LIB_OVERRIDE="${TIDL_LIB_OVERRIDE:-$SELF_DIR/prebuilt/ti-lib}"
if [ -d "$TIDL_LIB_OVERRIDE" ]; then
  echo "  overriding TI runtime libs from $TIDL_LIB_OVERRIDE"
  mkdir -p "$CHROOT/opt/ti/edgeai/lib"
  cp -a "$TIDL_LIB_OVERRIDE"/. "$CHROOT/opt/ti/edgeai/lib/"
  ( cd "$CHROOT/opt/ti/edgeai/lib"
    [ -f libonnxruntime.so.1.23.0 ]    && ln -sf libonnxruntime.so.1.23.0 libonnxruntime.so
    [ -f libtivision_apps.so.11.1.0 ]  && ln -sf libtivision_apps.so.11.1.0 libtivision_apps.so
    true )
fi

echo "[4/6] Compile inside chroot"
chroot "$CHROOT" /bin/bash -euo pipefail -c '
export SOC=am62a
if ! command -v meson >/dev/null || ! command -v ninja >/dev/null || \
   ! pkg-config --exists gstreamer-video-1.0 gstreamer-allocators-1.0 gudev-1.0; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    meson ninja-build libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libgudev-1.0-dev
fi
bash /opt/ecpp/gstreamer-v4l2/build-native.sh \
  /opt/ecpp/gst-plugins-good-1.26.2.tar.xz /opt/ecpp/gstreamer-v4l2-out
cp -a /opt/ecpp/include/. /usr/local/include/
ORT=/usr/local/include/onnxruntime/core/session/onnxruntime_c_api.h
if [ -f "$ORT" ]; then
  ln -sf "$ORT" /usr/local/include/onnxruntime_c_api.h
  mkdir -p /usr/local/include/core/session
  ln -sf "$ORT" /usr/local/include/core/session/onnxruntime_c_api.h
fi
cp -f /opt/ecpp/prebuilt/tflite/*.a /usr/local/lib/
ar rcs /usr/local/lib/libXNNPACK.a
# TI runtime .so live in /opt/ti/edgeai/lib (shipped in base rootfs) but are not
# on the default link path; expose them so -ltivision_apps / -lonnxruntime resolve.
ln -sf /opt/ti/edgeai/lib/libtivision_apps.so /usr/local/lib/libtivision_apps.so
ln -sf /opt/ti/edgeai/lib/libonnxruntime.so /usr/local/lib/libonnxruntime.so
CF="-DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=/usr/bin/gcc -DCMAKE_CXX_COMPILER=/usr/bin/g++ -DUSE_TENSORFLOW_RT=ON -DUSE_ONNX_RT=ON -DUSE_DLR_RT=OFF -Wno-dev"
echo "  -> edgeai-dl-inferer"
cd /opt/ecpp/src/edgeai-dl-inferer && rm -rf build && mkdir build && cd build
cmake .. $CF
make -j${JOBS} edgeai_dl_inferer edgeai_pre_process edgeai_post_process
cp -f ../lib/Release/libedgeai_dl_inferer.a /usr/local/lib/
cp -f ../lib/Release/libedgeai_pre_process.a /usr/local/lib/
cp -f ../lib/Release/libedgeai_post_process.a /usr/local/lib/
echo "  -> app_edgeai"
cd /opt/ecpp/src/apps_cpp && rm -rf build && mkdir build && cd build
cmake .. $CF
make -j${JOBS} app_edgeai
file /opt/ecpp/src/apps_cpp/bin/Release/app_edgeai
'

echo "[5/6] Extract product"
APP_BIN="$CHROOT/opt/ecpp/src/apps_cpp/bin/Release/app_edgeai"
DLINF_LIBDIR="$CHROOT/opt/ecpp/src/edgeai-dl-inferer/lib/Release"
[ -f "$APP_BIN" ] || { echo "ERROR: build product missing"; exit 1; }
mkdir -p "$OUT"; cp "$APP_BIN" "$OUT/app_edgeai"
cp "$CHROOT/opt/ecpp/gstreamer-v4l2-out/libgstvideo4linux2.so" "$OUT/"
echo "  product: $OUT/app_edgeai ($(du -h "$OUT/app_edgeai" | cut -f1))"

if [ -n "$INSTALL_ROOTFS" ]; then
  echo "  installing C/C++ Edge AI SDK into $INSTALL_ROOTFS"
  R="$INSTALL_ROOTFS"

  # 1. demo binary
  install -m755 -D "$APP_BIN" "$R/usr/local/bin/app_edgeai"
  install -m644 -D "$OUT/libgstvideo4linux2.so" \
    "$R/usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstvideo4linux2.so"

  # 2. SDK headers -> /usr/include/edgeai (dl-inferer API + backends + app_utils)
  rm -rf "$R/usr/include/edgeai"; mkdir -p "$R/usr/include/edgeai"
  cp -a "$SELF_DIR/include/." "$R/usr/include/edgeai/"

  # 3. static archives -> /usr/lib/edgeai (edgeai_* + TFLite deps + XNNPACK stub)
  mkdir -p "$R/usr/lib/edgeai"
  cp -f "$DLINF_LIBDIR"/libedgeai_dl_inferer.a \
        "$DLINF_LIBDIR"/libedgeai_pre_process.a \
        "$DLINF_LIBDIR"/libedgeai_post_process.a "$R/usr/lib/edgeai/"
  cp -f "$SELF_DIR/prebuilt/tflite/"*.a "$R/usr/lib/edgeai/"
  ar rcs "$R/usr/lib/edgeai/libXNNPACK.a"

  # 4. CMake package -> find_package(EdgeAI)
  install -m644 -D "$SELF_DIR/sdk/EdgeAIConfig.cmake" "$R/usr/lib/cmake/EdgeAI/EdgeAIConfig.cmake"

  # 5. example projects + configs + dev guide -> /usr/share/edgeai-cpp-examples
  EX="$R/usr/share/edgeai-cpp-examples"
  rm -rf "$EX"; mkdir -p "$EX/app_edgeai"
  cp -a "$SELF_DIR/examples/hello_inference" "$EX/"
  cp -a "$SELF_DIR/examples/configs" "$EX/"
  install -m644 "$SELF_DIR/examples/DEV_GUIDE.md" "$EX/DEV_GUIDE.md"
  # full app_edgeai demo = apps_cpp sources + a thin find_package(EdgeAI) CMakeLists
  cp -a "$SELF_DIR/src/apps_cpp/common" \
        "$SELF_DIR/src/apps_cpp/utils" \
        "$SELF_DIR/src/apps_cpp/app_edgeai" "$EX/app_edgeai/"
  install -m644 "$SELF_DIR/examples/app_edgeai/CMakeLists.txt" "$EX/app_edgeai/CMakeLists.txt"
  # never ship stray build trees
  find "$EX" -type d -name build -prune -exec rm -rf {} + 2>/dev/null || true

  echo "  SDK installed: headers=/usr/include/edgeai libs=/usr/lib/edgeai cmake=/usr/lib/cmake/EdgeAI examples=/usr/share/edgeai-cpp-examples"
fi

echo "[6/6] Cleanup"
cleanup; trap - EXIT
echo "=== DONE ==="
