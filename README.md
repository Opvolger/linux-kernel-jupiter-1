# Milk-V Jupiter (SpacemiT K1) with an AMD graphics card on mainline Linux

Patches and a build setup to get an AMD graphics card (tested: R9 290/390, "Hawaii") working over
PCIe on a [Milk-V Jupiter](https://milkv.io/jupiter) with the SpacemiT K1 RISC-V SoC, on a
**mainline** Linux kernel. Result: Debian 13 (trixie) running KDE Plasma 6 (Wayland) on the AMD
card, without rendering artifacts.

More background on my [blog](https://opvolger.github.io/) and
[GitHub](https://github.com/Opvolger/Opvolger).

> This project was made with the help of [Claude](https://claude.ai) (Anthropic): the kernel
> changes, the investigation in [milk-v-testing.md](milk-v-testing.md) and the scripts were
> created together with Claude Code and tested on the real hardware.

## Why are patches needed?

Mainline Linux supports the K1 and its PCIe controller, but a big GPU runs into several problems:

| Problem | Fix |
| --- | --- |
| PCIe driver can't find the root port (`-ENODEV`) once the device tree has an INTx node | look up the root port by `device_type = "pci"`, plus INTx support |
| Hawaii has 256 MB + 8 MB prefetchable BARs; the pcie2 window is only 256 MB | window enlarged to 264 MB (`k1.dtsi`) |
| PCIe DMA on the K1 is not cache-coherent: the GPU never sees the ring buffer (`ring gfx test failed`) | amdgpu: GTT write-combined on non-coherent devices |
| Write-combined VRAM: the GPU reads stale vertex data (triangles across the desktop) | amdgpu: VRAM BAR uncached on non-coherent devices |
| Misaligned access to uncached memory raises an *access fault* on the X60 cores → Xorg/SDDM crash | riscv: emulate such a fault as a misaligned access |
| RAM without a PCIe bus address is bounced through swiotlb | `reserved-memory` in the Jupiter dts (optional) |

The full story, with logs and what did *not* work, is in [milk-v-testing.md](milk-v-testing.md).

## Contents

```text
Makefile                check out the kernel, apply patches, build .debs (make help)
linux-7.2-patches/      patch series for Linux 7.2 (tested on the board)
linux-7.3-patches/      patch series for Linux 7.3 (tested on the board)
scripts/                kernel-tree.sh (check out + patch), export-patches.sh,
                        fetch-debian-config.sh + debian-defconfig.sh (Debian-based config)
configs/debian/         the Debian riscv64 kernel config the debian flavor is based on
milkv-tools/            board helpers: serial console, power, install, boot test, screen capture
.github/workflows/      GitHub Actions: builds all kernels, publishes a release for tags v*
AGENTS.md               short status and workflow (also for AI agents)
milk-v-testing.md       log of every attempt
```

Each patch series also adds three kernel configurations:

| Flavor | defconfig | Properties |
| --- | --- | --- |
| `builtin` | `k1_amdgpu_defconfig` | everything built in, GPU firmware inside the kernel, no initramfs needed |
| `modules` | `k1_amdgpu_modules_defconfig` | like a distribution kernel: modules + initramfs, firmware from `/lib/firmware` |
| `debian` | `k1_amdgpu_debian_defconfig` | everything the Debian riscv64 kernel enables (~3000 modules), minus other RISC-V SoCs; modules + initramfs |

## Building it yourself

Requirements on the build machine (Fedora example; for Debian/Ubuntu see the package list in
[.github/workflows/build.yml](.github/workflows/build.yml)):

```bash
sudo dnf install gcc-riscv64-linux-gnu make git flex bison bc perl \
                 openssl-devel elfutils-libelf-devel dpkg-dev debhelper fakeroot dwarves
```

`dwarves` (pahole) is needed by the `debian` flavor for BTF (and with it sched_ext and other
BPF features); without it those options silently drop out.

Then:

```bash
git clone <this repo> && cd linux-kernel-jupiter-1
make help
make deb-7.3-modules        # or deb-7.3-builtin, deb-7.3-debian, deb-7.3 (all three), all
```

What happens:

1. `.kernel.git/` is created (a blobless clone of the mainline kernel) and the tag `v7.3` is
   fetched. Different source? `make ... KERNEL_URL=<url>`. Only the tag, no history (much smaller
   download, used in CI): `make ... KERNEL_DEPTH=1`.
2. `linux-7.3/` becomes a git worktree on branch `jupiter-7.3`, and every patch from
   `linux-7.3-patches/` that is not applied yet is applied with `git am`.
3. `linux-firmware/` is cloned (only for the `builtin` flavor, which builds the GPU firmware into
   the kernel).
4. The kernel is built out of tree in `build/7.3-modules/obj` and the packages
   (`linux-image-7.3.0-k1-amdgpu-modules_7.3.0-1_riscv64.deb`, `linux-libc-dev_...`) end up in the
   repository root. Each following build automatically gets a higher package revision (or pass
   `PKGREV=n`). The `linux-headers` and `-dbg` packages are skipped (see `DEB_PROFILES` in the
   Makefile).

Build times on a 16-thread laptop: `builtin` and `modules` about 10–15 minutes each, `debian` about
50 minutes and ~31 GB of disk space in `build/` (it has debug info, like Debian's kernel).

Only the kernel files, no package: `make image-7.3-builtin` puts `Image-7.3.0-k1-amdgpu.gz`,
`k1-milkv-jupiter-7.3.0-k1-amdgpu.dtb` and `config-7.3.0-k1-amdgpu` in the repository root (see
*Booting the kernel image files*). The GitHub releases contain the same files.

## Installing on the board

Starting point: Debian 13 (riscv64) on the Jupiter's eMMC, with SpacemiT's U-Boot.

```bash
scp linux-image-7.3.0-k1-amdgpu-modules_7.3.0-1_riscv64.deb <board>:/tmp/
ssh <board> sudo apt install firmware-amd-graphics        # modules and debian flavors
ssh <board> sudo dpkg -i /tmp/linux-image-7.3.0-k1-amdgpu-modules_7.3.0-1_riscv64.deb
```

Boot the kernel with these bootargs (needed for CIK cards such as Hawaii):

```text
radeon.cik_support=0 amdgpu.cik_support=1
```

How to load kernel, initrd and dtb from U-Boot (by hand, or automatically through a `boot.scr`) is
described in [milk-v-testing.md](milk-v-testing.md), steps 13 and 15 and *Booting the installed
deb*. The scripts in `milkv-tools/` are written for my own setup (board address, Home Assistant
plug, HDMI capture); the board address can be changed with `BOARD=<ip>`, the rest via the variables
at the top of each script:

```bash
milkv-tools/test-kernel.sh linux-image-7.3.0-k1-amdgpu-debian_7.3.0-1_riscv64.deb \
    7.3.0-k1-amdgpu-debian      # install, switch boot.scr, reboot, check amdgpu, screenshot
milkv-tools/set-boot.sh 7.2.0-k1-amdgpu-modules    # boot another installed kernel next time
```

The first boot of a new `debian`-flavor kernel takes a few minutes longer: AppArmor (only enabled in
that config) compiles its profile cache once.

## Booting the kernel image files

The `builtin` kernel has everything it needs built in (ext4, MMC, USB, PCIe, amdgpu and the GPU
firmware), so `Image-<release>.gz` and `k1-milkv-jupiter-<release>.dtb` are enough: no modules, no
initramfs, no Debian package. Copy both to a partition U-Boot can read (FAT or ext4) on an SD card,
USB stick or the eMMC, and boot them from the U-Boot prompt (Ctrl-C during the boot menu):

```bash
setenv fdt_addr_r 0x31000000
# U-Boot numbering (SpacemiT U-Boot, checked with "mmc list"): SD card = mmc 0, eMMC = mmc 2
# (there is no mmc 1). USB: "usb start", then "usb 0:1".
load mmc 2:3 ${kernel_addr_r} /Image-7.3.0-k1-amdgpu.gz
load mmc 2:3 ${fdt_addr_r} /k1-milkv-jupiter-7.3.0-k1-amdgpu.dtb
setenv bootargs 'root=/dev/mmcblk0p1 rw rootwait swiotlb=131072 console=tty0 console=ttyS0,115200 earlycon radeon.cik_support=0 amdgpu.cik_support=1'
booti ${kernel_addr_r} - ${fdt_addr_r}
```

- `root=` must point at your root file system, with **Linux** numbering, which differs from
  U-Boot's: eMMC = `/dev/mmcblk0`, SD card = `/dev/mmcblk1` (here partition 1 of the eMMC,
  `/dev/mmcblk0p1`).
- `booti` decompresses the `.gz` itself through `kernel_comp_addr_r`/`kernel_comp_size`, which are
  already set in SpacemiT's U-Boot environment.
- To make it permanent, put these lines in a `boot.cmd`, turn it into a `boot.scr` with
  `mkimage -C none -A riscv -T script -d boot.cmd boot.scr` and let U-Boot run that
  (see [milk-v-testing.md](milk-v-testing.md), step 15).

## Changing the patches or moving to a new kernel

```bash
make checkout-7.3                    # linux-7.3/ with all patches as commits
# ... edit and commit in linux-7.3/ ...
make export-7.3                      # commits -> linux-7.3-patches/*.patch
```

New kernel version (for example 7.4):

```bash
cp -r linux-7.3-patches linux-7.4-patches
make checkout-7.4                    # on a conflict: resolve in linux-7.4/, git am --continue
scripts/kernel-tree.sh 7.4           # apply the remaining patches
make export-7.4 deb-7.4
```

The Makefile finds the versions by itself from the `linux-*-patches/` directories.

### Updating the Debian-based config

```bash
scripts/fetch-debian-config.sh       # newest Debian sid riscv64 config -> configs/debian/
make debian-defconfig-7.3            # regenerate k1_amdgpu_debian_defconfig in linux-7.3/
git -C linux-7.3 commit --amend -a   # it is the last patch (0012)
make export-7.3
```

The script switches off the other RISC-V SoC families (StarFive, SiFive, T-Head, Allwinner,
Sophgo, ...; the generic QEMU `virt` platform stays), sets the release name and module signing,
and lets options that are newer than the Debian kernel take their default value.

## GitHub Actions and releases

[.github/workflows/build.yml](.github/workflows/build.yml) builds every version × flavor on
GitHub-hosted runners (Ubuntu 24.04 with its riscv64 cross compiler):

- on pull requests that touch patches, configs, scripts or the Makefile, and by hand
  (*Actions → Build kernels → Run workflow*, optionally with fewer flavors);
- on a pushed tag `v*` it also creates a GitHub release with the `linux-image-*.deb` packages:

```bash
git tag v2026.10.19 && git push origin v2026.10.19
```

The versions come from the `linux-*-patches/` directories. The package revision is the workflow
run number. The `debian` flavor takes a few hours on a hosted runner (the job limit is 6 hours) and
needs most of the runner's disk, so the job first removes preinstalled SDKs.

## Status

| Kernel | Patches | Builds | Tested on the board |
| --- | --- | --- | --- |
| 7.2 | ✔ | ✔ builtin, modules, debian | ✔ all three (KDE Plasma without artifacts on 7.2 modules) |
| 7.3 | ✔ | ✔ builtin, modules, debian | ✔ all three (debian with the performance-governor fix, see below) |

On 19 Oct 2026 every kernel booted to a clean SDDM login screen with amdgpu working; the window
dragging test for artifacts was only done on 7.2 (see [milk-v-testing.md](milk-v-testing.md),
step 18).

**Known issues:**

- With the `schedutil` cpufreq governor (Debian's default) the K1 crashed during boot in about a
  quarter of the boots (garbage pointers, kernel Oops, once systemd itself, which froze the
  board). All three configs here therefore use the `performance` governor (fixed 1.6 GHz), which
  was stable in every test. Root cause not found yet; see
  [milk-v-testing.md](milk-v-testing.md), step 18. Release `v0.8.0` was built before this fix:
  use its `builtin`/`modules` packages, or a later release, for the `debian` flavor.
- An NVMe SSD in the M.2 slot (pcie1) is not detected ("Device found, but not active"), with or
  without these patches; see step 19.

Known limitations: CPU writes to VRAM are uncached and therefore slower; the `linux-headers` deb is
not built (cross-building it needs a riscv64 glibc); an HD 5450 (`radeon` driver) probably needs
similar changes.

## License

The kernel patches are, like the Linux kernel, licensed under GPL-2.0.
