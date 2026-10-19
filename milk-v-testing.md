# Milk-V testing

I have been trying for a while to get an AMD GPU working on a Milk-V Jupiter 1 board with the mainline Linux kernel. You can find more of my work on my [blogs](https://opvolger.github.io/) or [github](https://github.com/Opvolger/Opvolger).

## Server

On this machine I started a tftp server with docker, in the kernel's build directory
(e.g. `build/7.3-builtin/obj`, see step 16)

```bash
# --network host is required: tftp replies from a random port, which breaks with docker port mapping
docker run -d --name tftp --network host -v $(pwd):/var/tftpboot pghalliday/tftp
```

The firewall is temporarily disabled; this is on a safe home network.

## Kernel changes

This repo contains kernel changes for the Milk-V Jupiter 1 (K1); they were made by Claude.
They are kept as a patch series in `linux-<version>-patches/`; the `Makefile` checks out the kernel, applies the
patches and builds the packages (step 16). The build commands in steps 1–15 predate that
layout (kernel tree in `~/code/linux`, built in-tree) and are kept as history.

The goal is to get PCIe working better on the Milk-V Jupiter 1.

## Serial output of the Milk-V Jupiter 1

This machine has a serial connection to the Milk-V Jupiter 1. I use screen myself, but you can/may approach this differently

```bash
picocom --baud 115200 /dev/ttyUSB0
```

## Switching the Milk-V device off and on

The token can be found in the file `/home/opvolger/home-assistant.txt`

TOKEN='<your token>'
URL=http://192.168.2.202:8123/api/services/switch

*on / off / toggle*

```bash
curl -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"entity_id":"switch.zolder_sonoff_plug_1"}' $URL/turn_on     # or turn_off / toggle
```

## Log: what has been tried (17 Oct 2026)

### 1. TFTP from U-Boot

- `tftp ...` produced **no output at all** in this U-Boot (2022.10 SpacemiT) and loaded nothing.
  Use `tftpboot`, which does work:

```bash
setenv serverip 192.168.2.34
setenv fdt_addr_r 0x31000000          # fdt_addr_r does not exist in the env
tftpboot ${fdt_addr_r} ${serverip}:arch/riscv/boot/dts/spacemit/k1-milkv-jupiter.dtb
tftpboot ${kernel_addr_r} ${serverip}:arch/riscv/boot/Image.gz   # ~20 MiB/s
setenv bootargs 'root=/dev/mmcblk0p1 rw swiotlb=131072 console=tty0 console=ttyS0,115200 earlycon rootwait stmmaceth=chain_mode:1 selinux=0'
booti ${kernel_addr_r} - ${fdt_addr_r}
```

- With this the kernel (build from 31 Aug) boots all the way to the Debian login `sfvflite2 login:`.

### 2. PCIe: "failed to parse root port"

- In the boot log:

  ```text
  spacemit-k1-pcie ca400000.pcie: error -ENODEV: failed to parse root port
  spacemit-k1-pcie ca800000.pcie: error -ENODEV: failed to parse root port
  ```

  Because of this no PCIe device (and therefore no AMD GPU) is found.
- Cause: the change in `k1.dtsi` adds a child node `interrupt-controller` (INTx) per controller,
  **before** the `pcie@0` node. `k1_pcie_parse_port()` took the first child node with
  `of_get_next_available_child(np, NULL)`, and that is now the interrupt-controller. It has no `phys` → `-ENODEV`.
- Fix in `drivers/pci/controller/dwc/pcie-spacemit-k1.c`: look for the child node with `device_type = "pci"`
  (`for_each_available_child_of_node` + `of_node_is_type(..., "pci")`).

### 3. U-Boot: straight to the console instead of menu / network boot

What U-Boot does after power-on:

1. The board code does DHCP and tries to fetch `mac_mapping_file=/home/it/nfs/bianbu/mac_mapping.txt` via **NFS**
   from `serverip=10.0.92.148`. Those are SpacemiT default values and that server does not exist
   here, so this runs into timeouts (`T T T`). You can abort it with Ctrl-C.
2. After that: `bootdelay=0`, `bootcmd=run autoboot` → `boot_device=mmc` → `mmc_boot`; the menu has
   `bootmenu_delay=5`.

Settings (in the U-Boot console, followed by `saveenv`):

```bash
setenv serverip 192.168.2.34       # own tftp server instead of 10.0.92.148
setenv mac_mapping_file            # clear -> no NFS attempt (presumably, not tested yet)
setenv bootdelay 3                 # 3 s to interrupt with a key press
setenv bootcmd                     # empty -> no autoboot, straight to the => prompt
saveenv
```

With an empty `bootcmd` you land directly at the `=>` prompt. There you set the `bootargs` yourself and do
the `tftpboot`/`booti` steps from step 1, so you can adjust the boot arguments per test.

### 4. Switching power via Home Assistant

The board is connected to `switch.zolder_sonoff_plug_1`. With `turn_off`, waiting a few seconds and then
`turn_on`, the board does a cold restart (see *Switching the Milk-V device off and on*).

### 5. Test with the PCIe fix (kernel #3, 17 Oct)

Booted manually from the `=>` prompt (step 1). Result:

- `pcie@ca800000` (pcie2): `PCIe Gen.1 x2 link up`. The GPU is found:
  `0002:01:00.0 [1002:68f9]` (Radeon HD 5450, CEDAR) and audio `0002:01:00.1 [1002:aa68]`.
- BARs are assigned (BAR 0 256M pref at `0xa0000000`) and `radeon` loads: the GPU is posted,
  1024M VRAM, MSI works (`radeon: using MSI`), `fb0: radeondrmfb` is created.
- `pcie@ca400000` (pcie1): `Device found, but not active` (nothing is plugged in there).
- **New problem**:

  ```text
  [drm:r600_ring_test] *ERROR* radeon: ring 0 test failed (scratch(0x8504)=0xCAFEDEAD)
  radeon 0002:01:00.0: disabling GPU acceleration
  ```

  The GPU's command processor does not execute the ring. Suspected cause: the ring buffer
  lives in system memory (GTT) and the GPU does not see the CPU's writes (DMA coherency /
  cache on the K1). Not investigated yet.
- Note: the link runs at Gen.1 x2 (2.5 GT/s).

### 6. Another card: R9 290/390 (Hawaii) — failed

- Firmware for Hawaii is already in `CONFIG_EXTRA_FIRMWARE`, kernel #3 (same as step 5).
- Extra bootargs to have the card picked up by `amdgpu` instead of `radeon`:
  `radeon.cik_support=0 amdgpu.cik_support=1`.
- Result:

  ```text
  spacemit-k1-pcie ca400000.pcie: Device found, but not active
  spacemit-k1-pcie ca800000.pcie: Device found, but not active
  ```

  No link comes up, so `amdgpu` never even gets to see the card.
- Meaning: the LTSSM gets stuck in `Polling.Active`/`Polling.Compliance`. The controller does see
  that something is in the slot (receiver detect succeeds), but link training fails. With the HD 5450 in
  the same slot (pcie2) the link did come up.
- Possible causes (still to be checked):
  - the card gets no or too little power (6+8 pin, power supply, are the fans spinning?);
  - the card is not ready yet when PERST# is released / the driver waits too briefly (~1 s);
  - signal quality of a riser/adapter from x16 to the slot.
- Checked: the card's fans spin at full speed, so the card is getting power. There was a riser in between;
  next attempt with a riser that is known to work.

### 7. R9 290/390 with a different riser — link OK, amdgpu fails on BARs

- The link now does come up: `PCIe Gen.1 x1 link up` (x1 because of the riser). Card: `0002:01:00.0 [1002:67b1]`
  (HAWAII, ASUS/Sapphire 0x174B:0xE285), audio `[1002:aac8]`.
- `radeon` lets go of the card (`CIK support disabled by module param`), `amdgpu` picks it up,
  the VBIOS is read, the GPU is posted, 4096M GDDR5 detected.
- **Error**:

  ```text
  pci 0002:01:00.0: BAR 0 [mem size 0x10000000 64bit pref]: can't assign; no space
  pci 0002:01:00.0: BAR 2 [mem size 0x00800000 64bit pref]: can't assign; no space
  amdgpu 0002:01:00.0: [drm] Detected VRAM RAM=4096M, BAR=0M
  amdgpu: Move buffer fallback to memcpy unavailable
  amdgpu 0002:01:00.0: sw_init of IP block <uvd_v4_2> failed -19
  amdgpu 0002:01:00.0: Fatal error during GPU init
  ```

- Cause: in `k1.dtsi` pcie2 has a prefetchable window of exactly 256 MB
  (`0xa0000000-0xafffffff`). Hawaii has two prefetchable BARs: 256 MB (VRAM) + 8 MB (doorbells).
  Together they don't fit, so neither of them gets an address. (Besides the 256 MB the HD 5450 only had a
  small non-prefetchable BAR, which is why it did fit.)
- Fix: enlarge pcie2's prefetchable window to 264 MB (`0xa0000000-0xb07fffff`) and let the
  non-prefetchable window start at `0xb0800000` (104 MB). The total address range of pcie2
  stays the same; only the split changes.

### 8. R9 290/390 with larger pcie2 window — BARs OK, ring test fails

- After the change in `k1.dtsi` (pcie2 `ranges`, see step 7) the BARs get an address:

  ```text
  pci 0002:01:00.0: BAR 0 [mem 0xa0000000-0xafffffff 64bit pref]: assigned
  pci 0002:01:00.0: BAR 2 [mem 0xb0000000-0xb07fffff 64bit pref]: assigned
  amdgpu 0002:01:00.0: [drm] Detected VRAM RAM=4096M, BAR=256M
  ```

- **Error**:

  ```text
  amdgpu 0002:01:00.0: [drm:amdgpu_ring_test_helper] *ERROR* ring gfx test failed (-110)
  amdgpu 0002:01:00.0: hw_init of IP block <gfx_v7_0> failed -110
  amdgpu 0002:01:00.0: Fatal error during GPU init
  ```

  After that an Oops in the cleanup path (`drm_sched_entity_fini` ← `amdgpu_vce_sw_fini`): the VCE scheduler
  was never initialized. That is a consequence of the failed init, not the cause. The boot no longer
  reaches the login after that.
- This is the same kind of error as the `r600_ring_test` with the HD 5450 (step 5): the GPU's command processor
  does not execute the ring buffer.
- Suspected cause: **DMA is not cache-coherent on the K1.** The `soc` node in `k1.dtsi` has
  `dma-noncoherent`, so PCIe is too. The DRM/TTM stack assumes coherent devices (see the comment
  in `include/drm/drm_cache.h`). `drm_arch_can_wc_memory()` returns `false` on RISC-V, so amdgpu
  creates the ring buffer in GTT as plain *cached* memory. The CPU writes the commands into its
  cache, the GPU reads the (still empty) RAM via DMA and never sees them.
- The K1 does have `svpbmt` and `zicbom` (listed in `riscv,isa-extensions`), so uncached/WC mappings and
  cache maintenance are possible. Plan for the next attempt:
  1. Make `drm_arch_can_wc_memory()` return `true` on RISC-V (Svpbmt).
  2. In amdgpu, always create GTT buffers on a non-coherent device as USWC (uncached).
  3. Have TTM allocate the pages via `dma_alloc_attrs` (`use_dma_alloc`) if the device is not
     coherent, so they start out without dirty cache lines.

### 9. Reserving the PCIe DMA hole (DT only) — failed

- Analysis: the `dma-ranges` of `pcie-bus` in `k1.dtsi` give RAM `0x1_0000_0000-0x1_37ff_ffff` (896 MB) no
  bus address (those bus addresses are the MMIO window). DMA to those pages goes via swiotlb (bounce).
  A GPU keeps ring buffers mapped for a long time; CPU writes after `dma_map` then never reach the
  bounce copy that the GPU reads.
- Change: `reserved-memory` with `no-map` for that region in `k1-milkv-jupiter.dts` (with a comment).
  The kernel confirms: `OF: reserved mem: 0x0000000100000000..0x0000000137ffffff ... nomap`.
- Result: **same error**, `ring gfx test failed (-110)`. So this was not (solely) the cause. The
  reservation stays in place for now, because the problem does exist.
- Reference: the SpacemiT vendor kernel (`spacemit-com/linux-6.6`, branch `k1-bl-v2.2.y`) forces
  `caching = ttm_write_combined` for all GTT buffers in `amdgpu_ttm_tt_create()` on the K1. The TTM part
  (`__riscv` in `ttm_prot_from_caching()`) is already in mainline 7.2.

### 10. GTT buffers write-combined on non-coherent devices — **SUCCESS**

- Change in `drivers/gpu/drm/amd/amdgpu/amdgpu_ttm.c` (`amdgpu_ttm_tt_create()`, with a comment):

  ```c
  if (!dev_is_dma_coherent(adev->dev))
          caching = ttm_write_combined;
  ```

  Generic variant of what the SpacemiT vendor kernel does with `#ifdef CONFIG_SOC_SPACEMIT_K1X`. All
  GTT buffers (ring buffers, writeback/fences) are now mapped uncached (Svpbmt NC), so the GPU sees
  what the CPU writes.
- Kernel #4 + dtb with DMA hole reservation (step 9) + larger pcie2 window (step 7). Bootargs:
  `radeon.cik_support=0 amdgpu.cik_support=1`.
- Result:

  ```text
  amdgpu 0002:01:00.0: [drm] Display Core v3.2.384 initialized on DCE 8.0
  amdgpu 0002:01:00.0: [drm] UVD initialized successfully.
  amdgpu 0002:01:00.0: [drm] VCE initialized successfully.
  amdgpu 0002:01:00.0: SE 4, SH per SE 1, CU per SH 11, active_cu_number 40
  [drm] Initialized amdgpu 3.64.0 for 0002:01:00.0 on minor 0
  amdgpu 0002:01:00.0: [drm] fb0: amdgpudrmfb frame buffer device
  ```

  No ring/IB errors, boot reaches `sfvflite2 login:`.
- U-Boot reports on `booti`: `ERROR: reserving fdt memory region failed (addr=100000000 size=38000000)`.
  That is U-Boot's own memory bookkeeping (the region is already in use there); the kernel does apply the
  reservation. Harmless.

### 11. Verification: IB tests, benchmark, display

Booted with an extra `init=/bin/sh` for a root shell on the serial console, then:

```bash
mount -t proc proc /proc; mount -t sysfs sys /sys; mount -t debugfs none /sys/kernel/debug
cat /sys/kernel/debug/dri/0/amdgpu_test_ib          # -> "ib ring tests passed."
echo 1 > /sys/kernel/debug/dri/0/amdgpu_benchmark   # GTT <-> VRAM
echo 3 > /sys/kernel/debug/dri/0/amdgpu_benchmark   # GTT -> VRAM, 4 kB .. 64 MB
```

- IB tests on all rings (gfx, 8x compute, 2x sdma, uvd, vce) passed; fences are signaled.
- Benchmark: ~400 MB/s GTT <-> VRAM (both directions, limited by the x1 riser), 13 GB/s VRAM -> VRAM.
- **HDMI output from the R9 290/390 works** (framebuffer console via `amdgpudrmfb`).
- The same test **without** the DMA hole reservation (step 9, temporary dtb) also works. swiotlb then reported
  `io_tlb_used=0`, `io_tlb_used_hiwater=128` (so 256 kB was bounced at some point, not necessarily
  by the GPU). The reservation is therefore not needed to boot, but stays in place as protection against
  bouncing of long-lived GPU buffers under memory pressure (costs 896 MB of RAM; can be removed if you'd rather
  not have that).

### Summary of the working combination (17 Oct 2026)

| Component | Change |
| --- | --- |
| `drivers/pci/controller/dwc/pcie-spacemit-k1.c` | look up root port by `device_type = "pci"` (step 2) |
| `arch/riscv/boot/dts/spacemit/k1.dtsi` | pcie2 prefetchable window 256M -> 264M (step 7) |
| `arch/riscv/boot/dts/spacemit/k1-milkv-jupiter.dts` | `reserved-memory` for PCIe DMA hole (step 9, optional) |
| `drivers/gpu/drm/amd/amdgpu/amdgpu_ttm.c` | GTT write-combined if device is not DMA-coherent (step 10) |
| `drivers/gpu/drm/amd/amdgpu/amdgpu_vram_mgr.c` | VRAM BAR uncached if device is not DMA-coherent (step 14, against artifacts) |
| `arch/riscv/kernel/traps.c` | emulate unaligned user access that causes an access fault (step 14, needed for uncached VRAM) |
| bootargs | `radeon.cik_support=0 amdgpu.cik_support=1` (only for CIK cards such as Hawaii) |
| hardware | working riser (with the first riser the link did not come up) |

Still open:
- The HD 5450 (`radeon` driver) has the same coherency problem (step 5); `radeon_ttm.c` needs a
  similar change. Not tested.
- After a failed amdgpu init an Oops follows in the cleanup path (`amdgpu_vce_sw_fini`), a separate problem.

### 12. Defconfig: `arch/riscv/configs/k1_amdgpu_defconfig`

The current working config (amdgpu + firmware + USB) is in the tree as a defconfig. Verified:
`make k1_amdgpu_defconfig` produces exactly the same `.config`.

```bash
# requires: linux-firmware next to this tree (../linux-firmware), for CONFIG_EXTRA_FIRMWARE
make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- k1_amdgpu_defconfig
make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- -j$(nproc) Image.gz dtbs
```

### 13. Second defconfig with modules + initramfs: `arch/riscv/configs/k1_amdgpu_modules_defconfig`

Same board support and fixes as `k1_amdgpu_defconfig`, but set up like a distribution kernel
that boots with an initramfs (Debian creates it when the kernel package is installed):

- **Modules (~290)**: GPU (`amdgpu`, `radeon`, `nouveau`, ...), sound, media, network (K1 EMAC,
  PHYs, PCIe/USB cards), storage (MMC/`sdhci-of-k1`, NVMe, SCSI disks, USB storage), USB (DWC3, xHCI,
  HID, onboard hub), ext4 and other file systems, netfilter, crypto.
- **Built-in** (SoC basics): clocks, pinctrl, resets, regulators/PMIC, I2C, GPIO, serial console,
  PCIe controller and PHYs.
- **Initramfs required**: ext4 and the MMC driver are modules; without an initrd the kernel cannot find the rootfs.
- **Firmware**: only `esos.elf` built in (removed again in step 16). The GPU firmware comes from `/lib/firmware` on the board
  (Debian: `firmware-amd-graphics` from `non-free-firmware`).
- Version name `7.2.0-k1-amdgpu-modules`, so it can be installed alongside `7.2.0-k1-amdgpu`.
- Modules are compressed with xz. Wifi and bluetooth are (as in the other config) not enabled.

Building:

```bash
make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- k1_amdgpu_modules_defconfig
make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- -j$(nproc) LOCALVERSION= \
     KDEB_PKGVERSION=7.2.0-1 KDEB_CHANGELOG_DIST=trixie DPKG_FLAGS=-d bindeb-pkg
```

On the board:

```bash
sudo apt install firmware-amd-graphics      # GPU firmware (non-free-firmware must be in sources)
sudo dpkg -i linux-image-7.2.0-k1-amdgpu-modules_7.2.0-1_riscv64.deb
ls -la /boot/*k1-amdgpu-modules*            # vmlinuz-, initrd.img-, config-, System.map-
```

U-Boot (rootfs `mmc 2:1`, `/boot` = `mmc 2:3`, see *Booting from the installed deb*):

```bash
setenv fdt_addr_r 0x31000000
setenv ramdisk_addr_r 0x20000000
load mmc 2:3 ${kernel_addr_r} /vmlinuz-7.2.0-k1-amdgpu-modules
load mmc 2:3 ${ramdisk_addr_r} /initrd.img-7.2.0-k1-amdgpu-modules
setenv initrd_size ${filesize}
load mmc 2:1 ${fdt_addr_r} /usr/lib/linux-image-7.2.0-k1-amdgpu-modules/spacemit/k1-milkv-jupiter.dtb
setenv bootargs 'root=/dev/mmcblk0p1 rw swiotlb=131072 console=tty0 console=ttyS0,115200 earlycon rootwait stmmaceth=chain_mode:1 selinux=0 radeon.cik_support=0 amdgpu.cik_support=1'
booti ${kernel_addr_r} ${ramdisk_addr_r}:${initrd_size} ${fdt_addr_r}
```

- `setenv initrd_size ${filesize}` right after loading the initrd: `${filesize}` is overwritten by the
  next `load` (dtb).
- Memory: Image.gz at `0x08000000`, decompressed to `0x00200000`, initrd from `0x20000000` (room up to
  272 MB), dtb at `0x31000000`.
- The bootargs `radeon.cik_support=0 amdgpu.cik_support=1` also work with modules: the kernel passes them
  on when the module is loaded.

### 14. KDE Plasma (Wayland) runs, but with artifacts

- Plasma 6.3.6 on Wayland, Mesa 25.0.7 (radeonsi), kernel `7.2.0-k1-amdgpu` (deb). Stable, no crashes.
- Watching along via the UGREEN HDMI capture (`/dev/video2` on the Fedora machine):

  ```bash
  ffmpeg -f v4l2 -input_format mjpeg -video_size 1920x1080 -i /dev/video2 -frames:v 1 scherm.png
  ```

- **Error**: when dragging a window, large triangles from the taskbar to a point at the top, parts of
  windows drawn half/stale, background drawn over windows.
- `dmesg`: no GPU faults, ring timeouts or PCIe/AER errors (only `Failed to setup vendor infoframe`,
  harmless).
- Analysis: one vertex of a triangle with a wrong (stale/zero) position = the GPU reads
  vertex/uniform data from GTT before (or without) the CPU writes becoming visible. Mesa writes
  that data via WC mappings (Svpbmt NC). `pgprot_writecombine`/`pgprot_noncached` are the same as in the
  vendor kernel. The TTM path (`clear_page` via the cached linear map) has been checked: on reuse
  `dma_map_page(BIDIRECTIONAL)` does a cache flush, so that is probably not it.
- Hypotheses to test:
  1. NC writes from userspace (hart A) are not yet in RAM when the drm_sched thread
     (hart B) writes the doorbell: explicit `mb()` in the CS ioctl on hart A.
  2. Behavior of NC (write-combining/weakly ordered) on the X60: GTT as `ttm_uncached` (IO type)
     instead of `ttm_write_combined`, as a test (slow, and misaligned/vector access by Mesa may fault).

- Test: all cores but one offline (`echo 0 > /sys/devices/system/cpu/cpuN/online`, N=1..7):
  **same artifacts**. No race between cores (hypothesis 1 is ruled out). The pattern is systematic
  (tip of the triangle always at the top near the cursor/window title), so more likely the same stale data each time.
- New suspect (my own patch from step 10): forcing GTT to WC also dropped
  `AMDGPU_PTE_SNOOPED` from the GPU page table for buffers that were requested as *cached*. That flag
  partly determines how the GPU uses its own L2 for system memory, so the GPU may keep reading stale data from its
  cache.
- Change (`amdgpu_ttm.c`, with a comment): `struct amdgpu_ttm_tt` gets `snooped`; set when a
  cached BO is converted to WC; `amdgpu_ttm_tt_pde_flags()` then still sets `AMDGPU_PTE_SNOOPED`.
  Package `linux-image-7.2.0-k1-amdgpu_7.2.0-2_riscv64.deb`. Result: **same artifacts** (also gray
  triangles in the shadow color). Reverted.
- Shape of the error: the base coincides with vertices of the taskbar, the tip with a corner of a
  window/shadow. So the GPU combines vertices from different draws: in KWin's
  streaming vertex buffer it reads stale data from a previous frame in places where the new CPU data is not yet in
  RAM. Since it also happens with 1 core: presumably the CPU's NC/write-combine buffer
  (Svpbmt NC = weakly ordered); PCIe on the K1 is not coherent and does not see that buffer.
- Next test (`7.2.0-3`): GTT as `ttm_uncached` (Svpbmt IO, strictly ordered, no write-combining)
  instead of `ttm_write_combined`. Slow and possibly crashes due to unaligned access by Mesa, but
  proves the theory if the artifacts are gone.
- Result `7.2.0-3` (`ttm_uncached`): **SDDM does not start**. Xorg crashes in Mesa at
  `gbm_create_device` with `Segmentation fault at address 0x...6502` (odd address): unaligned
  access to strictly uncached (IO) memory is not allowed. So the test says nothing about the artifacts.
  Reverted to `7.2.0-1` (WC); source back to `ttm_write_combined`.
- Booting is now done via the updated `boot.scr` on the rootfs: in U-Boot (leave the boot menu with Ctrl-C)
  `load mmc 2:1 ${scriptaddr} boot.scr; source ${scriptaddr}`.
- Searched the vendor kernel (`spacemit-com/linux-6.6`, `k1-bl-v2.2.y`) for `CONFIG_SOC_SPACEMIT_K1X` in
  drm/arch/dma. Relevant K1 changes besides the GTT WC from step 10:
  - `amdgpu_vram_mgr.c`: **VRAM BAR for the CPU as `ttm_uncached`** instead of `ttm_write_combined`.
  - `gmc_v*_0.c`: DMA mask 34 bit instead of 40 (no difference on this 8 GB board: bus addresses < 2^34).
  - `radeon_irq_kms.c`: no MSI for cards <= GCN1 (only `radeon`, not relevant for Hawaii).
  - `arch/riscv/include/asm/pci.h`: `arch_can_pci_mmap_wc() 1`; `mm/init.c`: DMA32 limit 2 GB.
- Attempt `7.2.0-4`: VRAM BAR `ttm_uncached` on non-coherent devices (like the vendor kernel). Result:
  **no login screen**. `sddm-greeter-qt6` crashes: `unhandled signal 11 code 0x2 ... in libc.so.6[83502]`
  (same libc offset as the Xorg crash with `7.2.0-3`). That instruction is `sd t0,-8(a4)`: the
  unaligned 8-byte tail store of glibc's `memcpy`. For unaligned access to IO memory the X60 raises
  an *access fault* (not a misaligned trap), so the kernel does not emulate it → SIGSEGV.
  Reverted to `7.2.0-1`.
- Attempt `7.2.0-5`: same VRAM change **plus** in `arch/riscv/kernel/traps.c`: a load/store access
  fault from userspace on an unaligned address is first handed to the existing
  misaligned emulation (byte access, which is allowed on IO); otherwise SIGSEGV as before (with a comment).
  Result: **SUCCESS**. SDDM login screen and KDE Plasma work, **no more triangles/artifacts** when
  dragging windows (9 capture frames clean), no GPU errors, no coredumps. Somewhat slower, because
  CPU writes to VRAM are now strictly uncached (and unaligned tails go through the emulation).

### 15. Modular kernel with initramfs as default + autoboot

- `linux-image-7.2.0-k1-amdgpu-modules_7.2.0-2_riscv64.deb` built with all fixes (GTT WC, VRAM uncached,
  access fault emulation) and installed. `firmware-amd-graphics` was already on the board.
- The initrd (`initramfs-tools`, `MODULES=most`) contains `sdhci-of-k1`, `ext4`, `amdgpu` and
  `amdgpu/hawaii_*.bin`. After booting, `amdgpu`, `ext4`, `sdhci_of_k1`, `k1_emac` and `dwc3` are loaded as
  modules. KDE Plasma works without artifacts.
- `/boot.cmd` (on the rootfs) changed to `7.2.0-k1-amdgpu-modules`; backup of the previous one in
  `/boot.cmd.7.2.0-k1-amdgpu`. Then `boot.scr` regenerated:

  ```bash
  cd /
  sudo mkimage -C none -A riscv -T script -d boot.cmd boot.scr
  ```

- Booting manually from the U-Boot prompt: `load mmc 2:1 ${scriptaddr} boot.scr; source ${scriptaddr}`

Automatic boot with 3 seconds to intervene. During `bootdelay` this U-Boot shows the boot menu
(with countdown) and after the countdown runs menu item `bootmenu_0` (currently `run boot_default`, just an
`echo`, which is why you kept ending up back in the menu). Put the boot.scr line there:

```bash
setenv bootdelay 3
setenv bootmenu_0 'Debian (boot.scr)=load mmc 2:1 ${scriptaddr} boot.scr; source ${scriptaddr}'
setenv bootcmd 'load mmc 2:1 ${scriptaddr} boot.scr; source ${scriptaddr}'
saveenv
```

- Pressing a key (arrow) during the 3 seconds stops the countdown; then choose `U-Boot console` or
  another item. Ctrl-C leaves the menu straight to the `=>` prompt.
- `bootcmd` is a safety net in case the menu is not shown.
- Back to the old situation: `setenv bootmenu_0 '"-------- Boot Options --------"=run boot_default'`,
  `setenv bootcmd`, `saveenv`.
- **Tested (18 Oct)**: configured and `saveenv` (`Saving Environment to MMC... OK`), then `reset` without
  pressing keys: the menu shows `Debian (boot.scr)`, counts down 3-2-1, runs `boot.scr` and boots
  `7.2.0-k1-amdgpu-modules` to the login/SDDM.

### 16. Repository restructured as patch series + Makefile; port to Linux 7.3 (19 Oct 2026)

- The uncommitted changes in the 7.2 tree were split into 11 commits on top of `v7.2` and exported
  with `git format-patch` to `linux-7.2-patches/` (0001–0011: dt-binding, dwc export, root-port lookup,
  INTx driver, INTx dts, pcie2 window, DMA hole, GTT WC, VRAM uncached, traps.c, defconfigs).
  Checked: the tree rebuilt from the patches is byte-identical to the tested tree.
- `Makefile` + `scripts/kernel-tree.sh`: one shared bare kernel git (`.kernel.git`), one git worktree
  per version (`linux-7.2/`, `linux-7.3/`, branch `jupiter-<version>`); patches that are not applied
  yet (matched on the commit subject) are applied with `git am --3way`. Builds are out of tree
  (`O=build/<version>-<flavor>/obj`), so `builtin` and `modules` no longer need a copy of the tree.
- The `linux-headers` package is skipped (`DEB_BUILD_PROFILES=pkg.linux-upstream.nokernelheaders`; `dpkg-buildpackage -P` does not pass the profile on to `debian/rules`), so `make` no
  longer ends with an error; the package revision counts up from the `.deb` files in the repo root.
- **Linux 7.3**: all 11 patches apply. Only conflict: the `#include` block of `amdgpu_vram_mgr.c`
  (7.3 adds `cgroup_dmem.h` and `pm_runtime.h`); resolved by keeping all three includes.
  Upstream changes between 7.2 and 7.3 that touch the patched code were checked:
  - `PCI: dwc: Move iMSI-RX check before calling 'pp->ops->init()'`: `use_imsi_rx` is now set before
    `.init()`; `pp->msi_irq[0]` is still filled in after `.init()`, before `.post_init()`, so the
    INTx combined handler is unaffected.
  - `PCI: spacemit: Add missing MODULE_DEVICE_TABLE()`: one line, no overlap.
  - `traps.c`: kprobe annotations and the syscall entry changed; `DO_ERROR_INFO` (the template for
    the access-fault handler) is unchanged.
  - Both defconfigs: every option in them ends up in the 7.3 `.config` unchanged.
- `esos.elf` removed from `CONFIG_EXTRA_FIRMWARE` in both defconfigs (and from the repo). It is
  RT-Thread-based firmware for the K1's small real-time core (N308), loaded through remoteproc by
  the SpacemiT vendor kernel only; no mainline driver or K1 device tree requests it, so it was dead
  weight in the kernel. Its license is also unclear (no license text, not in linux-firmware).
- Build results (`make deb-7.3 deb-7.2`, 19 Oct): all four build without errors.
  - `linux-image-7.3.0-k1-amdgpu_7.3.0-1_riscv64.deb` (vmlinuz 21.5 MB, GPU firmware built in)
  - `linux-image-7.3.0-k1-amdgpu-modules_7.3.0-1_riscv64.deb` (vmlinuz 8.5 MB, 287 modules)
  - `linux-image-7.2.0-k1-amdgpu_7.2.0-6_riscv64.deb`, `linux-image-7.2.0-k1-amdgpu-modules_7.2.0-3_riscv64.deb`
  - The 7.3 dtb contains the patched pcie2 `ranges` (264M prefetchable), the INTx `interrupt-map`s
    and `memory@100000000` (DMA hole).
  - **Not yet tested on the board.**

### 17. Third config: everything the Debian kernel has (`k1_amdgpu_debian_defconfig`, 19 Oct 2026)

- Goal: a kernel with every option the Debian riscv64 kernel enables, plus what this board needs.
- Source: the newest Debian riscv64 kernel at the time, `7.2.11+deb14-riscv64` from sid
  (`scripts/fetch-debian-config.sh`; the config sits in `linux-base-<release>-riscv64`, the
  `linux-image-*` package is only a meta package). Stored in `configs/debian/`.
- `scripts/debian-defconfig.sh <version>` (or `make debian-defconfig-<version>`):
  - switches off the other SoC families from `arch/riscv/Kconfig.socs` that Debian enables
    (Andes, Anlogic, Canaan, ESWIN, Microchip/PolarFire, Renesas, SiFive, Sophgo, StarFive,
    Allwinner, Tenstorrent, T-Head, UltraRISC); `ARCH_SPACEMIT` and the generic `ARCH_VIRT` stay;
  - `LOCALVERSION="-k1-amdgpu-debian"`, `MODULE_SIG_ALL=y` with a key generated at build time
    (Debian signs its modules afterwards with its own key, so its config has no key),
    `GCC_PLUGINS` off (Fedora's cross gcc supports plugins, Debian's build does not use them);
  - `olddefconfig`: options newer than the Debian kernel get their default value;
  - checks that the board essentials (PLIC, K1 PCIe + PHYs, USB2 PHY, DWC3, onboard hub, SDHCI-K1,
    EMAC, CCU, pinctrl, P1 PMIC, amdgpu + CIK) are set, then `savedefconfig`.
- Debian already enables every K1 driver we use (`ARCH_SPACEMIT=y`, `PCIE_SPACEMIT_K1=y`,
  `PHY_SPACEMIT_K1_USB2=m`, `MMC_SDHCI_OF_K1=m`, `DRM_AMDGPU_CIK=y`, ...), so no board options had
  to be added.
- Compared with the Debian config, only these drop out (besides the other SoCs' drivers):
  symbols those SoCs select (`ARM_AMBA`, `SOC_BUS`, `CLKSRC_MMIO`, `MDIO_BUS_MUX`, `DRM_DW_HDMI`,
  `PCIE_CADENCE*`), `CC_CAN_LINK` (no riscv64 glibc for the cross compiler), `RUST_IS_AVAILABLE`
  (Rust is not enabled anyway) and two Debian-only patches (`LOCK_DOWN_IN_EFI_SECURE_BOOT`,
  `SECURITY_PERF_EVENTS_RESTRICT`).
- **pahole is required**: without it Kconfig silently drops `DEBUG_INFO_BTF` and everything that
  depends on it (`SCHED_CLASS_EXT`, `NET_SCH_BPF`, `IO_URING_BPF_OPS`, BTF args for probes).
  Install `dwarves` on the build host.
- Checked: `make k1_amdgpu_debian_defconfig` gives exactly the generated `.config` (7.2 and 7.3).
- Like Debian, `DEBUG_INFO=y`: the build is much slower and also produces a large
  `linux-image-*-dbg` package (not needed on the board).
- Build result 7.3 (`make deb-7.3-debian`, ~50 min on 16 threads, in parallel with other work):
  `linux-image-7.3.0-k1-amdgpu-debian_7.3.0-1_riscv64.deb` (126 MB; vmlinuz 12.9 MB) plus a
  `-dbg` package of 1.2 GB (debug info, not needed on the board). On the board the initrd is
  130 MB.

### 18. Board test of all kernels (19 Oct 2026)

Per kernel: `milkv-tools/install-deb.sh`, `milkv-tools/set-boot.sh <release>`, reboot, then check
`dmesg` (link up, `Initialized amdgpu`, BAR=256M, no ring/IB errors), `amdgpu_test_ib`, SDDM active,
no new coredumps, and an HDMI capture of the SDDM login screen. Moving windows (the artifact test
from step 14) was not possible remotely; a clean SDDM login screen counts as passed.

| Kernel | Package | Result |
| --- | --- | --- |
| `7.3.0-k1-amdgpu-modules` | `7.3.0-1` | passed: link Gen1 x1, amdgpu OK, IB tests passed, SDDM login screen clean |
| `7.3.0-k1-amdgpu` (builtin) | `7.3.0-1` | passed (0 modules loaded) |
| `7.2.0-k1-amdgpu-modules` | `7.2.0-3` (without `esos.elf`) | passed |
| `7.2.0-k1-amdgpu` (builtin) | `7.2.0-6` (without `esos.elf`) | passed |
| `7.3.0-k1-amdgpu-debian` | `7.3.0-1` | passed: 96 modules loaded, kernel not tainted (modules signed), `/sys/kernel/btf/vmlinux` and `/sys/kernel/sched_ext` present |
| `7.2.0-k1-amdgpu-debian` | `7.2.0-1` | passed: 95 modules, not tainted, BTF + sched_ext present |

- So `esos.elf` is indeed not needed by the mainline kernel (step 16).
- The first boot of the debian kernel took 3.5 min: `apparmor.service` 2 min 53 s. Only this config
  enables AppArmor (LSMs: `lockdown,capability,landlock,yama,apparmor,tomoyo,bpf,ipe,ima,evm`), so
  Debian compiled its 118 profiles into a new cache (`/var/cache/apparmor/<hash>.0`). Second boot:
  36 s in total. Expected once per new kernel build.
- One crash during the second boot of `7.3.0-k1-amdgpu-debian`: the udev helper
  `/usr/libexec/nfsrahead 179:512` (nfs-common 2.8.3, sets the read-ahead of a block device) died
  with `unhandled signal 11 code 0x1 at 0x00000013fc5e2a04`: `SEGV_MAPERR` with the fault address
  equal to the PC, so a jump to an unmapped address. Our `traps.c` patch only handles access faults
  (`SEGV_ACCERR`, code 0x2), so it is not involved. It happened once in the whole journal history
  (not on the boot before with the same kernel, nor on the 4 boots after); the system kept working.
  Not investigated further; watch for it.
- **Not a one-off.** Later the same evening, while booting `7.3.0-k1-amdgpu-debian` again (its 7th
  boot), systemd itself crashed:

  ```text
  systemd[1]: unhandled signal 11 code 0x1 at 0xffffffffffffffbf in libsystemd-core-257.so[a5f58,3fa9a00000+1a1000]
  epc : 0000003fa9aa5f58 ra : 0000003fa9aa5f58 ... badaddr: ffffffffffffffbf cause: 000000000000000d
  systemd[1]: Caught <SEGV>, dumped core as pid 521.
  systemd[1]: Freezing execution.
  ```

  PID 1 froze, the board stopped responding (no ssh) and had to be power-cycled. Recovered by
  interrupting U-Boot over the serial console and booting `7.3.0-k1-amdgpu-modules` by hand; the
  default boot was switched to that kernel.
- So: 2 wild-pointer crashes (`SEGV_MAPERR`, garbage address) in 7 boots of the debian kernel, none
  in more than 10 boots of the builtin/modules kernels. Something in the Debian config corrupts
  userspace state. Options that differ from the modules config: `TRANSPARENT_HUGEPAGE_ALWAYS=y`
  (prime suspect), `NUMA=y`, `KFENCE=y`, `INIT_ON_ALLOC_DEFAULT_ON=y`,
  `RANDOMIZE_KSTACK_OFFSET_DEFAULT=y`, `SCHED_CLASS_EXT=y` (vector and preemption settings are the
  same). Plan: boot the debian kernel repeatedly with `transparent_hugepage=never`, count crashes,
  then bisect the rest. **Do not use the debian flavor as default until this is solved.**
- The checks above are now one script: `milkv-tools/test-kernel.sh <deb> <release>`.
- End state on the board: default `7.3.0-k1-amdgpu-debian` (`/boot.cmd`), also installed
  `7.3.0-k1-amdgpu-modules` and `7.2.0-k1-amdgpu-modules` (fallbacks; switch with
  `milkv-tools/set-boot.sh <release>`). `/boot`: 261 MB free.
- Space on `/boot` (715 MB) is the limit: every kernel comes with an ~80–90 MB initrd (Debian also
  creates one for the builtin kernel). Removed the old `6.19.13-opvolger` and Debian `7.0.12` kernels
  (including the split `linux-base/binary/modules/headers` packages and the `linux-image-riscv64`
  meta package) to make room.
- The HDMI capture hung with `-input_format mjpeg -video_size 1920x1080` (no frames, ffmpeg stuck);
  the default format works. `milkv-tools/screenshot.sh` now uses the default format, finds the UGREEN
  device by name (video numbers change on replug; the laptop webcam must not be used) and kills
  ffmpeg after 30 s.

## Building a Debian package (.deb)

Required (Fedora): `sudo dnf install dpkg-dev debhelper` (plus `fakeroot`, `dpkg`).

The kernel version suffix is fixed in the defconfig (`CONFIG_LOCALVERSION="-k1-amdgpu"`,
`CONFIG_LOCALVERSION_AUTO` off). Pass `LOCALVERSION=` (empty) when building: without that variable
`scripts/setlocalversion` appends `-dirty` as long as there are uncommitted changes.

Nowadays: `make deb-7.3-builtin` / `make deb-7.3-modules` (see step 16). What the Makefile
does there boils down to:

```bash
cd ~/code/linux     # old layout
make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- k1_amdgpu_defconfig
make ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- -j$(nproc) \
     LOCALVERSION= KDEB_PKGVERSION=7.2.0-1 KDEB_CHANGELOG_DIST=trixie DPKG_FLAGS=-d \
     bindeb-pkg
```

- `KDEB_PKGVERSION`: increment (`7.2.0-2`, ...) with every new build, otherwise `dpkg` does not see it as an update.
- `DPKG_FLAGS=-d`: skip the Debian build-dependency check (on Fedora `dpkg` does not know the installed
  packages).
- `KDEB_CHANGELOG_DIST=trixie`: only for the changelog in the package.

Result (tested 17 Oct), at the time in `~/code/` (now in the root of this repo):

- `linux-image-7.2.0-k1-amdgpu_7.2.0-1_riscv64.deb` (22 MB):
  - `/boot/vmlinuz-7.2.0-k1-amdgpu` (Image.gz, including built-in GPU firmware)
  - `/boot/config-7.2.0-k1-amdgpu`, `/boot/System.map-7.2.0-k1-amdgpu`
  - `/usr/lib/linux-image-7.2.0-k1-amdgpu/spacemit/k1-milkv-jupiter.dtb`
- `linux-libc-dev_7.2.0-1_riscv64.deb` (userspace headers, not needed for booting)
- `linux-headers-...` **fails** with the Fedora cross compiler: that package compiles helper programs
  (`fixdep`, `modpost`, ...) for riscv64 and a riscv64 glibc is missing for that
  (`sys/types.h: No such file or directory`). Only needed for out-of-tree modules. That is why
  `make` ends with an error even though the image deb is done. The Makefile now skips this package with
  `DEB_BUILD_PROFILES=pkg.linux-upstream.nokernelheaders`.

Installing on the Milk-V:

```bash
# or: milkv-tools/install-deb.sh linux-image-7.2.0-k1-amdgpu_7.2.0-1_riscv64.deb
scp linux-image-7.2.0-k1-amdgpu_7.2.0-1_riscv64.deb <user>@192.168.2.32:/tmp/
# on the board:
sudo dpkg -i /tmp/linux-image-7.2.0-k1-amdgpu_7.2.0-1_riscv64.deb
```

### Booting from the installed deb (U-Boot)

By default U-Boot boots from its own boot partition (`mmc_boot`), so you load the kernel, initrd and dtb yourself.
Layout on this board (eMMC = U-Boot `mmc 2`, Linux `mmcblk0`):

| U-Boot | Linux | Contents |
| --- | --- | --- |
| `mmc 2:1` | `/dev/mmcblk0p1` = `/` | rootfs, dtb in `/usr/lib/linux-image-<version>/spacemit/` |
| `mmc 2:3` | `/dev/mmcblk0p3` = `/boot` | `vmlinuz-<version>`, `initrd.img-<version>` (in the root of the partition!) |

Kernel with everything built in (`7.2.0-k1-amdgpu`, no initrd needed):

```bash
setenv fdt_addr_r 0x31000000
load mmc 2:3 ${kernel_addr_r} /vmlinuz-7.2.0-k1-amdgpu
load mmc 2:1 ${fdt_addr_r} /usr/lib/linux-image-7.2.0-k1-amdgpu/spacemit/k1-milkv-jupiter.dtb
setenv bootargs 'root=/dev/mmcblk0p1 rw swiotlb=131072 console=tty0 console=ttyS0,115200 earlycon rootwait stmmaceth=chain_mode:1 selinux=0 radeon.cik_support=0 amdgpu.cik_support=1'
booti ${kernel_addr_r} - ${fdt_addr_r}
```

As a single saved command (does not boot automatically, only with `run boot_k1amd`):

```bash
setenv boot_k1amd 'setenv fdt_addr_r 0x31000000; load mmc 2:3 ${kernel_addr_r} /vmlinuz-7.2.0-k1-amdgpu; load mmc 2:1 ${fdt_addr_r} /usr/lib/linux-image-7.2.0-k1-amdgpu/spacemit/k1-milkv-jupiter.dtb; setenv bootargs root=/dev/mmcblk0p1 rw swiotlb=131072 console=tty0 console=ttyS0,115200 earlycon rootwait stmmaceth=chain_mode:1 selinux=0 radeon.cik_support=0 amdgpu.cik_support=1; booti ${kernel_addr_r} - ${fdt_addr_r}'
saveenv
```

`vmlinuz` is an Image.gz; `booti` decompresses it via `kernel_comp_addr_r`/`kernel_comp_size` (already in
the env).
