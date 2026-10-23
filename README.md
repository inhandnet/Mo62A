# MO-62A SDK

MO-62A single-board computer SDK, powered by the TI AM62A7 platform, offering up to 2 TOPS AI performance.

[中文](README_ZH.md) · [Downloads and changelog](RELEASES.md) · [Contributing and release policy](CONTRIBUTING.md)

## Mo series repository architecture

[![Mo repository ownership and unified website](architecture/repository-map.en.svg)](architecture/repository-map.en.svg)

| Repository | Maintained source | Delivery responsibility |
|---|---|---|
| **developer** · GitLab | Website components, routes, search, integration and contracts | The complete website, release composition and deployment |
| [mo-docs](https://github.com/inhandnet/mo-docs) | Software/hardware tutorials, specifications, media, design files and training | Versioned content and reference assets |
| [mo-tools](https://github.com/inhandnet/mo-tools) | Toolchain/SDK selection, environment setup, reusable tools and Studio | Tool metadata and source packages |
| [mo-models](https://github.com/inhandnet/mo-models) | Model catalog, compilation resources, compatibility and raw benchmarks | Model references, evidence and artifact status |
| [mo-examples](https://github.com/inhandnet/mo-examples) | Complete examples with related firmware, clients and configuration | Example sources and their requirements |
| **Mo\*** · product repositories | Each product's BSP, drivers, root filesystem, image build and flashing | Product images and checksummed release metadata |

`Mo*` covers independently maintained product repositories such as [Mo62A](https://github.com/inhandnet/Mo62A), Mo68A, Mo69A, Mo67A, Mo3588 and Mo3568. The framework does not fix their number. Hardware content and maintainer training move from mo-hardware into mo-docs; mo-hardware remains a historical migration source and is not a separate member of the target website composition.

Each source repository publishes ordinary versions. Developer alone has website RC/final channels. The target composition binds **developer + mo-docs + mo-tools + mo-models + mo-examples + selected Mo\*** to exact commits and consumed-asset hashes. A new source release does not change an already frozen website combination. Tutorial applicability, PCB revisions, image versions and actual validation remain distinct.

## Product repository boundary

[![Repository ownership and delivery](architecture/ownership.en.svg)](architecture/ownership.en.svg)

Mo62A continues to own BSP, drivers, image builds, flashing and system integration. Website migration does not require changing the kernel, rebuilding images or downloading large images during frontend builds. Developer consumes release.json and SHA256SUMS from a pinned Release. Hardware boot validation follows that Release's validation fields and actual evidence.

The BSP development instructions below retain their existing purpose. Shared tools, models and complete applications connect through their own pinned versions. These diagrams describe the unified target and do not claim release freezing or website rollout is complete.

[![Release composition and promotion](architecture/release-flow.en.svg)](architecture/release-flow.en.svg)

---

## Table of Contents

- [1. Overview](#1-overview)
- [2. Environment Setup](#2-environment-setup)
  - [2.1 Host System Requirements](#21-host-system-requirements)
  - [2.2 Clone This Repository](#22-clone-this-repository)
  - [2.3 Initialize the Environment with setup.sh](#23-initialize-the-environment-with-setupsh)
  - [2.4 Toolchain](#24-toolchain)
- [3. U-Boot](#3-u-boot)
  - [3.1 Related Files](#31-related-files)
  - [3.2 Signing Keys](#32-signing-keys)
  - [3.3 Build U-Boot](#33-build-u-boot)
  - [3.4 Stage Build Artifacts](#34-stage-build-artifacts)
  - [3.5 Build Output](#35-build-output)
- [4. Linux Kernel](#4-linux-kernel)
  - [4.1 Related Files](#41-related-files)
  - [4.2 Build DTBs](#42-build-dtbs)
  - [4.3 Build Kernel](#43-build-kernel)
  - [4.4 Stage Build Artifacts](#44-stage-build-artifacts)
  - [4.5 Build Output](#45-build-output)
  - [4.6 Build Checklist by Change Type](#46-build-checklist-by-change-type)
  - [4.7 Known DTS and Overlay Issues](#47-known-dts-and-overlay-issues)
- [5. Flashing the SD Card](#5-flashing-the-sd-card)
  - [5.1 Prerequisites](#51-prerequisites)
  - [5.2 Launch the Flash Tool](#52-launch-the-flash-tool)
  - [5.3 Online Flashing (Write Directly to SD Card)](#53-online-flashing-write-directly-to-sd-card)
  - [5.4 Offline Image Creation (balenaEtcher)](#54-offline-image-creation-balenaetcher)
  - [5.5 Customising the Rootfs Tarball (Adding apt Packages)](#55-customising-the-rootfs-tarball-adding-apt-packages)
  - [5.6 Rootfs Maintenance — Known Pitfalls and Fixes](#56-rootfs-maintenance--known-pitfalls-and-fixes)
    - [5.6.5 /tmp Not Mounted as tmpfs](#565-tmp-not-mounted-as-tmpfs)
- [6. Partition Layout](#6-partition-layout)
  - [6.1 BOOT Partition Contents](#boot-partition-contents)
  - [6.2 Boot Configuration](#boot-configuration)
- [7. Hardware Reference](#7-hardware-reference)
  - [7.1 Block Diagram Overview](#71-block-diagram-overview)
  - [7.2 Power System](#72-power-system)
  - [7.3 I2C Device Map](#73-i2c-device-map)
  - [7.4 Memory](#74-memory)
  - [7.5 Storage](#75-storage)
  - [7.6 Display — Micro HDMI](#76-display--micro-hdmi)
  - [7.7 Networking — Gigabit Ethernet](#77-networking--gigabit-ethernet)
  - [7.8 USB](#78-usb)
  - [7.9 Wireless — Wi-Fi / Bluetooth](#79-wireless--wi-fi--bluetooth)
  - [7.10 Audio](#710-audio)
  - [7.11 RTC](#711-rtc)
  - [7.12 Expansion Interfaces](#712-expansion-interfaces)
  - [7.13 Debug Interface](#713-debug-interface)
  - [7.14 Boot Configuration](#714-boot-configuration)
  - [7.15 JTAG Interface](#715-jtag-interface)
  - [7.16 Hardware Revision Straps](#716-hardware-revision-straps)
- [8. Display — DPMS Screen Blanking and Wake](#8-display--dpms-screen-blanking-and-wake)
- [9. S1 Power Button](#9-s1-power-button)
- [10. EEPROM](#10-eeprom)
- [11. MO-62A Automated Test Tool](#11-mo-62a-automated-test-tool)

---

## 1. Overview

MO-62A is a single-board computer based on the TI AM62A7 processor, designed for edge AI inference, machine vision, and industrial control applications. The AM62A7 integrates a quad-core Arm Cortex-A53 (up to 1.4 GHz), a single Cortex-R5F real-time processor, and a dedicated MMA (Matrix Multiplication Accelerator), delivering up to 2 TOPS of AI inference performance.

This SDK is built on top of **TI Processor SDK Linux RT EdgeAI AM62A EVM 11.01.07.05** and provides full hardware customization support for the MO-62A board. It includes the following components:

- **U-Boot**: Bootloader customized for MO-62A, including R5 SPL and A53 U-Boot
- **Linux Kernel**: Kernel and device trees customized for MO-62A, based on TI Linux RT kernel
- **Build System**: Unified Makefile-based build and staging workflow
- **Flash Tool**: Supports direct SD card writing and offline balenaEtcher image creation

SDK directory structure overview:

```
mo-62a/
├── board-support/          # U-Boot, Kernel sources and prebuilt images
│   ├── built-images/       # Staged build artifacts (generated after staging)
│   ├── prebuilt-images/    # TI prebuilt firmware (bl31, bl32, ti-dm, etc.)
│   └── extra-applications/ # Board-specific extra applications
├── bin/                    # Helper scripts and flash tool
│   ├── mo-62a-flash.sh     # Unified flash tool
│   └── extlinux/           # U-Boot extlinux boot configuration
├── filesystem/             # rootfs tarball directory
├── linux-devkit/           # AArch64 cross-compilation toolchain
├── k3r5-devkit/            # ARMv7 R5 cross-compilation toolchain
├── makerules/              # Per-component Makefile rules
├── Makefile                # Top-level Makefile
├── Rules.make              # Global path and platform configuration
└── setup.sh                # Development host initialization script
```

---

## 2. Environment Setup

### 2.1 Host System Requirements

The following host environment has been verified for building this SDK:

| Item | Requirement |
|------|-------------|
| OS | Ubuntu 22.04 LTS (x86_64) |
| Kernel | 6.8.0 or later |
| Architecture | x86_64 |

Required host packages:

```bash
sudo apt-get install \
  xinetd tftpd nfs-kernel-server minicom \
  build-essential libncurses5-dev autoconf automake \
  dos2unix screen lrzsz lzop flex libssl-dev \
  u-boot-tools make git parted dosfstools e2fsprogs \
  pv xz-utils zip wget curl cmake
```

### 2.2 Clone This Repository

Clone the MO-62A SDK to any directory on your host machine:

```bash
git clone https://github.com/inhandnet/mo-62a.git
cd mo-62a
```

### 2.3 Initialize the Environment with setup.sh

Run `setup.sh` from the SDK root to initialize the development host:

```bash
./setup.sh
```

The script performs the following steps:

1. **Verifies** the host OS (Ubuntu 22.04 LTS)
2. **Adds** the current user to the `dialout` group (required for serial port access)
3. **Installs** required host packages — press `Y` to install, `n` to skip if already installed
4. **Writes** `TI_SDK_PATH` to `~/.bashrc` pointing to the cloned repository root, so the variable persists across terminal sessions
5. **Creates** a symlink at `/opt/ti-processor-sdk-linux-rt-edgeai-am62a-evm-11.01.07.05` pointing to the cloned repository, required because the cross-compilation toolchain binaries have a hardcoded ELF interpreter path at that location

Example output:

```
-------------------------------------------------------------------------------
MO-62A SDK setup script
SDK root: /home/user/mo-62a
-------------------------------------------------------------------------------

Verifying Linux host distribution
Ubuntu 22.04 LTS is being used, continuing..

User 'user' is already in the 'dialout' group.

Do you wish to install required host packages? (Y/n) n
Host package installation skipped.

TI_SDK_PATH is already set correctly in /home/user/.bashrc:
  export TI_SDK_PATH="/home/user/mo-62a"
TI_SDK_PATH is now set to: /home/user/mo-62a

Creating toolchain symlink...
  /opt/ti-processor-sdk-linux-rt-edgeai-am62a-evm-11.01.07.05 -> /home/user/mo-62a

-------------------------------------------------------------------------------
MO-62A SDK setup completed!
You can now build the SDK from: /home/user/mo-62a
-------------------------------------------------------------------------------
```

> **Note:** After `setup.sh` completes, `TI_SDK_PATH` is active in the current shell and will be automatically set in all future terminal sessions via `~/.bashrc`. Running `setup.sh` again is safe — it will update the symlink and the `TI_SDK_PATH` entry without creating duplicates.

### 2.4 Toolchain

Two cross-compilation toolchains are included in the SDK:

**AArch64 toolchain** — used for Linux kernel and A53 U-Boot:

| Item | Value |
|------|-------|
| Path | `linux-devkit/sysroots/x86_64-arago-linux/usr/bin/aarch64-oe-linux/` |
| Prefix | `aarch64-oe-linux-` |
| GCC version | 13.4.0 |
| Target sysroot | `linux-devkit/sysroots/aarch64-oe-linux/` |

**ARMv7 R5 toolchain** — used for R5 SPL (tiboot3):

| Item | Value |
|------|-------|
| Path | `k3r5-devkit/sysroots/x86_64-arago-linux/usr/bin/arm-oe-eabi/` |
| Prefix | `arm-oe-eabi-` |
| GCC version | 13.4.0 |
| Target sysroot | `k3r5-devkit/sysroots/armv7at2hf-vfp-oe-eabi/` |

To verify both toolchains are available (run after `setup.sh` has completed):

```bash
# AArch64
linux-devkit/sysroots/x86_64-arago-linux/usr/bin/aarch64-oe-linux/aarch64-oe-linux-gcc --version

# ARMv7 R5
k3r5-devkit/sysroots/x86_64-arago-linux/usr/bin/arm-oe-eabi/arm-oe-eabi-gcc --version
```

Expected output:

```
aarch64-oe-linux-gcc (GCC) 13.4.0
Copyright (C) 2023 Free Software Foundation, Inc.

arm-oe-eabi-gcc (GCC) 13.4.0
Copyright (C) 2023 Free Software Foundation, Inc.
```

> **Note:** The toolchain binaries have a hardcoded ELF interpreter path pointing to `/opt/ti-processor-sdk-linux-rt-edgeai-am62a-evm-11.01.07.05/`. The symlink created by `setup.sh` satisfies this requirement regardless of where the repository is cloned. The toolchains are invoked automatically via `Rules.make` and do not require manual PATH export.

---

## 3. U-Boot

### 3.1 Related Files

MO-62A specific files added to the U-Boot source tree:

| File | Description |
|------|-------------|
| `board-support/ti-u-boot-2025.01+git/configs/am62ax_mo_62a_a53_defconfig` | A53 U-Boot defconfig |
| `board-support/ti-u-boot-2025.01+git/configs/am62ax_mo_62a_r5_defconfig` | R5 SPL defconfig |
| `board-support/ti-u-boot-2025.01+git/dts/upstream/src/arm64/ti/k3-am62a7-mo-62a.dts` | A53 main device tree |
| `board-support/ti-u-boot-2025.01+git/dts/upstream/src/arm64/ti/k3-am62a7-mo-62a-pinmux.dtsi` | Pin mux configuration |
| `board-support/ti-u-boot-2025.01+git/arch/arm/dts/k3-am62a7-r5-mo-62a.dts` | R5 SPL device tree |
| `board-support/ti-u-boot-2025.01+git/arch/arm/dts/k3-am62a7-mo-62a-u-boot.dtsi` | U-Boot specific DT additions |
| `board-support/ti-u-boot-2025.01+git/arch/arm/dts/k3-am62a7-mo-62a-binman.dtsi` | Binman packaging configuration |
| `board-support/ti-u-boot-2025.01+git/arch/arm/dts/k3-am62a7-mo-62a-lp4-4GB.dtsi` | LPDDR4 4GB memory configuration |

Prebuilt firmware required during the build (from TI, not modified):

| File | Description |
|------|-------------|
| `board-support/prebuilt-images/am62a-evm/bl31.bin` | Arm Trusted Firmware (TF-A) |
| `board-support/prebuilt-images/am62a-evm/bl32.bin` | OP-TEE OS |
| `board-support/prebuilt-images/am62a-evm/ti-dm/am62axx/dm_edgeai_mcu1_0_release_strip.out` | TI Device Manager firmware |

### 3.2 Signing Keys

The TI K3 binman packaging requires two RSA private key files in PEM format under
`board-support/ti-u-boot-2025.01+git/arch/arm/mach-k3/keys/`:

| File | Used for | Note |
|------|----------|------|
| `custMpk.pem` | Signs `tiboot3-*-hs-*.bin` and `tiboot3-*-hs-fs-*.bin` (HS / HS-FS devices) | Copied from `custMpk.key` on first build |
| `ti-degenerate-key.pem` | Signs `tiboot3-*-gp-*.bin` (GP devices) | Generated locally; AM62A ROM does not verify the RSA signature in GP mode, so any valid RSA key is functionally equivalent |

Both files are covered by `*.pem` in the U-Boot tree's `.gitignore` and are therefore never committed. `make u-boot` (via the `u-boot-keys` prerequisite) generates them automatically on first use — no manual steps are required.

> **Security note:** `custMpk.key` / `custMpk.pem` is the signing key for HS / HS-FS device firmware. Keep it confidential — any party who holds this key can sign firmware that boots on HS-mode MO-62A boards programmed with the matching public certificate.
>
> **Reproducibility note:** `ti-degenerate-key.pem` is generated locally with `openssl genrsa 4096` and will differ from the key in TI's official Processor SDK. This means `tiboot3-*-gp-*.bin` will not be byte-identical to TI's official build. MO-62A boards ship as HS-FS and the GP binary is not used in production; if byte-identical GP output is required, replace the generated file with the key from a full TI Processor SDK installation.

### 3.3 Build U-Boot

U-Boot is built in two separate passes — R5 SPL first, then A53 U-Boot. Both are invoked via the top-level `make` from the SDK root.

**Build R5 SPL (tiboot3):**

```bash
make u-boot-r5
```

This configures the R5 build with `am62ax_mo_62a_r5_defconfig` and compiles using the ARMv7 R5 toolchain (`arm-oe-eabi-`). The output is placed in `board-support/u-boot-build/r5/`.

**Build A53 U-Boot:**

```bash
make u-boot-a53
```

This configures the A53 build with `am62ax_mo_62a_a53_defconfig` and compiles using the AArch64 toolchain (`aarch64-oe-linux-`), incorporating `bl31.bin`, `bl32.bin`, and the TI Device Manager firmware via binman. The output is placed in `board-support/u-boot-build/a53/`.

**Build both in one step:**

```bash
make u-boot
```

### 3.4 Stage Build Artifacts

After a successful build, copy the output binaries to `board-support/built-images/`:

```bash
make u-boot_stage
```

### 3.5 Build Output

After staging, the following files are available in `board-support/built-images/`:

| File | Size | Source | Description |
|------|------|--------|-------------|
| `tiboot3-am62ax-gp-mo-62a.bin` | ~318 KB | R5 build | R5 SPL for GP (General Purpose) devices |
| `tiboot3-am62ax-hs-fs-mo-62a.bin` | ~320 KB | R5 build | R5 SPL for HS-FS (High Security, Field Securable) devices |
| `tiboot3-am62ax-hs-mo-62a.bin` | ~320 KB | R5 build | R5 SPL for HS (High Security) devices |
| `tiboot3.bin` | ~320 KB | R5 build | Default tiboot3 (HS-FS, used by flash tool) |
| `tispl.bin` | ~1.7 MB | A53 build | TI SPL — loads OP-TEE, TF-A, and A53 U-Boot |
| `u-boot.img` | ~1.2 MB | A53 build | A53 U-Boot FIT image |

> **Note:** The appropriate `tiboot3-*.bin` variant depends on the device security state. Most production MO-62A boards ship as HS-FS, which uses `tiboot3-am62ax-hs-fs-mo-62a.bin`. The flash tool uses `tiboot3.bin` (a copy of the HS-FS variant) by default.

---

## 4. Linux Kernel

### 4.1 Related Files

MO-62A specific files added to the Linux kernel source tree:

| File | Description |
|------|-------------|
| `board-support/ti-linux-kernel-6.12.35+git-ti-rt/arch/arm64/configs/am62ax_mo_62a_defconfig` | MO-62A base kernel defconfig |
| `board-support/ti-linux-kernel-6.12.35+git-ti-rt/arch/arm64/boot/dts/ti/k3-am62a7-mo-62a.dts` | MO-62A main device tree |
| `board-support/ti-linux-kernel-6.12.35+git-ti-rt/arch/arm64/boot/dts/ti/k3-am62a7-mo-62a-pinmux.dtsi` | Pin mux configuration |
| `board-support/ti-linux-kernel-6.12.35+git-ti-rt/arch/arm64/boot/dts/ti/k3-am62a7-mo-62a-exp-periph.dtso` | 40-pin peripheral mode DT overlay (I2C + UART + SPI + PWM + MCASP2 + WM8960) |
| `board-support/ti-linux-kernel-6.12.35+git-ti-rt/arch/arm64/boot/dts/ti/k3-am62a7-mo-62a-exp-spi0.dtso` | 40-pin SPI0-only DT overlay |
| `board-support/ti-linux-kernel-6.12.35+git-ti-rt/arch/arm64/boot/dts/ti/k3-am62a7-mo-62a-exp-audio.dtso` | WM8960 Audio HAT DT overlay (I2C + MCASP2 only) |
| `board-support/ti-linux-kernel-6.12.35+git-ti-rt/arch/arm64/boot/dts/ti/k3-am62a7-mo-62a-cam-imx219.dtso` | Sony IMX219 CSI2 camera DT overlay |

The following kernel config fragments are applied on top of the defconfig during the build:

| Fragment | Location | Purpose |
|----------|----------|---------|
| `ti_arm64_prune.config` | `kernel/configs/` | Removes non-TI ARM64 platform support to reduce build size |
| `ti_rt.config` | `kernel/configs/` | Enables PREEMPT_RT real-time kernel patches |

### 4.2 Build DTBs

Build all device tree blobs (63 DTBs and DTBOs in total):

```bash
make linux-dtbs
```

This configures the kernel with `am62ax_mo_62a_defconfig` + `ti_arm64_prune.config` + `ti_rt.config`, then builds all DTBs matching the prefix patterns defined in `Rules.make`:

```
ti/k3-am62a7  ti/k3-fpdlink  ti/k3-am62x-sk  ti/k3-v3link
```

Output is placed in `board-support/ti-linux-kernel-6.12.35+git-ti-rt/arch/arm64/boot/dts/`.

### 4.3 Build Kernel

Build the kernel image, modules, and FitImage:

```bash
make linux
```

This performs the following steps in order:

1. Builds DTBs (calls `linux-dtbs` automatically)
2. Builds U-Boot (calls `u-boot` automatically, required for FitImage signing key)
3. Compiles `Image` and `Image.gz`
4. Compiles kernel modules
5. Packages a signed `fitImage` using `mkimage` with the U-Boot signing key and the ITS template from `board-support/prebuilt-images/am62a-evm/`
6. Rebuilds U-Boot A53 (binman) to embed the MO-62A DTB into `tispl.bin`

### 4.4 Stage Build Artifacts

Copy kernel and DTB outputs to `board-support/built-images/`:

```bash
make linux_stage
```

### 4.5 Build Output

After staging, the following files are added to `board-support/built-images/`:

| File | Size | Description |
|------|------|-------------|
| `Image` | ~18 MB | Uncompressed kernel image |
| `Image.gz` | ~7.0 MB | Compressed kernel image |
| `fitImage` | ~7.3 MB | Signed FIT image (kernel + DTBs), used for verified boot |
| `dtb/ti/*.dtb` / `dtb/ti/*.dtbo` | — | 63 device tree blobs and overlays |

> **Note:** `fitImage` is signed with the `custMpk` key from the U-Boot source tree. The signing step also triggers a rebuild of `tispl.bin` so it embeds the MO-62A DTB (`k3-am62a7-mo-62a.dtb`) in the A53 SPL. This means `make linux` will always update both `fitImage` and `tispl.bin` in `built-images/`.

### 4.6 Build Checklist by Change Type

The flash tool always runs `make modules_install` during both online and offline flashing. This step **unconditionally overwrites** the entire `/lib/modules/<version>/` directory in the rootfs with whatever `.ko` files are currently present in the kernel source tree. If the kernel modules have not been fully compiled beforehand, all previously working modules (DRM/HDMI, Wi-Fi, PWM fan, thermal sensors, etc.) will be wiped from the rootfs, leaving only the modules that happen to exist in the tree at that moment.

Use the table below to determine which build commands are required before running the flash tool:

| Change type | Required build steps |
|-------------|----------------------|
| DTS / pinmux only | `make linux-dtbs` → `make linux-dtbs_stage` → **`make linux`** → `make linux_stage` |
| Kernel source (`.c` / `.h`) | `make linux` → `make linux_stage` |
| U-Boot source | `make u-boot` → `make u-boot_stage` |
| rootfs overlay only (scripts, services) | No kernel rebuild required — flash tool copies the overlay automatically |

> **Important:** Even when only DTS files change, `make linux` must be run (or the kernel module `.ko` files must be confirmed to be fully compiled in the source tree) before flashing. Running only `make linux-dtbs` is not sufficient because it does not compile kernel modules.

The safe, complete build sequence for a new firmware release is:

```bash
# 1. Full kernel build — compiles Image, all modules, and FitImage
make linux

# 2. Stage Image and DTBs to built-images/
make linux_stage
make linux-dtbs_stage

# 3. (Optional) Rebuild U-Boot if U-Boot sources changed
make u-boot
make u-boot_stage

# 4. Flash
sudo bash bin/mo-62a-flash.sh
```

### 4.7 Known DTS and Overlay Issues

This section documents device tree problems that have been encountered and the fixes applied.

---

#### 4.7.1 PCF85363 RTC Registered as rtc1 Instead of rtc0

**Symptom:** After boot, `/dev/rtc0` is assigned to the TPS6594 PMIC internal RTC instead of the PCF85363. Tools that expect the system RTC at `/dev/rtc0` (e.g. `hwclock`) communicate with the wrong device.

**Root cause:** The Linux RTC subsystem assigns device IDs by looking up `rtc` aliases in the DT `aliases` node. The `tps6594-rtc` driver is an MFD sub-device with no `of_node` of its own; the kernel falls back to its parent's `of_node` (`tps659312`) for alias lookup. Because `tps659312` had no `rtc` alias, the PMIC RTC was assigned dynamic ID 0, preempting the PCF85363.

**Fix:** Added `rtc1 = &tps659312` to the `aliases` node in `k3-am62a7-mo-62a.dts`, forcing the TPS6594 internal RTC to request ID 1. The PCF85363 now correctly registers as `/dev/rtc0`.

> The TPS6594 internal RTC has no coin-cell battery backup and is not the intended system RTC. The PCF85363 with its J2 battery connector is the authoritative timekeeping device.

---

#### 4.7.2 SPI0 CS1 Registration Failure (`cs1 >= max 1`)

**Symptom:** When booting with the `exp-spi0` or `exp-periph` overlay, the kernel log shows:

```
spi-rockchip: cs1 >= max 1
```

`/dev/spidev0.1` is not created; only CS0 is available.

**Root cause:** The `&main_spi0` node in the overlay did not set `num-cs`, so the SPI controller defaulted to one chip-select. Any child with `reg = <1>` exceeded the maximum.

**Fix:** Added `num-cs = <2>;` to `&main_spi0` in both `k3-am62a7-mo-62a-exp-spi0.dtso` and `k3-am62a7-mo-62a-exp-periph.dtso`. Both `/dev/spidev0.0` and `/dev/spidev0.1` are now created correctly.

---

#### 4.7.3 DTC `reg_format` Warnings in DT Overlays

**Symptom:** Compiling overlay files with the kernel DTC produces warnings such as:

```
Warning (reg_format): wm8960@1a: reg property has invalid length (expected 4, got 4)
Warning (reg_format): spidev@0: reg property has invalid length
```

**Root cause:** DTC cannot inherit `#address-cells` / `#size-cells` from parent nodes when compiling an overlay in isolation. Without these declarations, the compiler cannot validate `reg` property lengths.

**Fix:** Added `#address-cells = <1>; #size-cells = <0>;` to every overlay node that contains child devices with `reg` properties:

| Overlay file | Node patched |
|---|---|
| `exp-periph.dtso` | `&wkup_i2c0`, `&main_spi0` |
| `exp-audio.dtso` | `&wkup_i2c0` |
| `exp-spi0.dtso` | `&main_spi0` |
| `cam-imx219.dtso` | `&main_i2c2` |

---

## 5. Flashing the SD Card

The unified flash tool `bin/mo-62a-flash.sh` supports two output targets:

- **Online flashing** — write directly to a physical SD card
- **Offline image creation** — create a `.img` file for use with balenaEtcher

Both modes create identical partition layouts and content.

### 5.1 Prerequisites

Required host packages (installed by `setup.sh`):

```
parted  dosfstools  e2fsprogs  pv  xz-utils  zip  wget  curl
```

Ensure the following are ready before running the flash tool:

1. **Built images staged** — run `make u-boot_stage` and `make linux_stage` (or `make all_stage`) so that `board-support/built-images/` contains the required files
2. **Rootfs tarball present** — place a `.tar.xz` or `.tar.gz` rootfs tarball under `filesystem/`
3. **SD card inserted** (online mode only) — the tool automatically detects `/dev/sdX` and `/dev/mmcblkN` block devices

### 5.2 Launch the Flash Tool

Without arguments, the flash tool opens an interactive menu and must be run as root. For unattended offline images, see Section 5.4.1.

```bash
sudo bash bin/mo-62a-flash.sh
```

On launch, it prompts you to choose the output target:

```
=== MO-62A Flash Tool ===

Select output target:
  [1] Write directly to an SD card
  [2] Create offline image for balenaEtcher

Select target [1/2]:
```

### 5.3 Online Flashing (Write Directly to SD Card)

Select `[1]` for online mode. The tool will enumerate all detected block devices:

```
Detected candidate block devices:
  [1] /dev/sda  29.7G  SD Card Reader

Select target device number:
```

Then choose the operation mode:

```
Select operation mode:
  [1] full      - create partitions + format + copy BOOT + extract rootfs
  [2] partition - create partitions + format only
  [3] boot      - copy BOOT content only (strict checks, no repartition)
  [4] rootfs    - copy rootfs content only (strict checks, no repartition)

Select mode number (default 1):
```

| Mode | Description |
|------|-------------|
| `full` | Full write: wipe and repartition, format, copy boot files, extract rootfs, install kernel modules |
| `partition` | Partitioning only: wipe and recreate MBR, format partitions — no content written |
| `boot` | Overwrite BOOT partition only — re-flashes bootloader and kernel without touching rootfs |
| `rootfs` | Overwrite rootfs partition only — re-extracts the rootfs without touching the BOOT partition |

For a fresh SD card, select `full`. The tool will ask for confirmation (`Type YES to continue`), then proceed automatically:

1. Unmounts any existing partitions on the selected device
2. Wipes the old partition table
3. Creates MBR partition table: BOOT (FAT32, 256 MiB) + rootfs (ext4, remaining space)
4. Formats both partitions
5. Copies boot artifacts to the BOOT partition: `tiboot3.bin`, `tispl.bin`, `u-boot.img`, `Image`, DTBs, `extlinux/`
6. Asks which rootfs tarball to use (if multiple are present under `filesystem/`)
7. Extracts the rootfs tarball to the rootfs partition
8. Installs kernel modules (`make modules_install`) into the rootfs
9. Builds and installs any external applications from `board-support/extra-applications/`

Example session (full mode):

```
TARGET DEVICE: /dev/sda (29.7G)

MODE: full
This will ERASE ALL DATA on /dev/sda.

Destructive operation — please confirm.
Type YES to continue: YES

Checking mounts on /dev/sda ...
Wiping old partition table signatures...
Creating MBR partitions (BOOT FAT32(LBA) 256MiB + rootfs ext4 remaining)...
Formatting BOOT: /dev/sda1 (FAT32)
Formatting rootfs: /dev/sda2 (ext4)
Copying boot artifacts to BOOT partition...

Available rootfs tarballs:
  [1] debian-13.2-xfce-v6.12-arm64-2026-01-13-12gb.tar.xz

Select rootfs tarball number (or 'q' to abort): 1

Extracting rootfs to rootfs partition...
Installing kernel modules into rootfs: /tmp/mo-62a-rootfs.xxx/usr/lib/modules
...
Installed: rtk_hciattach

Done. BOOT and rootfs written successfully.
```

After flashing, insert the SD card into the MO-62A board and power on. Boot messages appear on the serial console at `ttyS2` (115200 8N1).

### 5.4 Offline Image Creation (balenaEtcher)

Select `[2]` for image mode. The tool prompts for image parameters:

```
Available rootfs tarballs:
  [1] debian-13.5-edgeai-base-arm64.tar.xz

Select rootfs tarball number (or 'q' to abort): 1

Output directory (default: <repository>/bin/out): /path/to/output
Version (e.g. V1.0.0) (default: V1.0.0): V1.1.0
Date (YYYY-MM-DD) (default: <today>): 2026-10-15
Image size (GiB, integer) (default: 12): 12
Compression (zip|xz|none) (default: xz): xz
```

| Parameter | Description |
|-----------|-------------|
| Output directory | Where to write the `.img` and checksum files |
| Version | Forms the name `mo62a-trixie-xfce-<version>` and the external application version |
| Date | Build date stamped into external applications |
| Image size (GiB) | Whole image size, including BOOT, 4 GiB swap, rootfs and filesystem overhead; default 12 GiB |
| Compression | `xz` (default), `zip`, or `none` (no compression) |

The tool creates a sparse `.img`, partitions and formats it via a loop device, installs the boot files and rootfs, then detaches and compresses it. It shares the kernel-module, external-application, external-driver and overlay installation functions with direct SD card writing. This does not imply byte-identical filesystem images.

Output files:

```
/path/to/output/
├── mo62a-trixie-xfce-V1.1.0.img       # Raw disk image
├── mo62a-trixie-xfce-V1.1.0.img.xz    # Compressed image (default)
├── mo62a-trixie-xfce-V1.1.0.sha256    # SHA-256 checksums of the image files
└── mo62a-factory-V1.1.0.deb          # Separate factory-test package, if available
```

To flash the image with balenaEtcher:

1. Open [balenaEtcher](https://etcher.balena.io/)
2. Decompress the `.img.xz` file and select the resulting `.img` using **Flash from file**
3. Select the target SD card
4. Click **Flash**

> **Note:** Allow space for the expanded rootfs, installed modules and applications, BOOT, swap and filesystem overhead. The default image size is not a guarantee that every custom rootfs will fit. Compressed download size is not the required SD card capacity.

#### 5.4.1 Non-interactive offline images

First compile and stage the kernel, modules, DTBs and U-Boot using the build instructions above. Download Git LFS objects, prepare the toolchain paths, and install the application build dependencies (including `qemu-user-static` and working AArch64 binfmt support for the EdgeAI C++ chroot build).

Validate the arguments and inspect the output plan without root, file writes, mounts or compilation:

```bash
bash bin/mo-62a-flash.sh --image \
  --rootfs filesystem/debian-13.5-edgeai-base-arm64.tar.xz \
  --version V1.1.0 \
  --output-dir /path/to/new-output \
  --dry-run
```

To generate the image, remove `--dry-run` and run the same command with `sudo`. Optional arguments are `--image-size-gib 12`, `--compression xz` and `--date YYYY-MM-DD`; the date defaults to the host's current date. Lowercase `v1.1.0` is normalized to `V1.1.0`; this initial interface accepts stable `Vx.y.z` versions only.

Non-interactive mode never selects a physical SD card. It refuses existing image, checksum or factory-package outputs, including symlinks; use a fresh directory for retries. A per-output-version directory lock prevents concurrent batch jobs from writing the same outputs. Use a separate source checkout for each concurrent build, since compilation modifies the kernel and application trees. After a forcibly terminated job, inspect its processes and mounts before removing any stale lock.

`--dry-run` validates arguments, rootfs file presence and output collisions, **not** archive contents, build dependencies, free space or bootability. This command assembles an offline image; it does not rebuild U-Boot/the kernel, publish a GitHub Release, or update a website. The factory package is separate from the OS image and is not included in its `.sha256` file.

Non-destructive CLI regression tests (Python 3; privileged and build operations are mocked):

```bash
python3 -B -m unittest discover -s tests -p 'test_flash_cli.py' -v
```

### 5.5 Customising the Rootfs Tarball (Adding apt Packages)

The flash tool extracts the rootfs tarball as-is.  Additional Debian packages (e.g. `frei0r-plugins` required by `imx219-preview.sh`) must be pre-installed into the tarball **before** flashing so that they are available both after online and offline flashing without requiring network access on the target.

The standard workflow is:

1. **Install prerequisites on the host** (one-time, x86-64 Ubuntu/Debian):

   ```bash
   sudo apt-get install -y qemu-user-static binfmt-support
   # Registers the arm64 binfmt handler so chroot can run aarch64 binaries directly.
   sudo systemctl restart systemd-binfmt || sudo update-binfmts --enable
   ```

2. **Extract the tarball** into a temporary directory:

   ```bash
   ROOTFS_DIR=/tmp/mo-62a-rootfs
   mkdir -p "$ROOTFS_DIR"
   sudo tar -xpf filesystem/debian-13.2-xfce-v6.12-arm64-2026-01-13-12gb.tar.xz \
       -C "$ROOTFS_DIR"
   ```

   > The `-p` flag preserves file permissions and ownership. Use `sudo` so that device nodes and suid bits are restored correctly.

3. **Copy the qemu binary** into the extracted rootfs:

   ```bash
   sudo cp /usr/bin/qemu-aarch64-static "$ROOTFS_DIR/usr/bin/"
   ```

4. **Bind-mount pseudo-filesystems** and enter the chroot:

   ```bash
   sudo mount --bind /proc    "$ROOTFS_DIR/proc"
   sudo mount --bind /sys     "$ROOTFS_DIR/sys"
   sudo mount --bind /dev     "$ROOTFS_DIR/dev"
   sudo mount --bind /dev/pts "$ROOTFS_DIR/dev/pts"

   sudo chroot "$ROOTFS_DIR" /bin/bash
   ```

5. **Inside the chroot**, install the required packages:

   ```bash
   # (inside chroot)
   apt-get update
   apt-get install -y frei0r-plugins
   apt-get clean          # remove downloaded .deb files to reduce tarball size
   exit
   ```

6. **Clean up** bind mounts and the qemu binary:

   ```bash
   sudo umount "$ROOTFS_DIR/dev/pts"
   sudo umount "$ROOTFS_DIR/dev"
   sudo umount "$ROOTFS_DIR/sys"
   sudo umount "$ROOTFS_DIR/proc"
   sudo rm -f  "$ROOTFS_DIR/usr/bin/qemu-aarch64-static"
   ```

7. **Repack** the tarball (replace the original file):

   ```bash
   TARBALL=filesystem/debian-13.2-xfce-v6.12-arm64-2026-01-13-12gb.tar.xz
   sudo tar -cpJf "$TARBALL" --numeric-owner -C "$ROOTFS_DIR" .
   sudo rm -rf "$ROOTFS_DIR"
   ```

   > **Important:** `sudo` and `--numeric-owner` are both required. Without `sudo`, all root-owned files (sudo, su, Xorg.wrap, etc.) will be stored with the host user's UID, breaking setuid binaries on the target. `--numeric-owner` stores UID/GID as integers rather than names, ensuring correct ownership regardless of host username mapping.
   >
   > Re-packing a ~5–7 GiB rootfs with `xz` compression takes 15–25 minutes. Use `tar -cpzf` (`.tar.gz`) for a faster but larger archive if turnaround time matters during development.

After repacking, re-run the flash tool as normal. The newly installed packages will be present on the target immediately after flashing, with no network access required.

**Packages currently pre-installed via this workflow:**

| Package | Required by | Purpose |
|---------|-------------|---------|
| `frei0r-plugins` | `imx219-preview.sh` | White-balance correction via `frei0r-filter-white-balance` GStreamer element |
| `tcpdump` (+`libpcap0.8t64`) | Wi-Fi monitor mode | 802.11 over-the-air packet capture in monitor mode |

> **Common chroot pitfall:** if the base tar lacks the `/proc`, `/sys`, `/dev`, `/dev/pts`, `/tmp`, `/run` directories, mounting or `apt` will fail (e.g. `tcpdump`'s postinst `adduser` errors with `could not open lock file /run/adduser`). Before entering the chroot, run `sudo mkdir -p "$ROOTFS_DIR"/{proc,sys,dev,dev/pts,tmp,run}` and `chmod 1777 .../tmp`.

### 5.6 Rootfs Maintenance — Known Pitfalls and Fixes

This section documents issues that have been encountered when building or modifying the rootfs tarball, and the fixes that must be applied to preserve a working system.

---

#### 5.6.1 Tarball Packaging Rules (MUST follow every time)

Two rules are non-negotiable when repacking the tarball:

| Rule | Command flag | What breaks without it |
|------|-------------|------------------------|
| Always use `sudo` | `sudo tar -cpJf …` | Root-owned files are stored with the host user's UID (e.g. 1000). `sudo`, `su`, `passwd`, `Xorg.wrap` and other setuid binaries lose their ownership and stop working after flashing. |
| Always use `--numeric-owner` | `tar … --numeric-owner` | UIDs/GIDs are stored as names, not numbers. If the host's `/etc/passwd` does not have the same usernames as the rootfs (e.g. `lightdm`, `saned`, `messagebus`), those entries are silently mapped to `nobody` during extraction, breaking services on the target. |

The correct repack command is:

```bash
sudo tar -cpJf "$TARBALL" --numeric-owner \
    --exclude=./proc --exclude=./sys --exclude=./dev --exclude=./run \
    --exclude=./tmp  --exclude=./mnt --exclude=./media \
    --exclude=./lost+found \
    -C "$ROOTFS_DIR" .
```

---

#### 5.6.2 Mesa bbbio Packages — Must Be Downgraded to Standard Trixie

The rootfs was originally built with Mesa packages from the **BeagleBone.io (bbbio) backport** (`25.3.0-1bbbio0~trixie+20251117`). These packages do not declare a proper `Depends:` on `mesa-libgallium`, so `apt-get autoremove` silently deletes `mesa-libgallium` and the `libgallium-*.so` file along with it.

**Symptom:** lightdm fails to start; Xorg logs show:
```
MESA-LOADER: failed to open gbm: /usr/lib/aarch64-linux-gnu/dri/gbm_dri.so: cannot open shared object file
```

**Fix:** Downgrade all 7 Mesa packages to the standard Debian trixie version (`25.0.7-2`) inside the chroot:

```bash
# Inside chroot
apt-get install -y --allow-downgrades \
    mesa-libgallium=25.0.7-2 \
    libgl1-mesa-dri=25.0.7-2 \
    libgbm1=25.0.7-2 \
    libegl-mesa0=25.0.7-2 \
    libglx-mesa0=25.0.7-2 \
    mesa-va-drivers=25.0.7-2 \
    mesa-vdpau-drivers=25.0.7-2
```

The standard Debian trixie `sources.list` already present in the rootfs is sufficient — no additional apt source is required.

> **Note:** `libdrm2` and related packages remain at the bbbio version (`2.4.127-1bbbio0~trixie+20251111`); these are compatible with Mesa 25.0.7-2 and do not need to be downgraded.

---

#### 5.6.3 Daemon Directory Ownership — Broken by `chown -R root:root`

If you ever run `sudo chown -R root:root <rootfs_dir>` during tarball preparation (e.g., to fix a bulk ownership issue), it will incorrectly reset the ownership of several daemon-specific directories. These must be restored **inside the chroot** (so that username→UID resolution uses the rootfs `/etc/passwd`, not the host's):

```bash
# Inside chroot — restore daemon directory ownership
chown -R lightdm:lightdm  /var/lib/lightdm     # LightDM display manager
chown -R messagebus:messagebus /var/lib/dbus    # D-Bus system bus
chown -R saned:saned      /var/lib/saned        # SANE scanner daemon
chown -R colord:colord    /var/lib/colord        # colord colour management
chown -R man:man          /var/cache/man         # man page cache
chown    root:mail        /var/mail              # mail spool
chmod    2775             /var/mail
```

**Why inside the chroot?** The rootfs uses different UIDs for these service accounts than the host machine. Running `chown lightdm:lightdm` outside the chroot will either fail (if the host has no `lightdm` user) or silently apply the wrong UID. Inside the chroot the correct numeric UID from `/etc/passwd` is used, and `--numeric-owner` in the repack step stores it correctly.

---

#### 5.6.4 `dpkg --verify` — Stale Locale File Entries

`localepurge` removes non-essential locale files from disk after package installation. If `localepurge` is run in a mode that does not update the dpkg database (e.g. not using `USE_DPKG`), the files are deleted from disk but `/var/lib/dpkg/info/<pkg>.list` still references them. `dpkg --verify` then reports thousands of `missing` entries.

**Check:**
```bash
dpkg --verify 2>&1 | grep "^?" | wc -l   # should be 0
```

**Fix (inside chroot or on extracted rootfs):**
```bash
# Collect all paths that dpkg thinks exist but are missing from disk
dpkg --verify 2>&1 | awk '/missing/{print $NF}' > /tmp/dpkg_missing.txt

# Remove those lines from every .list file
for f in /var/lib/dpkg/info/*.list; do
    grep -vFf /tmp/dpkg_missing.txt "$f" > "$f.tmp" || true
    mv "$f.tmp" "$f"
done
rm /tmp/dpkg_missing.txt
```

> **Note:** The tarball shipped from this repository has already had this fix applied. The issue only recurs if `localepurge` runs again on the live device without `USE_DPKG` mode enabled.

---

#### 5.6.5 `/tmp` Not Mounted as tmpfs

The default Debian rootfs tarball does not mount `/tmp` as a tmpfs. All writes to `/tmp` fall through to the SD card ext4 partition, which has significantly higher latency than memory (SD card random-write IOPS are orders of magnitude lower than RAM). Applications such as Chromium that write socket files and temporary data to `/tmp` are affected.

**Symptom:** `findmnt /tmp` returns nothing; `df -Th /tmp` shows `Filesystem: /dev/root, Type: ext4`.

**Fix:** A corrected `etc/fstab` is provided in the rootfs overlay at `board-support/rootfs-overlay/etc/fstab`. The added line is:

```
tmpfs    /tmp    tmpfs    nosuid,nodev,size=50%    0    0
```

`size=50%` allocates up to half of available RAM for `/tmp` (≈ 690 MB on the 2 GB board, ≈ 1.9 GB on the 4 GB board), matching the systemd `tmp.mount` default. The `install_rootfs_overlay` step in the flash tool applies this file automatically during flashing — no manual tarball repacking is required.

---

## 6. Partition Layout

Both online flashing and offline image creation produce identical partition layouts:

| Partition | Number | Filesystem | Size | Label | Contents |
|-----------|--------|------------|------|-------|----------|
| BOOT | 1 | FAT32 (LBA) | 256 MiB | `BOOT` | Bootloader, kernel image, DTBs, extlinux config |
| rootfs | 2 | ext4 | Remaining | `rootfs` | Root filesystem, kernel modules |

Partition table type: **MBR** (Master Boot Record)

### BOOT Partition Contents

After flashing, the BOOT partition contains:

```
BOOT/
├── tiboot3.bin          # R5 SPL (first-stage bootloader)
├── tispl.bin            # TI SPL (OP-TEE + TF-A + A53 U-Boot)
├── u-boot.img           # A53 U-Boot FIT image
├── Image                # Linux kernel image
├── ti/                  # Device tree blobs directory
│   ├── k3-am62a7-mo-62a.dtb
│   └── ...              # Additional TI DTBs and DTBOs
└── extlinux/
    └── extlinux.conf    # U-Boot extlinux boot configuration
```

### Boot Configuration

U-Boot uses the extlinux boot flow to load the kernel. The default `extlinux/extlinux.conf`:

```
menu title mo-62a MicroSD (extlinux.conf)

timeout 30
default microSD

# 40-pin GPIO mode (default): all expansion pins as plain GPIO
label microSD
  append console=ttyS2,115200n8 earlycon=ns16550a,mmio32,0x02800000 root=/dev/mmcblk1p2 rw rootfstype=ext4 rootwait
  kernel /Image
  fdt    /ti/k3-am62a7-mo-62a.dtb
  # initrd /initrd.img

# 40-pin peripheral mode: enable WKUP_I2C0 / UART5 / SPI0 / EHRPWM0 / MCASP2
label microSD-periph
  append console=ttyS2,115200n8 earlycon=ns16550a,mmio32,0x02800000 root=/dev/mmcblk1p2 rw rootfstype=ext4 rootwait
  kernel /Image
  fdt    /ti/k3-am62a7-mo-62a.dtb
  fdtoverlays /ti/k3-am62a7-mo-62a-exp-periph.dtbo
  # initrd /initrd.img
```

The kernel command line sets:
- Serial console: `ttyS2` at 115200 baud
- Root device: `/dev/mmcblk1p2` (partition 2 on the SD/MMC device)
- Root filesystem type: `ext4`

Two boot labels are provided. `microSD` is the default — all 40-pin header pins are plain GPIO. Select `microSD-periph` at the U-Boot boot menu (or set `default microSD-periph` in `extlinux.conf`) to apply the peripheral mode overlay, which enables WKUP\_I2C0, UART5, SPI0, EHRPWM0, and MCASP2 on the expansion header.

---

## 7. Hardware Reference

> Source: `doc/Mo_62a_s_mb_v10-260203.pdf` (schematic Rev V1.0, 22 sheets)

### 7.1 Block Diagram Overview

The MO-62A is built around the **TI AM62A74** SoC. The top-level block diagram connects the following subsystems:

| Subsystem | Key IC | SoC Interface |
|-----------|--------|---------------|
| Power Management | TPS65931211 (PMIC) | SOC_I2C0 |
| eMMC Storage | — | MMC0 |
| LPDDR4 Memory | MT53E1G32D2FW-046 | DDR32 (32-bit) |
| Micro SD Card | — | MMC1 |
| RGB-to-HDMI Transmitter | SiI9022ACNU | RGB888 + MCASP0 + SOC_I2C1 |
| Gigabit Ethernet PHY | DP83867IR | RGMII1 + MDIO |
| USB Hub (4-port) | USB2514 | USB1 |
| Wi-Fi / BT | FG6221ASRC-0L | MMC2 (SDIO) + SOC_UART6 |
| RTC | PCF85263ATL | SOC_I2C0 |
| Audio Codec | TLV320AIC3106 | MCASP1 + SOC_I2C1 |
| EEPROM | BL24C02 (M24M02E) | SOC_I2C1 |
| CSI Camera | — | CSI0 (4-lane MIPI) + SOC_I2C2 |
| 40-Pin Expansion | — | GPIO / I2C / SPI / UART / PWM / MCASP |
| Fan Controller | TXB0104RUTR (voltage translation) | PWM + TIMER |
| Debug UART | SN74LVC2G24DCUR (isolation) | SOC_UART0 |

---

### 7.2 Power System

**Input:** USB Type-C, 5 V, maximum 6.38 A total.

**Power rails and distribution:**

| Rail | Source | Typical Current | Consumers |
|------|--------|-----------------|-----------|
| VCC_3V3_MAIN | DCDC 6 A (TPS62A63RLR) | 6 A max | System 3.3 V backbone |
| VCC_3V3_SYS | LDSW 4 A (TPS22965) | 957 mA | USB Hub, Wi-Fi/BT, Audio Codec, Ethernet PHY, HDMI TX, RTC |
| VSYS_3V3_EXP | Load Switch 4 A (TPS22965) | — | 40-pin, CSI FPC, Micro SD |
| VDD_CORE | PMIC Buck (3.5 A) | — | SoC core |
| VDD_LPDDR4 | PMIC Buck (3.5 A) | — | LPDDR4 |
| SOC_DVDD1V8 | PMIC Buck (4 A) | — | SoC 1.8 V I/O |
| VCC1V8_SYS_SW | PMIC Buck (2 A) | 200 mA | LPDDR4 auxiliary |
| VDD_2V5 | LDO (TPS74801DRCR, 1.5 A) | 325 mA | Ethernet PHY VDDA2P5 |
| VDD_1V0 | LDO (TLV75510PDQN) | 108 mA | Ethernet PHY VDD1P0 |
| VDD_1V2 | LDO (TLV75512PDQN) | 80 mA | HDMI TX VDD1P2 |
| VDD_CANUART | LDO (FLV70S07SYP) | 10 mA | CAN / UART I/O |

**Status LEDs (driven by MCU GPIO):**

| LED | Color | GPIO Signal |
|-----|-------|-------------|
| POWER | Red | B9 / MCU_GPIO0_16 / PWR_LED |
| STATUS | Green | D7 / MCU_GPIO0_15 / ACT_LED |

---

### 7.3 I2C Device Map

| SoC Bus | Device | Address(es) |
|---------|--------|-------------|
| SOC_I2C0 | PMIC TPS65931211 | 0x48 / 0x49 / 0x5A / 0x5B |
| SOC_I2C0 | RTC PCF85263ATL | 0x51 |
| SOC_I2C1 | Audio Codec TLV320AIC3106 | 0x1B |
| SOC_I2C1 | HDMI TX SiI9022ACNU | 0x3B / 0x3F / 0x62 |
| SOC_I2C1 | EEPROM BL24C02 | 0x50 ¹ |
| SOC_I2C2 | CSI FPC | — |
| SOC_I2C2 | EXP 40-Pin (SDA1/SCL1) | — |
| MCU_I2C0 | PMIC (secondary I2C) | — |

> ¹ The EEPROM hardware is present at 0x50, but the `eeprom@50` DTS node is not enabled in the kernel device tree. The SiI9022A HDMI transmitter uses the same I2C address (0x50) for EDID DDC access via its internal I2C bypass; enabling both simultaneously causes bus conflicts. See [Section 10](#10-eeprom) for details.

---

### 7.4 Memory

**LPDDR4 (MT53E1G32D2FW-046)**

| Item | Value |
|------|-------|
| Bus width | 32-bit |
| Configuration | Single channel, 32-bit |
| SoC interface | DDR0 (full 32-bit data bus) |
| Power | VDD_LPDDR4 (1.1 V), SOC_DVDD1V8 |
| Reset pull-down | R120, 10 kΩ (populated) |

**EEPROM (BL24C02F)**

| Item | Value |
|------|-------|
| Package | SOT23-5 |
| Interface | I2C (SOC_I2C1) |
| Address | 0x50 |
| Write protect | GPIO: C19/GPIO1_7/EEP_WC (active-high; pulled high via R267 10 kΩ — write-protected by default when driver not loaded) |

> The `eeprom@50` DTS node is currently removed. See [Section 10](#10-eeprom).

---

### 7.5 Storage

**eMMC**

- Interface: MMC0 (8-bit, JEDC eMMC electrical standard v5.1 / JESD84-B51)
- I/O voltage: 1.8 V (VDDSHV4)

**Micro SD Card**

- Interface: MMC1 (4-bit, UHS-I capable with 3.3 V / 1.8 V switching)
- I/O voltage: 3.3 V (VDDSHV5) / 1.8 V switched
- Load switch with reset logic for UHS-I voltage switching
- Connector: Micro SD (MUF-MB4)

---

### 7.6 Display — Micro HDMI

**RGB-to-HDMI Transmitter: SiI9022ACNU**

| Item | Value |
|------|-------|
| SoC video interface | VOUT0_DATA[0..15], VOUT0_PCLK, VSYNC, HSYNC, DE (parallel RGB) |
| SoC audio interface | MCASP0 (ACLKX, AFSX, AXR2) |
| I2C control | SOC_I2C1 (0x3B / 0x3F / 0x62) |
| Reset GPIO | AA19/GPIO0_89/HDMI_RSTn |
| Output connector | Micro HDMI (J7) |
| ESD protection | ESD7304D (×2 groups) |
| Power | VDD_1V2 (1.2 V), VCC_3V3_SYS |

---

### 7.7 Networking — Gigabit Ethernet](#77-networking--gigabit-ethernet)

**Ethernet PHY: DP83867CSRGZR**

| Item | Value |
|------|-------|
| Interface | RGMII1 (1 Gbps) |
| PHY address | 0x00 |
| Auto-negotiation | Enabled, Auto-MDI-X |
| TX clock skew | 0 ns |
| RX clock skew | 2 ns |
| MDIO | SoC_RGMII_MDC / MDO |
| Crystal | Y8, 25 MHz / 2016 / 30 ppm / 12 pF |
| Power | VDDA2P5 = 2.5 V, VDD1P0 = 1.0 V, VDD1P2 = 1.2 V |
| Connector | RJ45 with integrated magnetics (LPJG4928HENL) |
| PoE header | J5 (2×2, 2.54 mm pitch) |
| Link LED | Left (green) |
| Activity LED | Right (yellow) |

---

### 7.8 USB

**USB Hub: USB2514 (USB2514BQFN36)**

| Item | Value |
|------|-------|
| Upstream port | 1× USB 2.0 (from SoC USB1) |
| Downstream ports | 4× USB 2.0 Type-A |
| Power switch | TPS2561DRC, Ilimit = 2800 mA |
| VBUS supply | VBUS_5V0_TYPEA (from 5 V input via SW 2 A) |
| Current per port | Up to 2 A total for all 4 ports |

**USB Type-C (J31)**

- USB 2.0 only (USB0)
- Powers the board (VIN-5V)
- ESD protection: TVS05000RV

---

### 7.9 Wireless — Wi-Fi / Bluetooth

**Module: FG6221ASRC-0L (6221A-SRC)**

| Item | Value |
|------|-------|
| Wi-Fi interface | MMC2 (SDIO 4-bit, 1.8 V) |
| BT interface | SOC_UART6 (with CTS/RTS, 1.8 V) |
| Enable — Wi-Fi | EN_WLAN (F22/GPIO0_71/WLAN_EN/1V8) |
| Enable — BT | EN_BT (K22/GPIO0_1/BT_EN/1V8) |
| Interrupt | INT_WLAN (E21/GPIO0_72/WLAN_IRQ/1V8) |
| Antenna connector | U.FL × 1 (CON1) |
| Supply | SOC_DVDD1V8 (1.8 V), VCC_3V3_SYS (3.3 V) |

**Regulatory Database**

The kernel is compiled with the `sforshee` and `wens` X.509 public keys and can only
verify the upstream-signed `regulatory.db`. The rootfs is pre-configured so that
`update-alternatives` auto mode selects `/lib/firmware/regulatory.db-upstream` as the
active database (the Debian-signed variant is removed). This eliminates the
`cfg80211: loaded regulatory.db is malformed` boot message and ensures all
`wireless-regdb` package upgrades continue to work correctly.

---

### 7.10 Audio

**Audio Codec: TLV320AIC3106IRGZ**

| Item | Value |
|------|-------|
| I2S interface | MCASP1 (ACLKX_BUF, AFSX_BUF, AXR0_BUF, AXR2_BUF) |
| I2C control | SOC_I2C1, address 0x1B |
| MCLK | 12.288 MHz crystal oscillator (25 ppm, 3.3 V) |
| Reset GPIO | W18/GPIO0_1/AUD_RSTn |
| Headphone output | HPLOUT / HPROUT (stereo) |
| Microphone input | MIC_IN (LINE IN) |
| 3.5 mm jack (J8) | Pin 1: L — Pin 2: MIC — Pin 3: GND — Pin 4/5: HPROUT/HPLOUT |
| Wiring standard | 国标 (CTIA): L / R / GND / MIC |

---

### 7.11 RTC

**RTC IC: PCF85263ATL**

| Item | Value |
|------|-------|
| Interface | SOC_I2C0, I2C 7-bit address 0x51 (0b0101001) |
| Crystal | Y1, SSP-T7-F, 32.768 kHz, 20 ppm, 12.5 pF load |
| Battery connector | J2 (SH1.0-2p, 3 V button cell) |

---

### 7.12 Expansion Interfaces

#### 7.12.1 40-Pin Header (J9 — USER EXPN)

The 40-pin expansion header (silk: USER EXPN) provides GPIO signals at **3.3 V logic levels**. All user-accessible signal pins default to GPIO mode. Optional peripheral functions (I2C, SPI, UART, PWM) can be enabled via device tree overlay.

> **Note:** Pins 27/28 (I2C2) are permanently assigned to the internal I2C bus used by the camera module and cannot be used as general GPIO.

| Pin | Name        | Default Function        | gpiochip  | Line | Optional Function    |
|-----|-------------|-------------------------|-----------|------|----------------------|
|  1  | 3V3         | 3.3 V power             | —         | —    | —                    |
|  2  | 5V          | 5 V power               | —         | —    | —                    |
|  3  | GPIO2       | GPIO (MCU\_GPIO0\_20)   | gpiochip0 | 20   | WKUP\_I2C0\_SDA      |
|  4  | 5V          | 5 V power               | —         | —    | —                    |
|  5  | GPIO3       | GPIO (MCU\_GPIO0\_19)   | gpiochip0 | 19   | WKUP\_I2C0\_SCL      |
|  6  | GND         | Ground                  | —         | —    | —                    |
|  7  | GPIO4       | GPIO (GPIO0\_39)        | gpiochip1 | 39   | —                    |
|  8  | GPIO14      | GPIO (GPIO1\_25)        | gpiochip2 | 25   | UART5\_TXD           |
|  9  | GND         | Ground                  | —         | —    | —                    |
| 10  | GPIO15      | GPIO (GPIO1\_24)        | gpiochip2 | 24   | UART5\_RXD           |
| 11  | GPIO17      | GPIO (GPIO1\_23)        | gpiochip2 | 23   | —                    |
| 12  | GPIO18      | GPIO (GPIO1\_0)         | gpiochip2 |  0   | MCASP2\_ACLKX        |
| 13  | GPIO27      | GPIO (GPIO0\_42)        | gpiochip1 | 42   | —                    |
| 14  | GND         | Ground                  | —         | —    | —                    |
| 15  | GPIO22      | GPIO (GPIO1\_22)        | gpiochip2 | 22   | —                    |
| 16  | GPIO23      | GPIO (GPIO0\_38)        | gpiochip1 | 38   | —                    |
| 17  | 3V3         | 3.3 V power             | —         | —    | —                    |
| 18  | GPIO24      | GPIO (GPIO0\_40)        | gpiochip1 | 40   | —                    |
| 19  | GPIO10      | GPIO (GPIO1\_18)        | gpiochip2 | 18   | SPI0\_D0 (MOSI)      |
| 20  | GND         | Ground                  | —         | —    | —                    |
| 21  | GPIO9       | GPIO (GPIO1\_19)        | gpiochip2 | 19   | SPI0\_D1 (MISO)      |
| 22  | GPIO25      | GPIO (GPIO0\_14)        | gpiochip1 | 14   | —                    |
| 23  | GPIO11      | GPIO (GPIO1\_17)        | gpiochip2 | 17   | SPI0\_CLK            |
| 24  | GPIO8       | GPIO (GPIO1\_15)        | gpiochip2 | 15   | SPI0\_CS0            |
| 25  | GND         | Ground                  | —         | —    | —                    |
| 26  | GPIO7       | GPIO (GPIO1\_16)        | gpiochip2 | 16   | SPI0\_CS1            |
| 27  | I2C2\_SDA   | I2C2 SDA (`i2c-2`)     | —         | —    | (camera bus, fixed)  |
| 28  | I2C2\_SCL   | I2C2 SCL (`i2c-2`)     | —         | —    | (camera bus, fixed)  |
| 29  | GPIO5       | GPIO (GPIO0\_36)        | gpiochip1 | 36   | —                    |
| 30  | GND         | Ground                  | —         | —    | —                    |
| 31  | GPIO6       | GPIO (GPIO0\_33)        | gpiochip1 | 33   | —                    |
| 32  | GPIO12      | GPIO (GPIO1\_14)        | gpiochip2 | 14   | EHRPWM0\_B           |
| 33  | GPIO13      | GPIO (GPIO1\_13)        | gpiochip2 | 13   | EHRPWM0\_A           |
| 34  | GND         | Ground                  | —         | —    | —                    |
| 35  | GPIO19      | GPIO (GPIO0\_91)        | gpiochip1 | 91   | MCASP2\_AFSX         |
| 36  | GPIO16      | GPIO (GPIO1\_9)         | gpiochip2 |  9   | EHRPWM1\_A           |
| 37  | GPIO26      | GPIO (GPIO0\_41)        | gpiochip1 | 41   | —                    |
| 38  | GPIO20      | GPIO (GPIO1\_5)         | gpiochip2 |  5   | MCASP2\_AXR0         |
| 39  | GND         | Ground                  | —         | —    | —                    |
| 40  | GPIO21      | GPIO (GPIO1\_2)         | gpiochip2 |  2   | MCASP2\_AXR1         |

> `gpiochip0` = `mcu_gpio0` (MCU domain).  `gpiochip1` = `main_gpio0` (GPIO0\_x).  `gpiochip2` = `main_gpio1` (GPIO1\_x).

##### Peripheral Mode — 40-Pin DT Overlay

Optional peripheral functions are enabled by booting with the `microSD-periph` extlinux label. This applies the `k3-am62a7-mo-62a-exp-periph.dtbo` overlay, which activates the following interfaces:

| Interface | Pins | Linux device |
|-----------|------|--------------|
| WKUP\_I2C0 | 3 (SDA), 5 (SCL) | `/dev/i2c-0` |
| UART5 | 8 (TXD), 10 (RXD) | `/dev/ttyS3` |
| SPI0 | 19 (MOSI), 21 (MISO), 23 (CLK), 24 (CS0), 26 (CS1) | `/sys/bus/spi/devices/spi0.*` (no `spidev` node by default) |
| EHRPWM0\_A | 33 | `/sys/class/pwm/pwmchip0/pwm0` |
| EHRPWM0\_B | 32 | `/sys/class/pwm/pwmchip0/pwm1` |
| MCASP2 | 12 (ACLKX), 35 (AFSX), 38 (AXR0), 40 (AXR1) | no soundcard (no codec binding) |

> When peripheral mode is active, I2C bus numbering shifts: `i2c-0` = WKUP\_I2C0 (expansion pins 3/5), `i2c-1` = main\_i2c0, `i2c-2` = main\_i2c1 (HDMI), `i2c-3` = main\_i2c2 (camera).

To switch back to GPIO mode, reboot and select the `microSD` label at the U-Boot menu.

#### 7.12.2 FPC 22-Pin CSI Camera (JP1)

| Item | Value |
|------|-------|
| Connector | FPC22 / 0.5 mm pitch (JP1) |
| Standard | 22-pin CSI camera connector, 4-lane MIPI CSI-2 |
| Lanes | CSI0_RXP/N[0..3] + CSI0_RXCLKP/N |
| I2C | CSI_I2C2_SDA/SCL (from SOC_I2C2) |
| Power | VSYS_3V3_EXP |
| Enable / Power-down | CSI0_PWDN (Y19/GPIO0_87) |
| Calibration | CSI0_RXRCALIB (499 Ω to GND) |

#### 7.12.3 Fan Connector (J6)

| Item | Value |
|------|-------|
| Connector | SH1.0-4p |
| PWM control | FAN_PWM (via TXB0104RUTR voltage translation) |
| Tach feedback | FAN_TACH |
| SoC signals | PWM (D18/TIMER_IO7), TACH (D1/ID1_10/EHRPWM1_B) |

---

### 7.13 Debug Interface

**Debug UART (J4 — SH1.0-3p)**

UART0 is the MPU debug UART. A SN74LVC2G24DCUR provides voltage isolation.

| Pin | Signal |
|-----|--------|
| 1 | UART0_RXD |
| 2 | GND |
| 3 | UART0_TXD |

Baud rate: 115200 8N1 (matches kernel console on `ttyS2`).

---

### 7.14 Boot Configuration

The MO-62A uses a fixed resistor boot mode configuration (BOOTMODE[15:0]).

**Configured boot modes:**

| Priority | Mode | Description |
|----------|------|-------------|
| Primary | SD CARD (MMC1) | 4-bit MMC SD card boot |
| Backup | Ethernet | Network boot fallback |

**BOOTMODE register settings (as configured by resistors):**

| Bits | Value | Meaning |
|------|-------|---------|
| BOOTMODE[2:0] | 011 | 25 MHz PLL input frequency |
| MCU_BOOTMODE[6:3] | 1000 | Primary boot = MMCSD (SD Card) |
| MCU_BOOTMODE[9:7] | B8=1, B7=0 | MMC Port 1, 4-bit width |
| MCU_BOOTMODE[12:10] | 100 | Backup boot = Ethernet |

**All supported boot modes (per silicon):**

1. OSPI
2. MMC1 — SD Card
3. UART
4. eMMC
5. Ethernet
6. USB0 DFU
7. USB0 MS

---

### 7.15 JTAG Interface

| Signal | Description |
|--------|-------------|
| SoC_EMU0 / SoC_EMU1 | Emulation pins |
| SoC_TCK | JTAG clock |
| SoC_TMS | JTAG mode select |
| SoC_TDI | JTAG data in |
| SoC_TDO | JTAG data out |
| SoC_TRSTN | JTAG reset |

Pull-up resistors: 4.7 kΩ to VCC_3V3_SYS.

---

### 7.16 Hardware Revision Straps

Three hardware revision pins (HW_REV0, HW_REV1, HW_REV2) are routed to the OSPI interface page (sheet 9). These PCB strap resistors (DNF by default) allow encoding the PCB revision and DDR model in hardware for software detection.

---

## 8. Display — DPMS Screen Blanking and Wake

The MO-62A supports automatic display blanking via DPMS (Display Power Management Signaling) and reliable wake-on-input from the blanked state. This required fixes across five layers of the software stack; all are included in the SDK and active after a normal flash.

### How It Works

When the display has been idle for 10 minutes the X server issues a DPMS Off command. SiI9022A cuts the HDMI TMDS link. After a 1-second autosuspend delay the AM62A DISPC hardware is power-cycled by the Linux runtime PM subsystem.

On any keyboard or mouse input:

1. `dpms-wakeup` detects the `/dev/input/event*` activity and calls `xset dpms force on`
2. The X server issues a DRM atomic commit to bring the CRTC back to active
3. The DISPC hardware powers back on; `dispc_runtime_resume()` re-initialises all registers
4. The SiI9022A 20 ms TMDS PLL stabilisation delay runs, then HDMI output is restored
5. `tidss_plane_atomic_update()` re-enables the VID pipeline so pixel data reaches the display

### Fixes Applied

| # | Layer | Root Cause | Fix |
|---|-------|-----------|-----|
| 1 | `drivers/gpu/drm/bridge/sii902x.c` | 20 ms TMDS PLL delay was gated on `mode.clock`, which is 0 after a module reload — PLL never locked, HDMI stayed dark | Delay moved unconditionally before `PWR_DWN` clear; CRTC state fallback added for `mode.clock = 0` |
| 2 | `rootfs-overlay/usr/local/bin/dpms-wakeup` | Xorg does not automatically call `xset dpms force on` when raw input arrives while DPMS is Off | Python daemon watches all `/dev/input/event*` nodes, calls `xset dpms force on` on activity (2 s cooldown) |
| 3 | `rootfs-overlay/etc/udev/rules.d/72-seat-input.rules` | USB input devices not tagged `ID_SEAT=seat0` — logind excludes them because the USB hub parent differs from the DSS/DRM parent | udev rules explicitly set `ID_SEAT=seat0` and `TAG+="seat"` for all recognised input device types |
| 4 | `rootfs-overlay/etc/xdg/autostart/xfce4-power-manager.desktop` | xfce4-power-manager 4.20.0 polls the XSS idle counter and re-blanks the display ~1 s after wake due to a race with the idle-counter reset | `Hidden=true` suppresses xfce4-power-manager autostart; DPMS fully managed by the X server |
| 5 | `drivers/gpu/drm/tidss/tidss_plane.c` | `dispc_initial_config()` resets `DISPC_VID_ATTRIBUTES` bit 0 (VID enable) to 0 on resume; DRM skips `atomic_enable()` because the plane is already bound to the CRTC | `dispc_plane_enable(true)` added inside `tidss_plane_atomic_update()` whenever the plane is visible |

### DPMS Configuration

The X server DPMS settings are applied at XFCE session start by `enable-dpms.desktop` (rootfs overlay: `etc/xdg/autostart/enable-dpms.desktop`):

```bash
xset +dpms              # Enable DPMS
xset dpms 0 0 600       # Off after 600 s idle; Standby/Suspend disabled
xset s off              # Disable the X screensaver
xset s noblank          # Disable X screen blanking
dpms-wakeup &           # Start the input-event wakeup daemon
```

To change the blank timeout, edit the `600` value in the rootfs overlay and reflash.

### Verifying DPMS from an SSH Session

```bash
# Check current DPMS state and timer settings
DISPLAY=:0 XAUTHORITY=/home/debian/.Xauthority xset q | grep -A3 DPMS

# Blank the display immediately (test)
DISPLAY=:0 XAUTHORITY=/home/debian/.Xauthority xset dpms force off

# Wake the display (test)
DISPLAY=:0 XAUTHORITY=/home/debian/.Xauthority xset dpms force on
```

---

## 9. S1 Power Button

The S1 button is connected to the `NPWRON` pin of the TPS6593-Q1 PMIC (I²C bus 0, address 0x48). The SDK implements a complete software stack that provides three hold-duration actions.

### Behaviour

| Event | Action | Notes |
|-------|--------|-------|
| Press | XFCE4 shutdown dialog | Appears immediately while button is still held |
| Release before 5 s | Dialog stays open | User can choose from dialog options |
| Hold ≥ 5 s | `systemctl poweroff` | Dialog bypassed; poweroff forced |
| Hold ~7 s | PMIC hardware forced shutdown | FSD — hardware safety, not software-controlled |
| After soft poweroff | Short S1 press restarts system | PMIC switched to ENABLE mode by reboot notifier |

This matches standard Ubuntu laptop power-button behaviour.

When no XFCE session is active (e.g. device is at the login screen), the dialog step is silently skipped — the 5 s poweroff timer still fires normally.

After `systemctl poweroff`, the kernel reboot notifier switches the PMIC `NPWRON_SEL` register back to ENABLE mode (`00`). This restores the default power-on behaviour so that a short S1 press can restart the system without requiring a power-cycle on the USB-C connector.

### Software Stack

| Component | Location | Role |
|-----------|----------|------|
| Kernel driver | `drivers/mfd/tps6594-core.c` | Configures `NPWRON_SEL = 01` (button mode); registers `NPWRON_START` IRQ; reports `KEY_POWER` events via `tps6594-pwrbutton` input device; reboot notifier switches back to ENABLE mode on poweroff |
| `s1-powerkey` daemon | `/usr/local/bin/s1-powerkey` | Python daemon that reads `KEY_POWER` events from `/dev/input/eventN` and fires `threading.Timer` callback at 5 s |
| systemd service | `/etc/systemd/system/s1-powerkey.service` | Starts the daemon at boot (`WantedBy=multi-user.target`); `Restart=always` |
| logind override | `/etc/systemd/logind.conf.d/s1-powerkey.conf` | Sets `HandlePowerKey=ignore` and `HandlePowerKeyLongPress=ignore` so logind does not consume `KEY_POWER` events before the daemon |

### PMIC Hardware Safety (FSD)

The TPS6593-Q1 has a hardware Forced Shutdown Device (FSD) timer: if S1 is held for approximately 7 seconds in button mode, the PMIC cuts all power rails regardless of software state. After an FSD event, a short S1 press restarts the system normally.

Because our 5 s software poweroff fires before the 7 s FSD threshold, and the reboot notifier switches `NPWRON_SEL` back to ENABLE mode during the shutdown sequence, the FSD timer is no longer running by the time the system goes fully off. The FSD remains as a last-resort safety mechanism if the software-initiated poweroff stalls.

### Verifying from an SSH Session

```bash
# Check service status
systemctl status s1-powerkey

# Watch live KEY_POWER events
sudo evtest /dev/input/event0

# Follow daemon log
journalctl -u s1-powerkey -f
```

---

## 10. EEPROM

The MO-62A carries a **BL24C02F** 2 Kbit (256-byte) I2C EEPROM on SOC_I2C1 (address 0x50). It is intended for board identity storage — serial number, hardware revision, MAC address seed, or other persistent metadata.

### Hardware

| Item | Value |
|------|-------|
| IC | BL24C02F (SOT23-5, compatible with Atmel 24C02) |
| Interface | SOC_I2C1, 7-bit address 0x50 |
| Capacity | 256 bytes, page size 16 bytes |
| Write protect | WP pin (GPIO1_7 / C19 / EEP_WC), active-high, pulled to VCC_3V3_SYS via R267 (10 kΩ) |

### I2C Address Conflict with SiI9022A

The BL24C02F shares I2C address **0x50** with the SiI9022A HDMI transmitter's internal EDID DDC bypass register. When the SiI9022A is in DDC-bypass mode, it responds to I2C transactions at 0x50 on SOC_I2C1 to expose the downstream monitor's EDID data. Enabling both the EEPROM driver and the SiI9022A DDC bypass simultaneously causes bus conflicts and prevents stable HDMI operation.

For this reason, the `eeprom@50` DTS node is **not included** in the current device tree (`k3-am62a7-mo-62a.dts`), and the GPIO1_7 pin (EEP_WC) is left as `PIN_INPUT` (write-protected via R267 pull-up). `CONFIG_EEPROM_AT24` is still compiled as a module, but no `at24` device is enumerated at boot.

To enable EEPROM access (e.g. during production programming), add the `eeprom@50` node back to the device tree and drive GPIO1_7 low to disable write protection. Ensure no HDMI display is connected during this operation to avoid I2C bus conflicts.

### Reading and Writing (when DTS node is enabled)

```bash
# Read all 256 bytes (hex + ASCII)
hexdump -C /sys/bus/i2c/devices/1-0050/eeprom

# Write a serial number string starting at byte 0
printf "MO-62A-SN001" | sudo dd of=/sys/bus/i2c/devices/1-0050/eeprom \
    bs=1 seek=0 conv=notrunc

# Write a single byte (e.g. hardware revision = 0x01) at offset 16
printf "\x01" | sudo dd of=/sys/bus/i2c/devices/1-0050/eeprom \
    bs=1 seek=16 conv=notrunc
```

> **Note:** The BL24C02F has a 16-byte page write buffer. Writes that cross a page boundary are split automatically by the `at24` driver. A 5 ms write cycle time is enforced per page.

---

## 11. MO-62A Automated Test Tool

`tools/mo62a-tester/` is a Python-based GUI tool for automated hardware acceptance testing of MO-62A boards over SSH.

### Features

- SSH connection to the device via LAN (IP entry or UDP auto-discovery via the `mo-discover` daemon)
- First-boot password change flow (detects the default `temppwd` password and prompts for a new one)
- Test item selection with tristate category checkboxes and English / Chinese UI
- Parallel test execution with live pass / fail / info status display
- HTML report export

### Requirements

```
Python 3.8+
paramiko
```

Install dependencies:

```bash
pip install -r tools/mo62a-tester/requirements.txt
```

### Usage

```bash
python3 tools/mo62a-tester/main.py
```

Connect to the device on the **Connect** page, select test items on the **Select** page, then run tests on the **Run** page.

### Test Categories

| Category | Coverage |
|----------|----------|
| System Basics | Firmware version, kernel version, DTB/overlays, OS version, hostname, uptime, filesystem usage, memory, CPU cores, CPU frequency (from OPP table), CPU temperature, Ethernet MAC address |
| LEDs | Power LED and Status LED GPIO control |
| Fan | PWM fan speed control and tachometer feedback |
| RTC | PCF85263A time read/write |
| I2C | Bus enumeration, device presence check |
| HDMI | Display mode and connector state |
| Audio | Codec detection, playback/capture |
| Camera | CSI pipeline, device node presence |
| Network | Ethernet link, IP assignment, connectivity |
| USB | Hub enumeration, port detection |
| GPIO | 40-pin header GPIO toggling |
| Services | systemd service states |

### Device-side Daemon

The `mo-discover` UDP daemon (installed to `/usr/local/bin/mo-discover`, managed by `mo-discover.service`) listens on UDP port 47622 and responds to broadcast discovery packets from the test tool. This allows the tool to find devices on the LAN without knowing their IP addresses in advance.
