# V4L2 decoder caps backport

The Debian 13 base uses GStreamer 1.26.2. Its V4L2 decoder negotiates NV12
with the driver but can still send the originally acquired I420 caps to
downstream elements. The patch updates `acquired_caps` after a successful
format change, matching the fix in upstream GStreamer 1.26.10:

https://gitlab.freedesktop.org/gstreamer/gstreamer/-/blob/1.26.10/subprojects/gst-plugins-good/sys/v4l2/gstv4l2videodec.c

`../build.sh` downloads the checksum-pinned 1.26.2 source archive, builds only
the V4L2 plugin inside its existing arm64 chroot, and installs it into the
image. The normal GStreamer libraries and other plugins remain unchanged.
This adds a source-download dependency and Meson/Ninja to the build environment.
The backport is deliberately version-checked; review it when updating the
base rootfs instead of overwriting a newer plugin with an older build.

To reproduce on an arm64 Debian 13 development device with GStreamer 1.26.2:

```sh
sudo apt-get install build-essential pkg-config patch meson ninja-build \
  libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libgudev-1.0-dev
curl -fLO https://gstreamer.freedesktop.org/src/gst-plugins-good/gst-plugins-good-1.26.2.tar.xz
bash build-native.sh gst-plugins-good-1.26.2.tar.xz ./out
```

The build script retains sources and does not install over the running system.
Stop video applications and back up the existing plugin before installing
`out/libgstvideo4linux2.so` into `/usr/lib/aarch64-linux-gnu/gstreamer-1.0/`.
This plugin fix also requires the Mo62A AM62A VPU polling device-tree fix.
The AM62A plugin map uses `capture-io-mode: 4`: Wave5 exports the decoded
planes, then `tiovxmemalloc` copies them into a contiguous TI buffer. This is
hardware decoding with a buffer copy, not a zero-copy claim. Import mode 5
cannot import the TI allocator's single buffer into the selected NV12M layout.

Regression pipeline (TI environment paths must be set as in `edgeai-demo`):

```sh
gst-launch-1.0 -v filesrc location=sample.mp4 ! qtdemux ! h264parse ! \
  v4l2h264dec capture-io-mode=4 ! tiovxmemalloc pool-size=12 ! \
  video/x-raw,format=NV12 ! fakesink sync=false
```

Check negotiated NV12 caps, successful preroll and EOS, then test the complete
Python and C++ file-input demos. Decoding alone does not validate inference.
