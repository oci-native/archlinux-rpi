# Kernel and firmware layout: Arch/ALARM packages vs bootc requirements

Evidence gathered by extracting the real `.pkg.tar.xz` files from
`http://mirror.archlinuxarm.org/aarch64/` on 2026-09-11. Nothing in this doc is
guessed from package names. Extraction tree:
`/tmp/claude-1000/-var-home-bupd-code-rpi/961e1f1f-153a-46c8-8080-8a29fc71db80/scratchpad/pkgs/extracted/`.

bootc's two hard requirements, restated: kernel at
`/usr/lib/modules/$kver/vmlinuz`, initramfs at
`/usr/lib/modules/$kver/initramfs.img`, and `/boot` empty in the built image.

**2026-09-13: the kernel no longer comes from any Arch package.** `linux-rpi` never
mounted root on the real board, so `Containerfile.base` now takes the kernel, modules
and dtbs from `quay.io/almalinuxorg/almalinux-bootc-rpi:10` and installs no Arch kernel
at all -- see the superseding note at the top of `docs/kernel-choice.md`. The *layout*
this doc specifies is unchanged and is still what the sync hook reads: kernel,
initramfs and `dtbs/` all under one `/usr/lib/modules/$kver/`. What changed is only
where that directory's contents originate. Two knock-on details worth knowing:

- The dtb set is staged in the `alma-kernel` build stage, from
  `/usr/share/raspberrypi2-kernel4/$kver/boot/`, not relocated out of `/boot` in
  `Containerfile.rpi`. It is the same 25-dtb Raspberry Pi downstream set inventoried
  below, `bcm2712d0-rpi-5-b.dtb` and `bcm2712-d-rpi-5-b.dtb` included, plus 366
  overlays.
- The VideoCore blobs still come from ALARM's `raspberrypi-bootloader`, and the
  CYW43455 wifi blobs from `firmware-raspberrypi`. Both are firmware for the hardware,
  not for the kernel, and `firmware-raspberrypi` does ship
  `brcmfmac43455-sdio.raspberrypi,5-model-b.{bin,txt,clm_blob}`, which is what the
  AlmaLinux kernel's `brcmfmac` will ask for on this board.

## Package manifests

### linux-rpi 6.18.50-1 (aarch64, 2440 files, 50.9 MB installed)

```
usr/lib/modules/6.18.50-1-rpi/vmlinuz          <- already the bootc path, verbatim
usr/lib/modules/6.18.50-1-rpi/pkgbase
usr/lib/modules/6.18.50-1-rpi/modules.order
usr/lib/modules/6.18.50-1-rpi/modules.builtin
usr/lib/modules/6.18.50-1-rpi/modules.builtin.modinfo
usr/lib/modules/6.18.50-1-rpi/kernel/...       <- 2015 .ko.zst files, standard path
boot/kernel8.img                               <- duplicate of vmlinuz, legacy name
boot/config.txt                                <- backup=, stock firmware config
boot/cmdline.txt                               <- backup=, "root=/dev/mmcblk0p2 rw rootwait console=serial0,115200 console=tty1 fsck.repair=yes"
boot/*.dtb                                     <- 26 files, bcm2710/2711/2712/2837, see below
boot/overlays/*.dtbo                           <- 386 files
boot/overlays/README
```

`vmlinuz` is already sitting at the exact path bootc wants. Arch's kernel
packaging convention matches bootc natively; AlmaLinux's RPM has to park its
kernel under a separate `raspberrypi2-kernel4` doc tree because RPM doesn't
give it this convention for free. Only `boot/` is the problem: 415 files (29
non-overlay plus 386 overlays) that must not exist in `/boot` in the image.

`.PKGINFO`: `depend = firmware-raspberrypi`, `depend = raspberrypi-bootloader`,
`depend = mkinitcpio>=0.7`, `conflict = linux-rpi-16k`, `conflict = uboot-raspberrypi`,
`provides = raspberrypi-overlays`, `backup = boot/config.txt`, `backup = boot/cmdline.txt`.

`.INSTALL` scriptlet: `post_install`/`post_upgrade` only touch a live
`/boot/config.txt` (strip `cma_*` lines) and warn about an unmounted `/boot`
partition, both no-ops in a container build with an empty `/boot` and no
running system, so there's nothing to neutralise there. `post_remove` deletes
`boot/initramfs-linux.img`. No pacman hook ships in this package. The team
brief's premise ("linux-rpi almost certainly has a hook that copies things
into /boot") is wrong, checked directly, there is none. The only
`/boot`-relevant hook in the whole package set belongs to `dracut` itself
(below), and it isn't Pi-specific.

`etc/mkinitcpio.d/linux-rpi.preset` exists (mkinitcpio is a hard dependency)
but is irrelevant since we mask mkinitcpio and drive dracut manually, exactly
as `Containerfile.base` already does for x86.

dtb list (26, confirms BCM2712 D0 coverage, see decision 2):

```
bcm2837-rpi-zero-2-w.dtb   bcm2837-rpi-cm3-io3.dtb   bcm2837-rpi-3-b.dtb
bcm2837-rpi-3-b-plus.dtb   bcm2837-rpi-3-a-plus.dtb  bcm2837-rpi-2-b.dtb
bcm2712d0-rpi-5-b.dtb      bcm2712-rpi-cm5l-cm5io.dtb  bcm2712-rpi-cm5l-cm4io.dtb
bcm2712-rpi-cm5-cm5io.dtb  bcm2712-rpi-cm5-cm4io.dtb   bcm2712-rpi-500.dtb
bcm2712-rpi-5-b.dtb        bcm2712-d-rpi-5-b.dtb
bcm2711-rpi-cm4s.dtb bcm2711-rpi-cm4.dtb bcm2711-rpi-cm4-io.dtb
bcm2711-rpi-400.dtb bcm2711-rpi-4-b.dtb
bcm2710-rpi-zero-2.dtb bcm2710-rpi-zero-2-w.dtb bcm2710-rpi-cm3.dtb
bcm2710-rpi-cm0.dtb bcm2710-rpi-3-b.dtb bcm2710-rpi-3-b-plus.dtb bcm2710-rpi-2-b.dtb
```

### linux-rpi-16k 6.18.50-1 (aarch64, 16K pages, BCM2712-only)

Same layout, `usr/lib/modules/6.18.50-1-rpi-16k/vmlinuz`, 2014 `.ko.zst`
modules (near-identical driver set to linux-rpi's 2015). `.PKGINFO`:
`pkgdesc = Linux kernel and modules (RPi Foundation fork) with 16k pagesize
for bcm2712/RPi5 ONLY`, `conflict = linux-rpi`, `conflict = linux`.

`boot/*.dtb` is 8 files, all BCM2712, and includes `bcm2712d0-rpi-5-b.dtb`,
the same D0 dtb as the 4K package. `boot/overlays/` is the same 386 files
(the overlay tree is board-agnostic, not page-size-dependent). Otherwise the
two packages are structurally identical, just built with
`CONFIG_ARM64_16K_PAGES=y` and trimmed dtbs.

### raspberrypi-bootloader 20260907-1 (any, 20 files)

```
boot/bootcode.bin
boot/start.elf     boot/start_x.elf   boot/start_cd.elf   boot/start_db.elf
boot/start4.elf    boot/start4x.elf   boot/start4cd.elf   boot/start4db.elf
boot/fixup.dat     boot/fixup_x.dat   boot/fixup_cd.dat   boot/fixup_db.dat
boot/fixup4.dat    boot/fixup4x.dat   boot/fixup4cd.dat   boot/fixup4db.dat
```

All 16 firmware blobs plus `bootcode.bin`, flat in `/boot`, nothing under
`/usr` at all. No `.INSTALL`, no hooks. `start4.elf`/`fixup4.dat` is the
VideoCore binary Pi 5 boots with. The Raspberry Pi Foundation never shipped a
`start5.elf`; BCM2712 reuses the BCM2711 (`4`) firmware binary family.

### firmware-raspberrypi 20260311-1 (any, wifi/BT blobs)

```
usr/lib/firmware/updates/brcm/BCM43430A1.hcd, BCM43430B0.hcd, BCM4345C0.hcd, ...
usr/lib/firmware/updates/brcm/brcmfmac43436-sdio.{bin,txt,clm_blob}
usr/lib/firmware/updates/brcm/brcmfmac43456-sdio.{bin,txt,clm_blob}
usr/lib/firmware/updates/cypress/cyfmac43439-sdio.{bin,txt,clm_blob}
usr/lib/firmware/updates/cypress/cyfmac43455-sdio-{minimal,standard}.bin
usr/share/alsa/cards/RPi-WM8804.conf
usr/share/licenses/broadcom/cypress/LICENSE
```

Already fully under `/usr` (`usr/lib/firmware/`) with the correct
linux-firmware convention (an `updates/` subdir so it overrides any
in-kernel-tree blob of the same name). No relocation needed for this
package. It was never under `/boot` to begin with.

### linux-firmware 20260810-2, meta-package with no direct content

`.PKGINFO` shows `xdata = pkgtype=split`, `size = 0`, and a chain of
`depend = linux-firmware-{amdgpu,atheros,broadcom,cirrus,intel,mediatek,
nvidia,other,radeon,realtek}` plus several `optdepend`s (liquidio, marvell,
mellanox, nfp, qcom, qlogic). It carries zero files itself. The Pi's own
wifi/BT chips (Broadcom/Cypress SDIO) are served by `firmware-raspberrypi`
above, not by `linux-firmware-broadcom` (that split covers PCIe/USB Broadcom
NICs, a different device class). Recommendation: don't pull `linux-firmware`
into the Pi image at all. It would add roughly ten split packages of
firmware for hardware a Pi 5 doesn't have (AMD GPU, Nvidia, Mellanox NICs,
and so on) for zero benefit. Revisit only if a specific USB/PCIe peripheral
needs a blob from one of those splits.

### raspberrypi-utils 20260904-1 (aarch64), provides vcmailbox and vcgencmd

Confirmed by direct file listing, both present:

```
usr/bin/vcgencmd
usr/bin/vcmailbox
usr/bin/rpi-eeprom-ab       usr/bin/rpi-fw-crypto      usr/bin/rpi-gpu-usage
usr/bin/dtoverlay usr/bin/dtmerge usr/bin/dtapply usr/bin/ovmerge
usr/bin/pinctrl usr/bin/eepflash.sh usr/bin/eepmake usr/bin/eepdump
```

`.PKGINFO`: `depend = dtc`, `conflict = raspberrypi-firmware`. No `.INSTALL`,
no hooks. `vcmailbox` is what `rpi-bootc-bootloader tryboot` shells out to
(`vcmailbox 0x00038064 4 4 1`), so this package is a hard runtime dependency
for the sync hook, not just a debugging convenience.

### dracut 111-1 (aarch64)

Two pacman hooks and two `kernel-install` plugins ship in the base package,
none of them Pi-specific:

```
usr/share/libalpm/hooks/90-dracut-install.hook   -> triggers on usr/lib/modules/*/vmlinuz, usr/lib/modules/*/pkgbase, usr/lib/dracut/*, usr/lib/firmware/*
usr/share/libalpm/hooks/60-dracut-remove.hook    -> triggers on usr/lib/modules/*/pkgbase removal
usr/lib/kernel/install.d/50-dracut.install       -> the actual dracut invocation via kernel-install
usr/lib/kernel/install.d/51-dracut-rescue.install
```

`90-dracut-install.hook` fires as soon as `linux-rpi`'s `vmlinuz`/`pkgbase`
land, and calls `kernel-install add`, which can write files under
`/boot/$MACHINE_ID/...` or `/boot/loader/entries/`. This is harmless for us:
`Containerfile.base` already handles this class of side effect by nuking
`/boot` and recreating it empty after pacman and the manual `dracut --force`
call finish, regardless of what the hook wrote. The Pi Containerfile should
do the same, copying the boot assets (dtbs, overlays, bootloader blobs) out
to their `/usr` targets before the final `rm -rf /boot`, same ordering as
x86.

The default dracut config profiles shipped under
`usr/lib/dracut/dracut.conf.d/{hostonly,generic,rescue,fips,ima,no-network}/`
are inert subdirectories, not symlinked as active, so nothing here overrides
the explicit `hostonly=no` / `add_dracutmodules` dropin `Containerfile.base`
already writes at `/usr/lib/dracut/dracut.conf.d/30-archlinux-bootc-container-build.conf`.
The same pattern applies to the Pi image. `hostonly=no` is still mandatory
because the initramfs is built inside the container, not on the target Pi.

No dracut modules named `ostree`/`bootc` ship in this package. Those come
from the `ostree` package itself (`ostree-2026.4-1-aarch64.pkg.tar.xz`,
confirmed present in the ALARM `extra` repo) and from bootc's own
`make install-all`, exactly as they already do on x86. ALARM ships no
first-party `bootc` package (confirmed: no `*bootc*` entry in `core`,
`extra`, or `alarm`), matching the team brief's from-source build.

## Decisions

### 1. linux-rpi (4K) vs linux-rpi-16k (16K): use linux-rpi (4K)

What differs, checked directly: separate kernel builds
(`6.18.50-1-rpi` vs `6.18.50-1-rpi-16k`), `conflict`-listed against each
other, near-identical driver/module set (2015 vs 2014 `.ko.zst` files). The
only real difference is `CONFIG_ARM64_16K_PAGES` and a trimmed BCM2712-only
dtb set (8 dtbs vs 26). Both ship `bcm2712d0-rpi-5-b.dtb`.

Raspberry Pi OS for Pi 5 does default to 16K pages (`kernel_2712`,
`CONFIG_ARM64_16K_PAGES=y` in `bcm2712_defconfig`). The official rationale is
a measured roughly 7% random-memory-access win, per a Raspberry Pi engineer
on the forums: https://forums.raspberrypi.com/viewtopic.php?t=361390. It
keeps a 4K fallback (`kernel8.img`, package `linux-image-rpi-v8`)
specifically for compatibility, selectable via `config.txt` or by purging
the 2712 package.

The open compatibility tracker
(https://github.com/raspberrypi/bookworm-feedback/issues/107) lists concrete
breakage on 16K pages: Wine, Box86/Box64, libvirt/QEMU/KVM, Zig,
jemalloc-linked binaries, Chromium <102, Qt5/6 WebEngine, most 32-bit
(armhf) binaries. The failure mode is ELF `LOAD` segments not aligned to the
running page size, which segfaults at `dlopen`/exec time unless every binary
was linked with `-Wl,-z,max-page-size=16384`. Android's 16K migration docs
describe the same class of bug
(https://source.android.com/docs/core/architecture/16kb-page-size/16kb).
Asahi Linux hits the identical class of failure on Apple Silicon's native
16K pages (https://asahilinux.org/docs/sw/broken-software/): hardened_malloc,
old Electron builds, Waydroid.

That failure mode is exactly what a bootc/podman appliance is built to run
into. The entire point of this image is executing arbitrary OCI container
images via podman, and most published aarch64 container images aren't
compiled with 16K-safe alignment; nothing guarantees a random upstream image
was built expecting anything but 4K. A silent segfault inside a workload
container is a much worse failure mode to debug than a 7% memory-latency gap.

Recommendation: `linux-rpi` (4K). Revisit only if a specific measured
workload needs the throughput and every container it runs has been verified
16K-safe. The two packages `conflict`, so this isn't a soft default; picking
wrong means reinstalling the kernel package, not just flipping a boot flag.

### 2. Pi 5 / BCM2712 dtb coverage, including D0: confirmed

Both `linux-rpi` and `linux-rpi-16k` ship `bcm2712d0-rpi-5-b.dtb` (verified
by direct `find` on the extracted package tree, listed above). `linux-rpi`
additionally carries `bcm2712-rpi-5-b.dtb` and `bcm2712-d-rpi-5-b.dtb`
(a non-D0 variant and a differently punctuated D0 variant), kept as shipped
rather than normalised. No gap here.

### 3. Files to relocate, and to where

Two packages, `raspberrypi-bootloader` and `linux-rpi`/`linux-rpi-16k`, put
files in `/boot`. `firmware-raspberrypi` already lives under `/usr` and
needs nothing.

The sync hook (`rpi-bootc-bootloader`, vendored copy) is the consumer that
must be able to find the relocated files. Its `process_path()` already
computes, per deployment:

```
OSTREEPATH   = the deployment root (readlink -f of ostree=... in the BLS entry)
KVER         = $(ls "$OSTREEPATH/usr/lib/modules/" | head -n 1)
BOOTDIR      = "$OSTREEPATH/usr/lib/modules/$KVER"
DTB_SRC      = readlink -f "$OSTREEPATH/usr/share/raspberrypi2-kernel"*/*/boot/   <- the AlmaLinux-specific line to change
```

and separately reads `$BOOTDIR/rpi-config.txt` for the per-slot firmware
config include. `BOOTDIR` is already computed for that purpose. Reusing it
for the dtbs is the smallest possible patch to the vendored script, and it
keeps the dtb/overlay tree exactly as versioned as the kernel it belongs to.
No separate glob, no drift risk between a kernel and a mismatched dtb set on
upgrade, since `/usr/lib/modules/$kver/` is itself part of the same ostree
commit as everything else in that deployment.

Target layout, proposed:

```
/usr/lib/modules/$kver/vmlinuz                 <- already correct, no change
/usr/lib/modules/$kver/initramfs.img           <- built by dracut, no change
/usr/lib/modules/$kver/dtbs/*.dtb              <- moved from linux-rpi's boot/*.dtb
/usr/lib/modules/$kver/dtbs/overlays/*.dtbo    <- moved from linux-rpi's boot/overlays/*.dtbo
/usr/lib/modules/$kver/rpi-config.txt          <- synthesized in the Containerfile, not shipped by any ALARM package, see blockers
```

One-line patch to the vendored `rpi-bootc-bootloader`:

```diff
- local DTB_SRC=$(readlink -f "$OSTREEPATH/usr/share/raspberrypi2-kernel"*/*/boot/ 2>/dev/null)
+ local DTB_SRC="$BOOTDIR/dtbs"
```

(`sync_dir_with_pattern` already expects `$DTB_SRC/overlays/*` for the
overlays half, which lines up unchanged.)

`raspberrypi-bootloader`'s 16 VideoCore blobs (`start*.elf`, `fixup*.dat`,
`bootcode.bin`) are a different case. The sync hook never touches them; it
only manages the per-slot `bootc/entries/ostree-N/` tree and the
`config-bootc-*.txt` includes. Those blobs are partition-1 content seeded
once when the SD card/disk is provisioned, not something `bootc upgrade`
touches afterward (this matches the known limitation already recorded in
STATUS.md). They still can't stay in `/boot` in the container image, so:

```
/usr/lib/raspberrypi/boot/{bootcode.bin,start*.elf,fixup*.dat}
```

is the proposed parking spot, package-level rather than kernel-version-level
since they're not tied to a specific kernel build. Who reads this path at
provisioning time is not established yet, see Blockers.

### 4. dracut modules for a Pi bootc image

`Containerfile.base` (x86) uses:
`add_dracutmodules+=" ostree bootc crypt dm btrfs tpm2-tss "`

Trimmed recommendation for the Pi target:

```
add_dracutmodules+=" ostree bootc "
```

`ostree` and `bootc` stay unconditionally: `ostree` is mandatory since it's
the whole boot mechanism, and `bootc` is mandatory for the same reason.

Justification for each drop:

`crypt` handles LUKS unlock in the initramfs. The team brief says no LUKS
initially, so drop it; add it back the day disk encryption is scoped in.

`dm` wires in device-mapper, needed by `crypt`, LVM, and dm-verity/composefs
root setups. None of those apply here: no LUKS, no LVM planned, and
composefs is explicitly disabled for this target per the decision already
recorded in STATUS.md. Drop it.

`btrfs` is called out as not needed initially in the team brief, and neither
AlmaLinux's reference (`root-fs-type = "xfs"`) nor the NixOS card (ext4)
roots on btrfs. `btrfs-progs` binaries in the initramfs are dead weight
without a btrfs root. Drop it; this is really a filesystem-choice call for
whoever owns partitioning, and worth revisiting together with that decision
rather than in isolation.

`tpm2-tss` supports TPM-backed unlock and measured boot. Pi 5 has no
on-board TPM, unlike x86 UEFI boxes with fTPM, so there's nothing to measure
into. Drop it; revisit only if a TPM HAT gets added to the hardware plan.

`hostonly=no` must stay explicit (already in `Containerfile.base`'s
`30-archlinux-bootc-container-build.conf` dropin) since the initramfs is
built inside the emulated container, not on the target Pi. Dracut's own
shipped default profile (`usr/lib/dracut/dracut.conf.d/hostonly/`) is
`hostonly=yes` and would produce a host-specific initramfs missing drivers
for whatever hardware isn't present in the build container.

No Pi-specific dracut module is needed for the SD/eMMC storage path. The
generic (non-hostonly) initrd already pulls in `mmc_block`/`sdhci` and
similar via dracut's standard kernel-modules inclusion, same as any other
block device.

### 5. Kernel cmdline for a Pi ostree/bootc system

ALARM's stock `linux-rpi` cmdline.txt, for reference only, not what we'd
ship as-is: `root=/dev/mmcblk0p2 rw rootwait console=serial0,115200
console=tty1 fsck.repair=yes`.

AlmaLinux's reference doesn't hardcode a Pi cmdline at all. Its
`10-rpi/almalinux-10-rpi.yaml` only sets `root-fs-type = "xfs"` in
`/usr/lib/bootc/install/20-rhel.toml` and leaves kernel args to bootc/ostree's
normal BLS generation (`ostree=...` plus whatever `/usr/lib/bootc/kargs.d/`
supplies), the same mechanism `Containerfile.pc` (x86) already relies on.
`bib-config.toml`'s `[customizations.kernel] append` line is present but
commented out, so AlmaLinux ships no extra Pi args by default either.

The NixOS card in STATUS.md took a structurally different route (U-Boot plus
extlinux, `cmdline.txt` left empty, args supplied by `extlinux.conf`'s
`APPEND` line instead), not directly comparable since it isn't bootc/ostree
and doesn't go through `os_prefix`.

For this image, the cmdline is composed by `rpi-bootc-bootloader`'s
`process_path()` itself: it takes the BLS entry's `options` line verbatim
and writes it to `bootc/entries/ostree-N/cmdline.txt` on the vfat partition.
So the actual Pi-specific requirement isn't a hardcoded cmdline string, it's
what to put in `/usr/lib/bootc/kargs.d/` (or the equivalent ostree kargs
source) to merge in, on top of whatever ostree/bootc generate automatically.

`rootwait` should carry over from ALARM's stock cmdline: SD/eMMC/NVMe
controller enumeration can lag past when the kernel tries to mount root, and
without it root-mount races the storage driver and fails intermittently.

`console=serial0,115200` is cheap to keep for headless debug over the Pi's
UART. AlmaLinux doesn't set this but nothing about ostree/bootc conflicts
with it.

No `root=/dev/mmcblkXpY` is needed. bootc/ostree supplies `root=` and
`ostree=` itself from the BLS entry; hardcoding a device path would fight
that mechanism, and it would also break the moment someone boots from NVMe
instead of SD.

No `fsck.repair=yes` equivalent is needed either. ostree's root is the
immutable composed `/usr` plus a read-only `/sysroot`; there's no `/boot`
fsck concern the way ALARM's stock non-bootc image has one.

This still needs to be written down as an actual `kargs.d` file and tested
on hardware before it's a settled decision rather than a comparison,
flagging as open, not blocking the rest of this workstream's output.

## Manifests summary

| package | version | boot-relevant files | relocation needed |
| --- | --- | --- | --- |
| linux-rpi | 6.18.50-1 | vmlinuz (already correct) plus 26 dtb, 386 overlays, kernel8.img/config.txt/cmdline.txt in `/boot` | dtbs and overlays go to `/usr/lib/modules/$kver/dtbs/`; kernel8.img/config.txt/cmdline.txt discarded, unused under bootc |
| linux-rpi-16k | 6.18.50-1 | same shape, 8 BCM2712-only dtbs | same, not used, see decision 1 |
| raspberrypi-bootloader | 20260907-1 | 16 VideoCore blobs, flat in `/boot`, nothing under `/usr` | to `/usr/lib/raspberrypi/boot/`, provisioning-time consumer not yet identified |
| firmware-raspberrypi | 20260311-1 | none, already under `/usr/lib/firmware/updates/{brcm,cypress}/` | none |
| linux-firmware | 20260810-2 | meta-package, 0 files of its own | not used, Pi wifi/BT already covered by firmware-raspberrypi |
| raspberrypi-utils | 20260904-1 | `/usr/bin/vcmailbox`, `/usr/bin/vcgencmd`, both confirmed | none, already correct path |
| dracut | 111-1 | 2 pacman hooks plus 2 kernel-install plugins, none Pi-specific | none to relocate; neutralised the same way `Containerfile.base` already does, populate `/usr` targets, then `rm -rf /boot` at the end |

## Blockers

`rpi-config.txt` has no source package. AlmaLinux's kernel RPM ships one per
kernel build; nothing in the ALARM package set produces an equivalent. It
has to be authored as part of this build (a Containerfile step), not sourced
from a package. Small, but it's new content someone has to write and keep in
sync with `config.txt`'s `[cm5]`/`[cm4]` sections.

There's no identified consumer for the relocated VideoCore blobs
(`/usr/lib/raspberrypi/boot/`) at initial provisioning time. The sync hook
only manages the `bootc/entries/ostree-N/` tree on an already-provisioned
vfat partition; it never writes `start4.elf` and friends. AlmaLinux's own
repo has no visible seeding step for this either (checked `bib-config.toml`,
`Makefile`, `design.md`, none reference it). This is the
first-boot/disk-image-build problem, out of this workstream's scope, but the
chosen path won't be validated until whoever owns that step reads from it.

Kernel cmdline (`kargs.d` content) is a proposal, not a tested decision. It
needs the Pi on the network to confirm `rootwait` and the serial console
actually behave as expected under the `os_prefix` boot chain.

Not a blocker, just worth stating plainly: nothing here has been built or
booted. This is a package-content audit only.
