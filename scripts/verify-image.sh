#!/usr/bin/env bash
# Inspect an already-built raw image using read-only loop devices and mounts.
set -euo pipefail
[[ ($# == 2 || $# == 3) && $EUID == 0 ]] || { echo 'Usage: sudo verify-image.sh IMAGE KERNEL_RELEASE [DPKG_STATUS_COPY]' >&2; exit 1; }
image=$(realpath -e -- "$1")
kernel=$2
[[ -f "$image" && "$kernel" =~ ^[a-zA-Z0-9._+-]+$ ]] || exit 1
inspect_dir=$(mktemp -d /tmp/mo62a-image-check.XXXXXX)
loop=''
cleanup() {
  set +e
  mountpoint -q "$inspect_dir/rootfs" && umount "$inspect_dir/rootfs"
  mountpoint -q "$inspect_dir/boot" && umount "$inspect_dir/boot"
  [[ -n "$loop" ]] && losetup -d "$loop"
  rmdir "$inspect_dir/rootfs" "$inspect_dir/boot" "$inspect_dir" 2>/dev/null || true
}
trap cleanup EXIT
sfdisk --json "$image" | python3 -c '
import json, sys
t=json.load(sys.stdin)["partitiontable"]; p=t["partitions"]
assert t["label"]=="dos" and len(p)==3
assert p[0]["start"]==2048 and p[0]["type"].lower() in ("c", "0c") and p[0]["bootable"]
assert p[1]["type"]=="82" and p[1]["size"]*512==4*1024**3
assert p[2]["type"]=="83"
'
loop=$(losetup --find --show --read-only --partscan "$image")
udevadm settle
mkdir "$inspect_dir/boot" "$inspect_dir/rootfs"
mount -o ro "${loop}p1" "$inspect_dir/boot"
mount -o ro,noload "${loop}p3" "$inspect_dir/rootfs"
for file in tiboot3.bin tispl.bin u-boot.img Image extlinux/extlinux.conf sysconfig.txt; do
  [[ -s "$inspect_dir/boot/$file" ]] || { echo "Missing BOOT file: $file" >&2; exit 1; }
done
[[ -s "$inspect_dir/boot/ti/k3-am62a7-mo-62a.dtb" ]]
root="$inspect_dir/rootfs"
[[ -s "$root/etc/os-release" && -x "$root/usr/local/bin/app_edgeai" ]]
[[ -s "$root/usr/lib/modules/$kernel/modules.dep" ]]
[[ -n "$(find "$root/usr/lib/modules/$kernel" -name 'cryptodev.ko*' -print -quit)" ]]
grep -q cryptodev "$root/usr/lib/modules/$kernel/modules.dep"
[[ -x "$root/usr/local/bin/edgeai-demo" ]]
[[ -s "$root/opt/ti/edgeai/lib/libonnxruntime.so.1.23.0" ]]
[[ -s "$root/usr/lib/firmware/ti-ipc/am62axx/dsp_edgeai_c7x_1_release_strip.out" ]]
[[ -s "$root/var/lib/dpkg/status" ]]
if [[ $# == 3 ]]; then
  # The SBOM is generated from the package database of this exact image.
  install -m 0644 "$root/var/lib/dpkg/status" "$3"
fi
echo 'PASS: partition layout, boot artifacts, kernel modules, cryptodev and EdgeAI files'
echo 'Physical-board boot and peripheral validation are not performed by this check.'
