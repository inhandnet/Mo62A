#!/usr/bin/env bash
# For disposable GitHub-hosted Ubuntu 22.04 runners only, not developer machines.
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_ENVIRONMENT:-}" == github-hosted ]] || {
  echo 'This setup script is restricted to GitHub-hosted runners.' >&2; exit 1;
}
source /etc/os-release
[[ "$ID" == ubuntu && "$VERSION_ID" == 22.04 ]] || { echo 'Ubuntu 22.04 required' >&2; exit 1; }
# Reclaim optional preinstalled SDKs in this disposable VM. Never target the checkout.
for sdk in /usr/local/lib/android /usr/share/dotnet /opt/ghc; do
  if [[ -d "$sdk" && ! -L "$sdk" ]]; then sudo rm -rf -- "$sdk"; fi
done
sudo apt-get update -q
sudo apt-get install -y --no-install-recommends \
  build-essential bc bison flex swig libssl-dev libgnutls28-dev \
  libncurses-dev libelf-dev uuid-dev autoconf automake libtool pkg-config \
  python3 python3-dev python3-setuptools python3-yaml python3-pyelftools \
  python3-cryptography python3-pycryptodome python3-pytest python3-jsonschema yamllint \
  u-boot-tools device-tree-compiler parted fdisk dosfstools e2fsprogs \
  kmod cpio rsync lzop lz4 xz-utils zip zstd file \
  qemu-user-static binfmt-support git-lfs curl wget
# TI's binman board configuration entry imports these modules during U-Boot packaging.
# Check them before downloading the SDK's large LFS objects or starting compilation.
/usr/bin/python3 scripts/check-build-python.py
sudo update-binfmts --enable qemu-aarch64
[[ -r /proc/sys/fs/binfmt_misc/qemu-aarch64 ]] || { echo 'AArch64 binfmt is missing' >&2; exit 1; }
grep -q '^enabled' /proc/sys/fs/binfmt_misc/qemu-aarch64
free_bytes=$(df -B1 --output=avail "$GITHUB_WORKSPACE" | tail -n 1 | tr -d ' ')
(( free_bytes >= 35 * 1024 * 1024 * 1024 )) || { echo 'At least 35 GiB free disk is required before LFS download' >&2; exit 1; }
df -h "$GITHUB_WORKSPACE"
