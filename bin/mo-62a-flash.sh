#!/usr/bin/env bash
set -euo pipefail

# mo-62a-flash.sh — unified SD card / offline image creation tool
#
# Without arguments, prompts to choose:
#   [1] Write directly to an SD card
#   [2] Create an offline .img for Armbian Imager
#
# SD card sub-modes (chosen interactively):
#   full      - create partitions + format + copy BOOT + extract rootfs
#   partition - create partitions + format only
#   boot      - copy BOOT partition content only (strict layout check)
#   rootfs    - copy rootfs partition content only (strict layout check)
#
# Use --image with explicit inputs for non-interactive offline image creation.
# Direct SD card writes remain interactive only.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SDK_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

BUILT_IMAGES_DIR="$SDK_ROOT/board-support/built-images"
EXTLINUX_SRC_DIR="$SDK_ROOT/bin/extlinux"
ROOTFS_TARBALL_DIR="$SDK_ROOT/filesystem"

BOOT_SIZE_MIB=256
BOOT_SIZE_BYTES_EXPECTED=$(( BOOT_SIZE_MIB * 1024 * 1024 ))
SWAP_SIZE_MIB=4096   # 4 GB swap partition (p2), rootfs becomes p3

# ── Shared globals ─────────────────────────────────────────────────────────────
BOOT_MNT=""
ROOTFS_MNT=""
ROOTFS_TARBALL=""

# SD card globals
DEVICE=""
SD_MODE="full"

# Image globals
# Image name format: mo62a-trixie-xfce-<version>   (e.g. mo62a-trixie-xfce-V1.0.0)
# Only VERSION varies between releases; the rest is fixed. DATE is still used to
# stamp built external apps (BUILD_DATE) but is no longer part of the image name.
# Default to the newest release tag of this checkout (e.g. V1.1.0) so the
# interactive default matches the published changelog; --image requires --version.
IMAGE_VERSION="$(git -C "$SCRIPT_DIR" tag -l 'V*' 2>/dev/null | sort -V | tail -n 1)"
[[ -n "$IMAGE_VERSION" ]] || IMAGE_VERSION="V1.0.0"
IMAGE_DATE="$(date +%Y-%m-%d)"
IMAGE_PREFIX="mo62a-trixie-xfce"
OUT_DIR=""
NAME="${IMAGE_PREFIX}-${IMAGE_VERSION}"
IMG_SIZE_GIB=12
COMPRESS="xz"
IMG_PATH=""
LOOPDEV=""
NON_INTERACTIVE=0
DRY_RUN=0
OUTPUT_LOCK=""

# ── Cleanup / error helpers ────────────────────────────────────────────────────
cleanup() {
  set +e
  if mountpoint -q "${BOOT_MNT:-}";   then umount "${BOOT_MNT}";   fi
  if mountpoint -q "${ROOTFS_MNT:-}"; then umount "${ROOTFS_MNT}"; fi
  if [[ -n "${BOOT_MNT:-}"   && -d "${BOOT_MNT:-}"   ]]; then rmdir "${BOOT_MNT}"   2>/dev/null || true; fi
  if [[ -n "${ROOTFS_MNT:-}" && -d "${ROOTFS_MNT:-}" ]]; then rmdir "${ROOTFS_MNT}" 2>/dev/null || true; fi
  if [[ -n "${LOOPDEV:-}" ]]; then losetup -d "${LOOPDEV}" 2>/dev/null || true; fi
  if [[ -n "${OUTPUT_LOCK:-}" ]]; then rmdir "$OUTPUT_LOCK" 2>/dev/null || true; fi
}

die()  { echo "ERROR: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat >&2 <<'USAGE'
Usage: mo-62a-flash.sh
       mo-62a-flash.sh --image --rootfs FILE --version Vx.y.z --output-dir DIR [OPTIONS]
       mo-62a-flash.sh --help

Run without arguments for the interactive menu (requires root).

On launch you will be asked to choose:
  [1] Write directly to an SD card
  [2] Create an offline .img for Armbian Imager

SD card sub-modes (chosen interactively after device selection):
  full      - create partitions + format + copy BOOT + extract rootfs
  partition - create partitions + format only
  boot      - copy BOOT partition content only (strict layout check, no repartition)
  rootfs    - copy rootfs partition content only (strict layout check, no repartition)

Image options (prompted interactively):
  output dir / name / image size (GiB) / compression (zip|xz|none)

Non-interactive mode (offline image only):
  --image                 Create an offline image; never select a physical SD card
  --rootfs FILE           Explicit .tar.xz, .tar.gz or .tar rootfs archive
  --version Vx.y.z         Required release version; lowercase v is normalized to V
  --output-dir DIR        Required output directory; existing outputs are refused
  --image-size-gib N      Whole image size in GiB (default: 12; range: 5..2047)
  --compression FORMAT    xz (default), zip or none
  --date YYYY-MM-DD       Date stamped into external apps (default: today's date)
  --dry-run               Validate inputs and print the plan; no root or writes

Compile and stage the kernel, modules and boot files before creating an image.
Image creation requires root, loop devices and the app build dependencies.
--dry-run does not verify archive contents, build dependencies or bootability.
No --force or unattended physical-device write mode is provided.
USAGE
}

parse_image_args() {
  local option
  local -A seen=()
  IMAGE_VERSION=""
  while (( $# )); do
    option="$1"
    [[ -n "$option" ]] || die "Empty option (use --help)"
    [[ -z "${seen[$option]:-}" ]] || die "Duplicate option: $option"
    seen[$option]=1
    case "$option" in
      --image) NON_INTERACTIVE=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --rootfs|--version|--output-dir|--image-size-gib|--compression|--date)
        [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die "Missing value for $option"
        case "$option" in
          --rootfs) ROOTFS_TARBALL="$2" ;;
          --version) IMAGE_VERSION="$2" ;;
          --output-dir) OUT_DIR="$2" ;;
          --image-size-gib) IMG_SIZE_GIB="$2" ;;
          --compression) COMPRESS="$2" ;;
          --date) IMAGE_DATE="$2" ;;
        esac
        shift 2
        ;;
      *) die "Unknown option: $option (use --help)" ;;
    esac
  done
  [[ "$NON_INTERACTIVE" == 1 ]] || die "Non-interactive options require --image"
  [[ -n "$ROOTFS_TARBALL" ]] || die "--rootfs is required"
  [[ -n "$IMAGE_VERSION" ]] || die "--version is required"
  [[ -n "$OUT_DIR" ]] || die "--output-dir is required"
}

check_image_outputs() {
  local candidate
  for candidate in "$OUT_DIR/$NAME".img* "$OUT_DIR/$NAME.sha256" \
      "$OUT_DIR/mo62a-factory-${IMAGE_VERSION}.deb"; do
    [[ ! -e "$candidate" && ! -L "$candidate" ]] || die "Refusing to overwrite existing output: $candidate"
  done
}

validate_image_args() {
  [[ "$IMAGE_VERSION" =~ ^[Vv](0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
    || die "Version must be Vx.y.z (for example V1.1.0)"
  IMAGE_VERSION="V${IMAGE_VERSION:1}"
  NAME="${IMAGE_PREFIX}-${IMAGE_VERSION}"
  [[ "$IMG_SIZE_GIB" =~ ^[1-9][0-9]{0,3}$ ]] || die "Image size must be an integer GiB in 5..2047"
  (( IMG_SIZE_GIB >= 5 && IMG_SIZE_GIB <= 2047 )) || die "Image size must be in 5..2047 GiB (MBR layout)"
  case "$COMPRESS" in xz|zip|none) ;; *) die "Invalid compression: $COMPRESS (expected zip|xz|none)" ;; esac
  [[ "$IMAGE_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "Date must be YYYY-MM-DD"
  local checked_date
  checked_date="$(date -d "$IMAGE_DATE" +%F 2>/dev/null)" || die "Invalid date: $IMAGE_DATE"
  [[ "$checked_date" == "$IMAGE_DATE" ]] || die "Invalid date: $IMAGE_DATE"
  [[ -f "$ROOTFS_TARBALL" && -r "$ROOTFS_TARBALL" && -s "$ROOTFS_TARBALL" ]] \
    || die "Rootfs must be a non-empty readable regular file: $ROOTFS_TARBALL"
  ROOTFS_TARBALL="$(realpath -e -- "$ROOTFS_TARBALL")"
  case "$ROOTFS_TARBALL" in *.tar.xz|*.tar.gz|*.tar) ;; *) die "Unsupported rootfs tarball: $ROOTFS_TARBALL" ;; esac
  if head -c 42 -- "$ROOTFS_TARBALL" | LC_ALL=C grep -aq '^version https://git-lfs.github.com/spec/v1'; then
    die "Rootfs is a Git LFS pointer; download LFS objects first"
  fi
  OUT_DIR="$(realpath -m -- "$OUT_DIR")"
  case "$OUT_DIR" in /dev|/dev/*|/proc|/proc/*|/sys|/sys/*) die "Unsafe output directory: $OUT_DIR" ;; esac
  [[ ! -e "$OUT_DIR" || -d "$OUT_DIR" ]] || die "Output path is not a directory: $OUT_DIR"
  check_image_outputs
}

print_image_plan() {
  echo "Offline image plan:"
  echo "  rootfs:      $ROOTFS_TARBALL"
  echo "  version:     $IMAGE_VERSION"
  echo "  build date:  $IMAGE_DATE"
  echo "  size (GiB):  $IMG_SIZE_GIB"
  echo "  compression: $COMPRESS"
  echo "  raw image:   $OUT_DIR/$NAME.img"
  if [[ "$COMPRESS" != none ]]; then echo "  compressed:  $OUT_DIR/$NAME.img.$COMPRESS"; fi
  echo "  checksums:   $OUT_DIR/$NAME.sha256"
  echo "  factory deb: $OUT_DIR/mo62a-factory-${IMAGE_VERSION}.deb (if factory bundle is present)"
}

require_root() {
  if [[ "$(id -u)" != "0" ]]; then
    die "Please run as root (use sudo)."
  fi
}

# ── Shared helpers ─────────────────────────────────────────────────────────────
prompt_with_default() {
  local prompt="$1" def="$2" val=""
  read -r -p "${prompt} (default: ${def}): " val
  if [[ -z "$val" ]]; then echo "$def"; else echo "$val"; fi
}

confirm_or_die() {
  local msg="$1" confirm=""
  echo >&2
  echo "$msg" >&2
  read -r -p "Type YES to continue: " confirm
  case "$confirm" in
    YES|yes|Y|y) ;;
    *) die "Aborted." ;;
  esac
}

find_kernel_dir() {
  find "$SDK_ROOT/board-support" -maxdepth 1 -type d -name "ti-linux-kernel-*" 2>/dev/null | head -n 1 || true
}

install_kernel_modules_into_rootfs() {
  local kernel_dir depmod_cmd
  kernel_dir="$(find_kernel_dir)"
  [[ -n "$kernel_dir" ]] || die "ti-linux-kernel-* not found under $SDK_ROOT/board-support; cannot modules_install"
  [[ -d "${ROOTFS_MNT:-}" ]] || die "ROOTFS_MNT not mounted; cannot modules_install"

  if [[ ! -f "$kernel_dir/.config" || ! -f "$kernel_dir/modules.order" ]]; then
    die "Kernel tree not configured/built ($kernel_dir/.config or modules.order missing); run 'make linux' first"
  fi
  if ! find "$kernel_dir" -type f -name '*.ko' -print -quit 2>/dev/null | grep -q .; then
    die "No *.ko found under $kernel_dir; build kernel modules first (e.g. 'make linux')"
  fi

  depmod_cmd="depmod"
  if ! have depmod; then depmod_cmd="true"; fi

  echo "Installing kernel modules into rootfs: $ROOTFS_MNT/usr/lib/modules"
  make -C "$kernel_dir" ARCH=arm64 INSTALL_MOD_PATH="$ROOTFS_MNT" \
    INSTALL_MOD_DIR="usr/lib/modules" DEPMOD="$depmod_cmd" modules_install
}

install_rootfs_overlay() {
  local overlay_dir="$SDK_ROOT/board-support/rootfs-overlay"
  [[ -d "${ROOTFS_MNT:-}" ]] || die "ROOTFS_MNT not mounted; cannot install rootfs overlay"
  [[ -d "$overlay_dir" ]] || { echo "No rootfs-overlay directory found, skipping."; return 0; }

  echo "Installing rootfs overlay: $overlay_dir -> $ROOTFS_MNT"
  # Do not carry the checkout owner's UID onto /etc and other system paths.
  # New entries belong to the installer (root); existing base ownership stays.
  cp -a --no-preserve=ownership "$overlay_dir"/. "$ROOTFS_MNT"/
  # Ensure scripts are executable
  find "$ROOTFS_MNT/usr/local/bin" -type f 2>/dev/null | xargs chmod +x 2>/dev/null || true
  # NetworkManager refuses to load keyfiles that aren't root:root 0600. git only
  # tracks the exec bit (not ownership, not 0600), so a fresh clone ships these
  # 0644, so enforce the required keyfile permissions here.
  if [[ -d "$ROOTFS_MNT/etc/NetworkManager/system-connections" ]]; then
    chown -R 0:0 "$ROOTFS_MNT/etc/NetworkManager/system-connections"
    chmod 600 "$ROOTFS_MNT"/etc/NetworkManager/system-connections/*.nmconnection 2>/dev/null || true
  fi
  echo "Rootfs overlay installed."
  normalize_rootfs_ownership
}

# The base rootfs archive and earlier overlays can carry the build host's
# UID/GID (1000) onto system paths such as /etc/fstab or /usr/include. Any
# such entry outside /home belongs to root on a fresh image; also drop the
# group-write bit that a umask 002 checkout leaves on them.
write_release_file() {
  # Device-side identity of the image, os-release style: cat /etc/mo-62a-release
  local kernel_release target
  [[ -d "${ROOTFS_MNT:-}" ]] || die "ROOTFS_MNT not mounted; cannot write release file"
  kernel_release="$(ls -1 "$ROOTFS_MNT/usr/lib/modules" 2>/dev/null | sort -V | tail -n 1)"
  target="$ROOTFS_MNT/etc/mo-62a-release"
  install -d -m 0755 "$ROOTFS_MNT/etc"
  {
    echo "MO_BOARD=\"Mo 62A\""
    echo "MO_IMAGE_NAME=\"$NAME\""
    echo "MO_IMAGE_VERSION=\"$IMAGE_VERSION\""
    echo "MO_BUILD_DATE=\"$IMAGE_DATE\""
    echo "MO_KERNEL=\"${kernel_release:-unknown}\""
    echo "MO_ROOTFS_TARBALL=\"$(basename -- "${ROOTFS_TARBALL:-unknown}")\""
  } > "$target"
  chmod 0644 "$target"
  echo "Wrote $target ($IMAGE_VERSION, built $IMAGE_DATE)"
}

normalize_rootfs_ownership() {
  [[ -d "${ROOTFS_MNT:-}" ]] || return 0
  local count
  count=$(find "$ROOTFS_MNT" -xdev -path "$ROOTFS_MNT/home" -prune -o \
            \( -uid 1000 -o -gid 1000 \) -print 2>/dev/null | wc -l)
  if (( count > 0 )); then
    echo "Normalizing ownership of $count rootfs entries owned by UID/GID 1000 -> root"
    find "$ROOTFS_MNT" -xdev -path "$ROOTFS_MNT/home" -prune -o \
      \( -uid 1000 -o -gid 1000 \) -print0 2>/dev/null | xargs -0 -r chown -h 0:0
    find "$ROOTFS_MNT" -xdev -path "$ROOTFS_MNT/home" -prune -o \
      \( -type f -o -type d \) -perm -g+w ! -path "$ROOTFS_MNT/tmp" ! -path "$ROOTFS_MNT/var/tmp" \
      ! -path "$ROOTFS_MNT/var/mail" ! -path "$ROOTFS_MNT/var/lock" ! -path "$ROOTFS_MNT/var/local" \
      ! -path "$ROOTFS_MNT/dev/*" -print0 2>/dev/null | xargs -0 -r chmod g-w
  fi
}

build_factory_deb() {
  local version="$1" outdir="$2"
  local factory_dir="$SDK_ROOT/tools/mo62a-factory"
  local deb_path="$factory_dir/dist/mo62a-factory-${version}.deb"

  if [[ -d "$factory_dir" ]]; then
    if [[ -f "$factory_dir/build.sh" ]]; then
      echo "Building mo62a-factory deb for $version ..." >&2
      ( cd "$factory_dir" && bash build.sh "$version" ) || die "Failed to build mo62a-factory deb"
    fi

    if [[ -f "$deb_path" ]]; then
      cp -v "$deb_path" "$outdir/" >&2
    else
      echo "WARN: mo62a-factory deb not found: $deb_path" >&2
    fi
  else
    echo "WARN: mo62a-factory directory not found, skipping factory deb" >&2
  fi
}

install_external_apps_into_rootfs() {
  local ext_dir="$SDK_ROOT/board-support/extra-applications"
  [[ -d "${ROOTFS_MNT:-}" ]] || die "ROOTFS_MNT not mounted; cannot install external apps"
  [[ -d "$ext_dir" ]] || { echo "No external directory found, skipping."; return 0; }

  local sdk_cross="$SDK_ROOT/linux-devkit/sysroots/x86_64-arago-linux/usr/bin/aarch64-oe-linux/aarch64-oe-linux-"
  local sdk_sysroot="$SDK_ROOT/linux-devkit/sysroots/aarch64-oe-linux"

  for app_dir in "$ext_dir"/*/; do
    [[ -f "$app_dir/Makefile" ]] || continue
    echo "Building external app: $(basename "$app_dir")"
    make -C "$app_dir" CROSS_COMPILE="$sdk_cross" SYSROOT="$sdk_sysroot" clean
    make -C "$app_dir" CROSS_COMPILE="$sdk_cross" SYSROOT="$sdk_sysroot" \
      VERSION="$IMAGE_VERSION" BUILD_DATE="$IMAGE_DATE" \
      ROOTFS_TARBALL="$ROOTFS_TARBALL" \
      || die "Failed to build $(basename "$app_dir")"
    make -C "$app_dir" CROSS_COMPILE="$sdk_cross" SYSROOT="$sdk_sysroot" install \
      APP_INSTALL_DIR="$ROOTFS_MNT/usr/bin" \
      VERSION="$IMAGE_VERSION" BUILD_DATE="$IMAGE_DATE" \
      ROOTFS_TARBALL="$ROOTFS_TARBALL" \
      || die "Failed to install $(basename "$app_dir")"
    echo "Installed: $(basename "$app_dir")"
  done
}

install_external_drivers_into_rootfs() {
  local drv_dir="$SDK_ROOT/board-support/extra-drivers"
  [[ -d "${ROOTFS_MNT:-}" ]] || die "ROOTFS_MNT not mounted; cannot install external drivers"
  [[ -d "$drv_dir" ]] || { echo "No external drivers directory found, skipping."; return 0; }

  local kernel_dir sdk_cross
  kernel_dir="$(find_kernel_dir)"
  [[ -n "$kernel_dir" ]] || die "ti-linux-kernel-* not found; cannot build external drivers"
  sdk_cross="$SDK_ROOT/linux-devkit/sysroots/x86_64-arago-linux/usr/bin/aarch64-oe-linux/aarch64-oe-linux-"

  for drv in "$drv_dir"/*/; do
    [[ -f "$drv/Makefile" ]] || continue
    echo "Building external driver: $(basename "$drv")"
    make -C "$drv" ARCH=arm64 CROSS_COMPILE="$sdk_cross" KERNEL_DIR="$kernel_dir" clean
    make -C "$drv" ARCH=arm64 CROSS_COMPILE="$sdk_cross" KERNEL_DIR="$kernel_dir" \
      || die "Failed to build $(basename "$drv")"
    make -C "$drv" ARCH=arm64 CROSS_COMPILE="$sdk_cross" KERNEL_DIR="$kernel_dir" \
      INSTALL_MOD_PATH="$ROOTFS_MNT" modules_install \
      || die "Failed to install $(basename "$drv")"
    echo "Installed: $(basename "$drv")"
  done
}

pick_rootfs_tarball_interactive() {
  [[ -d "$ROOTFS_TARBALL_DIR" ]] || die "Missing directory: $ROOTFS_TARBALL_DIR"
  mapfile -t tars < <(ls -1 "$ROOTFS_TARBALL_DIR"/*.tar.xz 2>/dev/null || true)
  if [[ ${#tars[@]} -eq 0 ]]; then
    mapfile -t tars < <(ls -1 "$ROOTFS_TARBALL_DIR"/*.tar.gz \
                              "$ROOTFS_TARBALL_DIR"/*.tar 2>/dev/null || true)
  fi
  [[ ${#tars[@]} -gt 0 ]] || die "No rootfs tarballs found under: $ROOTFS_TARBALL_DIR"

  echo >&2
  echo "Available rootfs tarballs:" >&2
  local i=1 t
  for t in "${tars[@]}"; do
    echo "  [$i] $(basename "$t")" >&2
    i=$(( i + 1 ))
  done
  echo >&2
  read -r -p "Select rootfs tarball number (or 'q' to abort): " idx
  [[ "$idx" != "q" && "$idx" != "Q" ]] || die "Aborted."
  [[ "$idx" =~ ^[0-9]+$ ]] || die "Invalid selection: $idx"
  (( idx >= 1 && idx <= ${#tars[@]} )) || die "Selection out of range: $idx"
  echo "${tars[$((idx-1))]}"
}

copy_boot_files() {
  echo "Copying boot artifacts to BOOT partition..."
  [[ -d "$BUILT_IMAGES_DIR" ]] || die "Missing directory: $BUILT_IMAGES_DIR"
  [[ -d "$EXTLINUX_SRC_DIR" ]] || die "Missing directory: $EXTLINUX_SRC_DIR"

  local req=(tiboot3.bin tispl.bin u-boot.img Image) f
  for f in "${req[@]}"; do
    [[ -f "$BUILT_IMAGES_DIR/$f" ]] || die "Missing built image: $BUILT_IMAGES_DIR/$f"
    cp -v "$BUILT_IMAGES_DIR/$f" "$BOOT_MNT/"
  done

  [[ -d "$BUILT_IMAGES_DIR/dtb/ti" ]] || die "Missing DTB dir: $BUILT_IMAGES_DIR/dtb/ti"
  rm -rf "$BOOT_MNT/ti" || true
  cp -r "$BUILT_IMAGES_DIR/dtb/ti" "$BOOT_MNT/"

  rm -rf "$BOOT_MNT/extlinux" || true
  cp -r "$EXTLINUX_SRC_DIR" "$BOOT_MNT/"

  if [[ -f "$SDK_ROOT/bin/uEnv.txt" ]]; then
    cp -v "$SDK_ROOT/bin/uEnv.txt" "$BOOT_MNT/uEnv.txt"
  fi

  # First-boot user configuration template (consumed once by mo-62a-auto-config.sh
  # on first boot, then deleted). Customers may edit it on the BOOT drive before
  # first boot to preset the login user, Wi-Fi, hostname, etc.
  if [[ -f "$SDK_ROOT/bin/sysconfig.txt" ]]; then
    cp -v "$SDK_ROOT/bin/sysconfig.txt" "$BOOT_MNT/sysconfig.txt"
  fi
  sync
}

# ── SD card: helpers ───────────────────────────────────────────────────────────
untar_with_pv() {
  local tarball="$1" dest="$2" totals_bytes="${3:-}"
  [[ -f "$tarball" ]] || die "Rootfs tarball not found: $tarball"
  [[ -d "$dest" ]]    || die "Rootfs mountpoint not found: $dest"
  have pv || return 1

  local pv_args=(-p -t -e -r -b)
  if [[ -n "$totals_bytes" && "$totals_bytes" =~ ^[0-9]+$ ]]; then
    pv_args+=(-s "$totals_bytes")
  fi

  case "$tarball" in
    *.tar.xz)
      have xz || return 1
      xz -dc "$tarball" | pv "${pv_args[@]}" | tar --xattrs --acls --numeric-owner -xpf - -C "$dest"
      ;;
    *.tar.gz)
      have gzip || return 1
      gzip -dc "$tarball" | pv "${pv_args[@]}" | tar --xattrs --acls --numeric-owner -xpf - -C "$dest"
      ;;
    *.tar)
      cat "$tarball" | pv "${pv_args[@]}" | tar --xattrs --acls --numeric-owner -xpf - -C "$dest"
      ;;
    *) return 1 ;;
  esac
}

untar_progress() {
  local tarball="$1" dest="$2"
  [[ -f "$tarball" ]] || die "Rootfs tarball not found: $tarball"
  [[ -d "$dest" ]]    || die "Rootfs mountpoint not found: $dest"

  if [[ "$tarball" == *.tar.xz ]] && have xz; then
    local totals_bytes blocking_factor
    totals_bytes="$(xz --robot --list "$tarball" 2>/dev/null | awk '$1=="totals"{print $5}' || true)"
    if [[ -n "$totals_bytes" && "$totals_bytes" =~ ^[0-9]+$ ]]; then
      if have pv && untar_with_pv "$tarball" "$dest" "$totals_bytes"; then
        echo >&2; return 0
      fi
      blocking_factor=$(( totals_bytes / 51200 + 1 ))
      tar --blocking-factor="$blocking_factor" --checkpoint=1 \
        --checkpoint-action='ttyout=Progress %u%\r' -xJpf "$tarball" -C "$dest"
      echo >&2; return 0
    fi
  fi

  if [[ "$tarball" == *.tar.gz ]] && have gzip; then
    local totals_bytes blocking_factor
    totals_bytes="$(gzip -l "$tarball" 2>/dev/null | awk 'NR==2{print $2}' || true)"
    if [[ -n "$totals_bytes" && "$totals_bytes" =~ ^[0-9]+$ ]]; then
      if have pv && untar_with_pv "$tarball" "$dest" "$totals_bytes"; then
        echo >&2; return 0
      fi
      blocking_factor=$(( totals_bytes / 51200 + 1 ))
      tar --blocking-factor="$blocking_factor" --checkpoint=1 \
        --checkpoint-action='ttyout=Progress %u%\r' -xzpf "$tarball" -C "$dest"
      echo >&2; return 0
    fi
  fi

  if have pv && untar_with_pv "$tarball" "$dest" ""; then
    echo >&2; return 0
  fi

  echo "Extracting rootfs (no progress available) ..." >&2
  case "$tarball" in
    *.tar.xz) tar -xJpf "$tarball" -C "$dest" ;;
    *.tar.gz) tar -xzpf "$tarball" -C "$dest" ;;
    *)        tar -xpf  "$tarball" -C "$dest" ;;
  esac
}

part_suffix() {
  local dev="$1"
  if [[ "$dev" =~ [0-9]$ ]]; then echo "p"; else echo ""; fi
}

get_disk_size() {
  lsblk -dn -o SIZE "$1" 2>/dev/null | head -n 1 || true
}

get_part_nodes() {
  local dev="$1" pfx
  pfx="$(part_suffix "$dev")"
  # p1=BOOT  p2=SWAP  p3=rootfs
  echo "${dev}${pfx}1" "${dev}${pfx}2" "${dev}${pfx}3"
}

blkid_type() {
  have blkid || die "blkid not found (install util-linux)"
  blkid -o value -s TYPE "$1" 2>/dev/null | head -n 1 || true
}

lsblk_bytes() {
  have lsblk || die "lsblk not found"
  lsblk -dn -b -o SIZE "$1" 2>/dev/null | head -n 1 || true
}

check_partition_layout_strict() {
  local dev="$1"
  [[ -b "$dev" ]] || die "Invalid drive: $dev"

  local parts_count
  parts_count="$(lsblk -nrpo NAME "$dev" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')"
  [[ "$parts_count" == "3" ]] \
    || die "Strict check failed: expected exactly 3 partitions on $dev (found $parts_count; p1=BOOT p2=SWAP p3=rootfs)"

  local p1 p2 p3
  read -r p1 p2 p3 <<<"$(get_part_nodes "$dev")"
  [[ -b "$p1" ]] || die "Strict check failed: partition 1 (BOOT) not found: $p1"
  [[ -b "$p2" ]] || die "Strict check failed: partition 2 (SWAP) not found: $p2"
  [[ -b "$p3" ]] || die "Strict check failed: partition 3 (rootfs) not found: $p3"

  local p1_bytes
  p1_bytes="$(lsblk_bytes "$p1")"
  if [[ -n "$p1_bytes" && "$p1_bytes" =~ ^[0-9]+$ ]]; then
    local min_bytes max_bytes
    min_bytes=$(( BOOT_SIZE_BYTES_EXPECTED - 16 * 1024 * 1024 ))
    max_bytes=$(( BOOT_SIZE_BYTES_EXPECTED + 16 * 1024 * 1024 ))
    if (( p1_bytes < min_bytes || p1_bytes > max_bytes )); then
      die "Strict check failed: BOOT partition size unexpected: $p1 is ${p1_bytes} bytes (expected ~${BOOT_SIZE_BYTES_EXPECTED})"
    fi
  fi
}

force_unmount_blockdev() {
  local dev="$1"
  [[ -b "$dev" ]] || return 0

  if [[ -r /proc/swaps ]]; then
    if awk 'NR>1{print $1}' /proc/swaps | grep -qx "$dev"; then
      echo "swapoff $dev"; swapoff "$dev" 2>/dev/null || true
    fi
  fi

  if have lsblk; then
    while IFS= read -r mp; do
      [[ -z "$mp" ]] && continue
      echo "umount -f $mp"; umount -f "$mp" 2>/dev/null || true
    done < <(lsblk -nr -o MOUNTPOINT "$dev" 2>/dev/null | sort -u)
  fi

  if have udisksctl; then
    udisksctl unmount -b "$dev" >/dev/null 2>&1 || true
  fi
}

ensure_drive_not_in_use() {
  local drive="$1"
  [[ -n "$drive" && -b "$drive" ]] || die "Invalid drive: $drive"

  if have lsblk; then
    while IFS= read -r node; do
      [[ -z "$node" ]] && continue
      force_unmount_blockdev "$node"
    done < <(lsblk -nrpo NAME "$drive" 2>/dev/null | tail -n +2)
  fi
  force_unmount_blockdev "$drive"

  if have lsblk; then
    if lsblk -nrpo NAME,MOUNTPOINT "$drive" 2>/dev/null \
        | awk 'NF>=2 && $2 != "" {found=1} END{exit found?0:1}'; then
      echo "ERROR: selected drive is still mounted/in use; refusing to repartition:" >&2
      lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE "$drive" >&2 || true
      die "Please close file managers/automount and unmount the SD card, then retry."
    fi
  fi
}

list_candidate_disks() {
  while IFS= read -r line; do
    local name="" size="" type="" model=""
    if [[ "$line" =~ NAME=\"([^\"]*)\" ]];  then name="${BASH_REMATCH[1]}";  fi
    if [[ "$line" =~ SIZE=\"([^\"]*)\" ]];  then size="${BASH_REMATCH[1]}";  fi
    if [[ "$line" =~ TYPE=\"([^\"]*)\" ]];  then type="${BASH_REMATCH[1]}";  fi
    if [[ "$line" =~ MODEL=\"([^\"]*)\" ]]; then model="${BASH_REMATCH[1]}"; fi
    [[ "$type" == "disk" ]] || continue
    [[ "$name" =~ ^/dev/(sd[a-z]+|mmcblk[0-9]+)$ ]] || continue
    printf '%s\t%s\t%s\n' "$name" "$size" "$model"
  done < <(lsblk -dpno NAME,SIZE,TYPE,MODEL -P 2>/dev/null || true)
}

pick_device() {
  local candidates
  mapfile -t candidates < <(list_candidate_disks)
  [[ ${#candidates[@]} -gt 0 ]] \
    || die "No candidate SD card devices found (expected /dev/sdX or /dev/mmcblkN)."

  echo "Detected candidate block devices:" >&2
  local i=1 line
  for line in "${candidates[@]}"; do
    IFS=$'\t' read -r dev size model <<<"$line"
    if [[ -n "${model}" ]]; then
      echo "  [$i] ${dev}  ${size}  ${model}" >&2
    else
      echo "  [$i] ${dev}  ${size}" >&2
    fi
    i=$(( i + 1 ))
  done
  echo >&2
  read -r -p "Select target device number: " idx
  [[ "$idx" != "q" && "$idx" != "Q" ]] || die "Aborted."
  [[ "$idx" =~ ^[0-9]+$ ]] || die "Invalid selection: $idx"
  (( idx >= 1 && idx <= ${#candidates[@]} )) || die "Selection out of range: $idx"
  IFS=$'\t' read -r dev _rest <<<"${candidates[$((idx-1))]}"
  echo "$dev"
}

unmount_device() {
  local dev="$1"
  echo "Checking mounts on $dev ..."
  ensure_drive_not_in_use "$dev"
  sleep 1
  ensure_drive_not_in_use "$dev"
}

create_partitions() {
  local dev="$1"
  sync || true
  if have blockdev; then blockdev --flushbufs "$dev" 2>/dev/null || true; fi

  echo "Wiping old partition table signatures..."
  if have wipefs; then wipefs -a "$dev" || true; fi

  local swap_end_mib=$(( BOOT_SIZE_MIB + SWAP_SIZE_MIB ))
  echo "Creating MBR partitions: BOOT FAT32 ${BOOT_SIZE_MIB}MiB + SWAP ${SWAP_SIZE_MIB}MiB + rootfs ext4 remaining..."
  have parted || die "parted not found"
  parted -s "$dev" mklabel msdos
  parted -s "$dev" mkpart primary fat32 1MiB "${BOOT_SIZE_MIB}MiB"
  parted -s "$dev" set 1 boot on
  parted -s "$dev" set 1 lba on
  parted -s "$dev" mkpart primary linux-swap "${BOOT_SIZE_MIB}MiB" "${swap_end_mib}MiB"
  parted -s "$dev" mkpart primary ext4 "${swap_end_mib}MiB" 100%

  partprobe "$dev" || true
  if have udevadm; then udevadm settle || true; fi
}

format_partitions() {
  local dev="$1" pfx
  pfx="$(part_suffix "$dev")"
  local p1="${dev}${pfx}1" p2="${dev}${pfx}2" p3="${dev}${pfx}3"
  [[ -b "$p1" ]] || die "Partition not found: $p1"
  [[ -b "$p2" ]] || die "Partition not found: $p2"
  [[ -b "$p3" ]] || die "Partition not found: $p3"
  have mkfs.vfat || die "mkfs.vfat not found (install dosfstools)"
  have mkfs.ext4 || die "mkfs.ext4 not found (install e2fsprogs)"
  echo "Formatting BOOT: $p1 (FAT32)";   mkfs.vfat -F 32 -n BOOT "$p1"
  echo "Formatting SWAP: $p2 (swap)";    mkswap -L swap "$p2"
  echo "Formatting rootfs: $p3 (ext4)";  mkfs.ext4 -F -L rootfs "$p3"
}

mount_partitions() {
  local dev="$1" pfx
  pfx="$(part_suffix "$dev")"
  BOOT_MNT="$(mktemp -d /tmp/mo-62a-boot.XXXXXX)"
  ROOTFS_MNT="$(mktemp -d /tmp/mo-62a-rootfs.XXXXXX)"
  mount -t vfat "${dev}${pfx}1" "$BOOT_MNT"
  mount -t ext4 "${dev}${pfx}3" "$ROOTFS_MNT"
}

format_boot_partition_only() {
  local dev="$1" p1 _p2
  read -r p1 _p2 <<<"$(get_part_nodes "$dev")"
  [[ -b "$p1" ]] || die "Partition not found: $p1"
  have mkfs.vfat || die "mkfs.vfat not found (install dosfstools)"
  echo "Formatting BOOT partition: $p1 (FAT32)"
  mkfs.vfat -F 32 -n BOOT "$p1"
}

format_rootfs_partition_only() {
  local dev="$1" _p1 _p2 p3
  read -r _p1 _p2 p3 <<<"$(get_part_nodes "$dev")"
  [[ -b "$p3" ]] || die "Partition not found: $p3"
  have mkfs.ext4 || die "mkfs.ext4 not found (install e2fsprogs)"
  echo "Formatting rootfs partition: $p3 (ext4)"
  mkfs.ext4 -F -L rootfs "$p3"
}

mount_boot_only() {
  local dev="$1" p1 _p2
  read -r p1 _p2 <<<"$(get_part_nodes "$dev")"
  BOOT_MNT="$(mktemp -d /tmp/mo-62a-boot.XXXXXX)"
  mount -t vfat "$p1" "$BOOT_MNT"
}

mount_rootfs_only() {
  local dev="$1" _p1 _p2 p3
  read -r _p1 _p2 p3 <<<"$(get_part_nodes "$dev")"
  ROOTFS_MNT="$(mktemp -d /tmp/mo-62a-rootfs.XXXXXX)"
  mount -t ext4 "$p3" "$ROOTFS_MNT"
}

pick_mode_interactive() {
  echo >&2
  echo "Select operation mode:" >&2
  echo "  [1] full      - create partitions + format + copy BOOT + extract rootfs" >&2
  echo "  [2] partition - create partitions + format only" >&2
  echo "  [3] boot      - copy BOOT content only (strict checks, no repartition)" >&2
  echo "  [4] rootfs    - copy rootfs content only (strict checks, no repartition)" >&2
  echo >&2
  local choice
  read -r -p "Select mode number (default 1): " choice
  case "$choice" in
    ""|1) SD_MODE="full" ;;
    2)    SD_MODE="partition" ;;
    3)    SD_MODE="boot" ;;
    4)    SD_MODE="rootfs" ;;
    q|Q)  die "Aborted." ;;
    *)    die "Invalid mode selection: $choice" ;;
  esac
}

sd_extract_rootfs() {
  echo "Extracting rootfs to rootfs partition..."
  have tar || die "tar not found"
  untar_progress "$ROOTFS_TARBALL" "$ROOTFS_MNT"
  install_kernel_modules_into_rootfs
  install_external_apps_into_rootfs
  install_external_drivers_into_rootfs
  install_rootfs_overlay
  write_release_file
  sync
}

run_sd_flow() {
  have lsblk || die "lsblk not found"

  local dev
  dev="$(pick_device)"
  local dev_size
  dev_size="$(get_disk_size "$dev")"

  echo
  if [[ -n "$dev_size" ]]; then
    echo "TARGET DEVICE: $dev ($dev_size)"
  else
    echo "TARGET DEVICE: $dev"
  fi

  pick_mode_interactive

  if [[ "$SD_MODE" == "full" || "$SD_MODE" == "rootfs" ]]; then
    IMAGE_VERSION="$(prompt_with_default "Version (e.g. V1.0.0)" "$IMAGE_VERSION")"
    IMAGE_DATE="$(prompt_with_default "Build date (YYYY-MM-DD)" "$IMAGE_DATE")"
  fi

  case "$SD_MODE" in
    full|partition)
      echo "MODE: $SD_MODE"
      echo "This will ERASE ALL DATA on $dev."
      ;;
    boot)
      echo "MODE: boot"
      echo "This will overwrite BOOT partition files on $dev (no repartition)."
      ;;
    rootfs)
      echo "MODE: rootfs"
      echo "This will overwrite rootfs partition content on $dev (no repartition)."
      ;;
  esac
  confirm_or_die "Destructive operation — please confirm."

  echo
  unmount_device "$dev"

  case "$SD_MODE" in
    full)
      create_partitions "$dev"
      format_partitions "$dev"
      mount_partitions "$dev"
      copy_boot_files
      ROOTFS_TARBALL="$(pick_rootfs_tarball_interactive)"
      sd_extract_rootfs
      ;;
    partition)
      create_partitions "$dev"
      format_partitions "$dev"
      ;;
    boot)
      check_partition_layout_strict "$dev"
      format_boot_partition_only "$dev"
      mount_boot_only "$dev"
      copy_boot_files
      ;;
    rootfs)
      check_partition_layout_strict "$dev"
      format_rootfs_partition_only "$dev"
      mount_rootfs_only "$dev"
      ROOTFS_TARBALL="$(pick_rootfs_tarball_interactive)"
      sd_extract_rootfs
      ;;
  esac

  echo
  case "$SD_MODE" in
    full)
      echo "Done. BOOT and rootfs written successfully."
      echo "Unmounting..."
      ;;
    partition)
      echo "Done. Partitions created and formatted successfully."
      ;;
    boot)
      echo "Done. BOOT partition updated successfully."
      echo "Unmounting..."
      ;;
    rootfs)
      echo "Done. rootfs partition updated successfully."
      echo "Unmounting..."
      ;;
  esac
}

# ── Image: helpers ─────────────────────────────────────────────────────────────
create_sparse_image() {
  local img="$1" bytes="$2"
  rm -f "$img"
  echo "Creating sparse image: $img (${bytes} bytes)"
  truncate -s "$bytes" "$img"
}

partition_image_mbr() {
  local img="$1"
  local swap_end_mib=$(( BOOT_SIZE_MIB + SWAP_SIZE_MIB ))
  have parted || die "parted not found"
  echo "Partitioning image (MBR): BOOT fat32 ${BOOT_SIZE_MIB}MiB + SWAP ${SWAP_SIZE_MIB}MiB + rootfs ext4 remaining"
  parted -s "$img" mklabel msdos
  parted -s "$img" mkpart primary fat32 1MiB "${BOOT_SIZE_MIB}MiB"
  parted -s "$img" set 1 boot on
  parted -s "$img" set 1 lba on
  parted -s "$img" mkpart primary linux-swap "${BOOT_SIZE_MIB}MiB" "${swap_end_mib}MiB"
  parted -s "$img" mkpart primary ext4 "${swap_end_mib}MiB" 100%

  # Force MBR type byte to FAT32 LBA (0x0c) — AM62* boot ROM is picky.
  if [[ -x /usr/sbin/sfdisk ]]; then
    if ! /usr/sbin/sfdisk --part-type "$img" 1 0x0c; then
      echo "WARN: failed to set MBR partition 1 type to 0x0c; image may not boot on all ROMs" >&2
    fi
    /usr/sbin/sfdisk --activate "$img" 1 >/dev/null 2>&1 || true
  else
    echo "WARN: /usr/sbin/sfdisk not found; cannot force MBR partition 1 type to 0x0c" >&2
  fi
}

attach_loop() {
  local img="$1"
  have losetup || die "losetup not found"
  LOOPDEV="$(losetup --find --show --partscan "$img")"
  [[ -n "$LOOPDEV" ]] || die "losetup failed"
  sleep 0.2
}

format_and_mount_loop_parts() {
  local p1="${LOOPDEV}p1" p2="${LOOPDEV}p2" p3="${LOOPDEV}p3"
  [[ -b "$p1" ]] || die "partition not found: $p1"
  [[ -b "$p2" ]] || die "partition not found: $p2"
  [[ -b "$p3" ]] || die "partition not found: $p3"
  have mkfs.vfat || die "mkfs.vfat not found (install dosfstools)"
  have mkfs.ext4 || die "mkfs.ext4 not found (install e2fsprogs)"

  echo "Formatting BOOT: $p1"
  # Force BPB geometry to match known-good SD card (AM62* ROM sensitive to BPB fields).
  # -g 4/32: heads/sectors-per-track; -h 2048: BPB_HiddSec (1MiB start = 2048 sectors).
  mkfs.vfat -F 32 -n BOOT -g 4/32 -h 2048 "$p1"
  echo "Formatting SWAP: $p2"
  mkswap -L swap "$p2"
  echo "Formatting rootfs: $p3"
  mkfs.ext4 -F -L rootfs "$p3"

  BOOT_MNT="$(mktemp -d /tmp/mo-62a-image-boot.XXXXXX)"
  ROOTFS_MNT="$(mktemp -d /tmp/mo-62a-image-rootfs.XXXXXX)"
  mount -t vfat "$p1" "$BOOT_MNT"
  mount -t ext4 "$p3" "$ROOTFS_MNT"
}

img_extract_rootfs_tarball() {
  local tarball="$1"
  [[ -f "$tarball" ]] || die "Rootfs tarball not found: $tarball"
  have tar || die "tar not found"
  echo "Extracting rootfs tarball to image rootfs partition..."
  case "$tarball" in
    *.tar.xz) tar --xattrs --acls --numeric-owner -xJpf "$tarball" -C "$ROOTFS_MNT" ;;
    *.tar.gz) tar --xattrs --acls --numeric-owner -xzpf "$tarball" -C "$ROOTFS_MNT" ;;
    *.tar)    tar --xattrs --acls --numeric-owner -xpf  "$tarball" -C "$ROOTFS_MNT" ;;
    *) die "Unsupported rootfs tarball: $tarball" ;;
  esac
  sync
}

compress_outputs() {
  local outdir="$1" base="$2"
  case "$COMPRESS" in
    none) return 0 ;;
    zip)
      have zip || die "zip not found (install zip) or use compression: none/xz"
      ( cd "$outdir" && rm -f "${base}.img.zip" && zip -9 "${base}.img.zip" "${base}.img" )
      ;;
    xz)
      have xz || die "xz not found (install xz-utils) or use compression: none/zip"
      ( cd "$outdir" && rm -f "${base}.img.xz" && xz -T0 -6 -k "${base}.img" )
      ;;
    *) die "Invalid compression: $COMPRESS (expected zip|xz|none)" ;;
  esac
}

write_checksums() {
  local outdir="$1" base="$2"
  ( cd "$outdir" && sha256sum "${base}.img"* > "${base}.sha256" )
}

run_image_flow() {
  [[ -d "$BUILT_IMAGES_DIR" ]] || die "Missing built-images: $BUILT_IMAGES_DIR (run build first)"
  [[ -d "$EXTLINUX_SRC_DIR" ]] || die "Missing extlinux dir: $EXTLINUX_SRC_DIR"

  if [[ "$NON_INTERACTIVE" == 0 ]]; then
    ROOTFS_TARBALL="$(pick_rootfs_tarball_interactive)"
    OUT_DIR="$(prompt_with_default "Output directory" "$SCRIPT_DIR/out")"
    IMAGE_VERSION="$(prompt_with_default "Version (e.g. V1.0.0)" "$IMAGE_VERSION")"
    IMAGE_DATE="$(prompt_with_default "Date (YYYY-MM-DD)" "$IMAGE_DATE")"
    NAME="${IMAGE_PREFIX}-${IMAGE_VERSION}"
    IMG_SIZE_GIB="$(prompt_with_default "Image size (GiB, integer)" "$IMG_SIZE_GIB")"
    COMPRESS="$(prompt_with_default "Compression (zip|xz|none)" "$COMPRESS")"
  fi

  [[ "$IMG_SIZE_GIB" =~ ^[0-9]+$ ]] || die "Image size must be an integer GiB"
  mkdir -p "$OUT_DIR"

  if [[ "$NON_INTERACTIVE" == 1 ]]; then
    # Hold a per-version lock and recheck after locking, before any output writes.
    mkdir "$OUT_DIR/.${NAME}.lock" 2>/dev/null || die "Output is locked: $OUT_DIR/.${NAME}.lock"
    OUTPUT_LOCK="$OUT_DIR/.${NAME}.lock"
    check_image_outputs
  fi

  echo >&2
  echo "Summary:" >&2
  echo "  rootfs tarball:  $ROOTFS_TARBALL" >&2
  echo "  out dir:         $OUT_DIR" >&2
  echo "  name:            $NAME" >&2
  echo "  img size (GiB):  $IMG_SIZE_GIB" >&2
  echo "  compress:        $COMPRESS" >&2
  echo "  factory deb:     $OUT_DIR/mo62a-factory-${IMAGE_VERSION}.deb" >&2

  if [[ "$NON_INTERACTIVE" == 0 ]]; then
    confirm_or_die "This will create/overwrite: $OUT_DIR/${NAME}.img (and compressed output)."
  fi
  build_factory_deb "$IMAGE_VERSION" "$OUT_DIR"

  IMG_PATH="$OUT_DIR/${NAME}.img"
  local img_bytes=$(( IMG_SIZE_GIB * 1024 * 1024 * 1024 ))

  create_sparse_image "$IMG_PATH" "$img_bytes"
  partition_image_mbr "$IMG_PATH"
  attach_loop "$IMG_PATH"
  format_and_mount_loop_parts
  copy_boot_files
  img_extract_rootfs_tarball "$ROOTFS_TARBALL"
  install_kernel_modules_into_rootfs
  install_external_apps_into_rootfs
  install_external_drivers_into_rootfs
  install_rootfs_overlay
  write_release_file

  sync
  umount "$BOOT_MNT";   rmdir "$BOOT_MNT"   || true; BOOT_MNT=""
  umount "$ROOTFS_MNT"; rmdir "$ROOTFS_MNT" || true; ROOTFS_MNT=""
  losetup -d "$LOOPDEV"; LOOPDEV=""

  compress_outputs "$OUT_DIR" "$NAME"
  write_checksums  "$OUT_DIR" "$NAME"

  echo
  echo "Done."
  echo "Output directory: $OUT_DIR"
  echo "Raw image:        $OUT_DIR/${NAME}.img"
  echo "Factory deb:      $OUT_DIR/mo62a-factory-${IMAGE_VERSION}.deb"
  if [[ "$COMPRESS" == "zip" && -f "$OUT_DIR/${NAME}.img.zip" ]]; then
    echo "Compressed:       $OUT_DIR/${NAME}.img.zip"
  fi
  if [[ "$COMPRESS" == "xz"  && -f "$OUT_DIR/${NAME}.img.xz" ]]; then
    echo "Compressed:       $OUT_DIR/${NAME}.img.xz"
  fi
  echo "Checksums:        $OUT_DIR/${NAME}.sha256"
}

# ── Top-level entry ────────────────────────────────────────────────────────────
pick_flash_mode() {
  echo >&2
  echo "Select output target:" >&2
  echo "  [1] Write directly to an SD card" >&2
  echo "  [2] Create offline image for Armbian Imager" >&2
  echo >&2
  local choice
  read -r -p "Select target [1/2]: " choice
  case "$choice" in
    1) echo "sd"    ;;
    2) echo "image" ;;
    q|Q) die "Aborted." ;;
    *) die "Invalid selection: $choice" ;;
  esac
}

main() {
  if [[ $# == 1 && ( "$1" == -h || "$1" == --help ) ]]; then usage; return 0; fi
  if [[ $# -gt 0 ]]; then
    parse_image_args "$@"
    validate_image_args
    print_image_plan
    if [[ "$DRY_RUN" == 1 ]]; then
      echo "Dry run only: no files written, builds started or devices accessed."
      return 0
    fi
    require_root
    trap cleanup EXIT
    run_image_flow
    return 0
  fi

  require_root
  trap cleanup EXIT

  echo >&2
  echo "=== Mo 62A Flash Tool ===" >&2

  local target
  target="$(pick_flash_mode)"

  case "$target" in
    sd)    run_sd_flow    ;;
    image) run_image_flow ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
