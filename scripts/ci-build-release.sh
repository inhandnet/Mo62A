#!/usr/bin/env bash
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true && "${RUNNER_ENVIRONMENT:-}" == github-hosted ]] || {
  echo 'Use a disposable GitHub-hosted runner for this release build.' >&2; exit 1;
}
[[ $# == 1 && "$1" =~ ^V(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || exit 1
version=$1
export TI_SDK_PATH=$(pwd -P)
sdk_link=/opt/ti-processor-sdk-linux-rt-edgeai-am62a-evm-11.01.07.05
[[ ! -e "$sdk_link" && ! -L "$sdk_link" ]] || { echo 'SDK path unexpectedly exists' >&2; exit 1; }
sudo ln -s "$TI_SDK_PATH" "$sdk_link"
git lfs pull
git lfs fsck --objects HEAD
read -r rootfs rootfs_sha image_size < <(python3 -c 'import yaml; c=yaml.safe_load(open(".github/release-policy.yml")); print(c["rootfs"], c["rootfs_sha256"], c["image_size_gib"])')
printf '%s  %s\n' "$rootfs_sha" "$rootfs" | sha256sum -c -
jobs=$(nproc)
# linux depends on DTBs and both U-Boot builds; stage only after the final FIT signing rebuild.
make TI_SDK_PATH="$TI_SDK_PATH" MAKE_JOBS="$jobs" linux
make TI_SDK_PATH="$TI_SDK_PATH" MAKE_JOBS="$jobs" linux_stage
build_date=$(git show -s --format=%cs HEAD)
output="$RUNNER_TEMP/mo62a-image-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
sudo env TI_SDK_PATH="$TI_SDK_PATH" JOBS="$jobs" bash bin/mo-62a-flash.sh \
  --image --rootfs "$rootfs" --version "$version" --output-dir "$output" \
  --image-size-gib "$image_size" --compression xz --date "$build_date"
kernel=$(cat board-support/ti-linux-kernel-*/include/config/kernel.release)
sudo bash scripts/verify-image.sh "$output/mo62a-trixie-xfce-$version.img" "$kernel"
xz -t "$output/mo62a-trixie-xfce-$version.img.xz"
mkdir -p dist
sudo mv "$output/mo62a-trixie-xfce-$version.img.xz" dist/
sudo chown "$(id -u):$(id -g)" "dist/mo62a-trixie-xfce-$version.img.xz"
raw_size=$(stat -c %s "$output/mo62a-trixie-xfce-$version.img")
python3 scripts/release.py --version "$version" --output dist \
  --image "dist/mo62a-trixie-xfce-$version.img.xz" --raw-size "$raw_size" --kernel "$kernel"
( cd dist && sha256sum -c SHA256SUMS )
du -h dist/*
