# bootc-rpi team brief

Read this first, then `STATUS.md` in the repo root. Every agent on this project shares
this context. Do not re-derive it.

## Goal

A bootable container (bootc) OS image for a Raspberry Pi 5, aarch64, that supports
`bootc upgrade` and rollback. Target repo name `oci-native/archlinux-rpi`. Working
directory is `/var/home/bupd/code/rpi`. Nothing is pushed anywhere until Prasanth
approves the layout.

## Settled decisions — do not relitigate

1. **Boot route: native Raspberry Pi firmware.** No UEFI, no U-Boot, no GRUB, no bootupd.
   The VideoCore firmware acts as the A/B bootloader through `os_prefix` in `config.txt`.
   This is the mechanism `AlmaLinux/bootc-images-rpi` uses and it is proven on Pi 3/4/5.
2. **bootc storage backend: ostree. composefs deployment format: ON.** These are two
   different things that share a word, and an earlier version of this brief conflated them.
   `[composefs] enabled = yes` in `/usr/lib/ostree/prepare-root.conf` is an ostree-internal
   setting for whether deployment checkouts are stored as composefs images. It still uses
   `/ostree/repo`, `/sysroot/ostree/deploy/...` and `/boot/loader/entries/ostree-N.conf`,
   which are the paths the sync hook reads, so it is compatible and we keep it on, matching
   both AlmaLinux and the x86_64 sibling image. What `--bootloader=none` cannot be combined
   with is bootc's separate `--composefs-backend`, an experimental composefs-rs storage
   backend with its own on-disk format at `/composefs`. Do not pass that flag, and do not
   ship a UKI, since a UKI makes bootc select that backend automatically.
3. **Initramfs: dracut**, matching the existing x86_64 image. Not mkinitcpio.

## Reference material, already cloned locally

- `/tmp/claude-1000/-var-home-bupd-code-rpi/74fac201-f524-4cfa-b355-37e3ee2b3f9c/scratchpad/bootc-images-rpi`
  — AlmaLinux's Pi bootc images. Read `10-rpi/Containerfile`, `10-rpi/kernel.yaml`,
  `config.txt`, `bib-config.toml`, `Makefile`.
- `/tmp/claude-1000/-var-home-bupd-code-rpi/74fac201-f524-4cfa-b355-37e3ee2b3f9c/scratchpad/rpi-bootc-bootloader`
  — kfox1111's sync hook, v0.0.8. The script `rpi-bootc-bootloader` and
  `system/ostree-finalize-staged.service.d/rpi-bootc-bootloader.conf` are the whole trick.
  `design.md` explains the GPIO6 rollback button and tryboot/watchdog scheme.
- `/home/bupd/Projects/archlinux` — Prasanth's existing x86_64 Arch bootc builder.
  `Containerfile.base`, `Containerfile.pc`, `Taskfile.yml`,
  `docs/laptop-bootc-architecture.md`. The Pi target should look like a sibling of this,
  not a separate invention.

## How AlmaLinux's boot chain works

bootc/ostree writes ordinary BLS entries to `/boot/loader/entries/ostree-{1,2}.conf`.
A drop-in on `ostree-finalize-staged.service` runs `rpi-bootc-bootloader finalize-staged`
after every staged deployment. That script mounts the vfat firmware partition (partition
1 of whatever device holds `/sysroot`) and writes, per slot N:

    bootc/entries/ostree-N/vmlinuz
    bootc/entries/ostree-N/initrd
    bootc/entries/ostree-N/cmdline.txt      <- the BLS entry's `options` line
    bootc/entries/ostree-N/*.dtb
    bootc/entries/ostree-N/overlays/*
    bootc/entries/ostree-N/rpi-config.txt

then regenerates `config.txt`, `config-bootc-default.txt`, `config-bootc-fallback.txt`
and `tryboot.txt`. `os_prefix=bootc/entries/ostree-N/` selects the slot. `[gpio6=1]` and
`[gpio6=0]` firmware filters give a physical rollback button. `vcmailbox 0x00038064 4 4 1`
sets the tryboot flag and `dtparam=watchdog=on` reverts a slot that fails to come up.

## Arch package availability, verified 2026-09-11 against live ALARM aarch64 databases

`linux-rpi` 6.18.50-1 (built 2026-09-09) · `linux-rpi-16k` 6.18.50-1 (16K pages, the Pi 5
`kernel_2712` equivalent) · `linux-aarch64` 7.2.4-1 (mainline) · `raspberrypi-bootloader`
20260907-1 · `firmware-raspberrypi` 20260311-1 · `dracut` 111-1 · `ostree` 2026.4-1 ·
`composefs` 1.0.8-1 · `systemd` 261.2-1 · `podman` 6.1.1-1 · `skopeo` 1.24.0-1 ·
`btrfs-progs` 7.1-1 · `cryptsetup` 2.8.8-1.

`linux-rpi` depends on mkinitcpio, `raspberrypi-bootloader` and `firmware-raspberrypi`,
provides `raspberrypi-overlays`, and conflicts with `uboot-raspberrypi`.

## Known gaps

1. **No aarch64 Arch container base exists.** `docker.io/archlinux/archlinux:latest` is a
   single amd64 manifest, not a manifest list. ALARM publishes no first-party OCI image.
   Bootstrap from `http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz`
   (generic aarch64; the `-rpi-` variant preinstalls a kernel and is not what we want).
2. **dtb location.** AlmaLinux's kernel RPM parks dtbs under
   `/usr/share/raspberrypi2-kernel*/*/boot/` and the sync hook hardcodes that glob. Arch's
   `linux-rpi` puts them under `/boot`, which bootc requires to be empty in the image.
   They must be relocated into `/usr` and the hook's `DTB_SRC` changed to match.
3. **Nothing seeds the VideoCore firmware onto the vfat partition.** The sync hook only
   manages the `bootc/entries/ostree-N/` tree on an already-provisioned partition. It never
   writes `start4.elf`, `fixup4.dat`, `bootcode.bin`. AlmaLinux has no seeding step in the
   container either, which is why their README says `bootc-image-builder` alone is not
   enough and firmware updates may need a reimage. We have to own this in our disk-image
   build. Owned by the `diskimage` agent.

## Corrections to this brief, from `kernellayout`, 2026-09-11

Verified by extracting the real packages. Supersedes anything above that conflicts.

- `linux-rpi` already installs the kernel at `/usr/lib/modules/$kver/vmlinuz`, which is
  exactly bootc's required path. No relocation needed for the kernel itself.
- **No pacman hook and no `.INSTALL` scriptlet writes to `/boot`.** An earlier version of
  this brief guessed that one did. It does not. The `/boot` content is simply files the
  package ships (26 dtbs, 386 overlays, plus `kernel8.img`/`config.txt`/`cmdline.txt`,
  415 files total), and `rm -rf /boot` at the end of the build is sufficient, the same way
  `Containerfile.base` already handles it.
- **dtb relocation target is `/usr/lib/modules/$kver/dtbs/`**, not a standalone path. The
  sync hook already computes `$BOOTDIR` for `rpi-config.txt`, so the whole Arch patch is
  one line: `DTB_SRC="$BOOTDIR/dtbs"`. It also keeps dtbs versioned with the kernel through
  the ostree commit instead of a separate glob.
- The VideoCore blobs from `raspberrypi-bootloader` still go to `/usr/lib/raspberrypi/boot/`.
- `raspberrypi-utils` 20260904-1 provides `/usr/bin/vcmailbox` and `/usr/bin/vcgencmd`, so
  the tryboot rollback path is available to us.
- `firmware-raspberrypi` already installs under `/usr/lib/firmware/updates/{brcm,cypress}/`.
  Nothing to move, and `linux-firmware` is not needed.
- **Kernel choice: `linux-rpi` (4K pages), not `linux-rpi-16k`.** Raspberry Pi OS does
  default to 16K on Pi 5 for roughly 7% performance, but 16K pages break a long list of
  userspace on ELF alignment, including QEMU/KVM, Wine, Box86/64 and older Chromium. This
  image is a container host, and most published container images are not built 16K-safe.
  Revisit only with workloads verified 16K-safe.
- Both kernels ship `bcm2712d0-rpi-5-b.dtb`, so the Pi 5 D0 stepping is covered.
- **dracut modules trim to `ostree bootc` only.** Drop `crypt`, `dm` (no LUKS or LVM),
  `btrfs` (no btrfs root planned) and `tpm2-tss` (the Pi 5 has no TPM). Keep `hostonly=no`.
- **Kernel cmdline: do not hardcode `root=`.** bootc/ostree supplies `root=` and `ostree=`
  from the BLS entry, and hardcoding a device path breaks booting from NVMe instead of SD.
  Keep `rootwait` for the storage enumeration race and `console=serial0,115200` for
  headless debug. Untested on hardware so far.
- `rpi-config.txt` has no source package in Arch. AlmaLinux's kernel RPM ships one per
  build. We have to author it in the Containerfile and keep it in sync with `config.txt`.

## Build host

`oci-native-archlinux`, x86_64, 12 cores, 31 GiB RAM, 521 GiB free on `/var`. Rootless
podman 6.1.1, buildah 1.45. `qemu-user-static` 11.1.1 with binfmt `qemu-aarch64`
registered carrying the `F` flag. `podman run --platform linux/arm64` is verified working.
No `qemu-system-aarch64` yet.

**Cross-build rule:** never execute a freshly built aarch64 binary during an emulated
build. Build such binaries in a `--platform=$BUILDPLATFORM` stage and `COPY --from=` the
result. This avoids the well-documented SIGILL/SIGSEGV class of qemu-user bugs. Also,
`bootc container lint` needs `--skip var-tmpfiles --skip utf8` under emulation
(`set_robust_list` returns ENOSYS, bootc-dev/bootc#1481, open).

## Hardware

**Two** Raspberry Pi 5 boards are on hand, neither yet on the network. Two boards means we
can test a fresh install and a clean-room repeat of our own instructions, and can compare
kernel or config variants on identical hardware. Board revision matters: Pi 5 rev 1.0 vs
rev 1.1 and the D0 stepping differ, and we do not know ours yet. `node2` (<node2>) is offline;
<build-host> is this x86_64 build host, not a Pi. A 64 GB SD card is plugged in at
`/dev/sdb` carrying a previous NixOS aarch64 experiment (`citadel`). Treat it as
expendable, but **never write to `/dev/sdb` without asking Prasanth at that moment.**

## House rules

- Read-only on any running Pi until explicitly authorised.
- No pushes to any repo until the layout is approved. Never merge a PR.
- Commits: conventional, capitalised subject, DCO sign-off
  `Signed-off-by: Prasanth Baskar <prasanth@8gears.com>`. No AI attribution of any kind.
- Prose in docs and READMEs must read like a person wrote it. No em dashes, no
  "not X but Y" constructions, no bold-label bullet lists, no inflated significance.
- Report back compressed: findings, decisions, blockers. No filler.
