# bootc-rpi — status

Working dir: `/var/home/bupd/code/rpi`. Goal: bootable-container image for Raspberry Pi
(aarch64) that supports `bootc upgrade` / rollback, extending the existing
`oci-native/archlinux` design.

Updated: 2026-09-11

## Goals

Two tracks, and they feed each other.

1. **A bootc Pi 5 image.** Reproducible aarch64 Arch bootable container that runs on a
   Raspberry Pi 5 and supports `bootc upgrade` and rollback. Target repo
   `oci-native/archlinux-rpi`.
2. **Official Raspberry Pi 5 support in Arch Linux ARM.** Prasanth wants this as a real
   deliverable and as our first upstream contribution. Working hypothesis: most of the
   packaging already exists, since `linux-rpi` 6.18.50-1 builds for aarch64 and ships both
   `bcm2712-rpi-5-b.dtb` and `bcm2712d0-rpi-5-b.dtb`, `raspberrypi-bootloader` is at
   20260907-1, and `raspberrypi-utils` provides `vcmailbox`. If that holds, the gap is a
   tested install path and a platform page, not missing code. The `alarmcontrib` agent is
   confirming or destroying that hypothesis.

Track 1 produces exactly the evidence track 2 needs: two Pi 5 boards, boot logs, and a
verified install procedure.

## Phase 1 — feasibility spike


## Phase 1 verdict — feasibility: YES, via AlmaLinux's route


Decided 2026-09-11. Reference architecture is `AlmaLinux/bootc-images-rpi` plus
`kfox1111/rpi-bootc-bootloader` v0.0.8. Both read in full.

### Boot route: native Pi firmware. No UEFI, no U-Boot, no GRUB.

The VideoCore firmware is itself the A/B bootloader. bootc/ostree writes ordinary BLS
entries to `/boot/loader/entries/ostree-{1,2}.conf`; a drop-in on
`ostree-finalize-staged.service` runs a sync hook that mounts the vfat firmware
partition and populates, per slot:

    bootc/entries/ostree-N/{vmlinuz,initrd,cmdline.txt,*.dtb,overlays/,rpi-config.txt}
    config.txt -> include config-bootc-default.txt -> os_prefix=bootc/entries/ostree-N/

`os_prefix` is the slot switch and is a stock firmware feature. It also buys:

- rollback via `[gpio6=1]`/`[gpio6=0]` config.txt filters (physical button on GPIO6),
- auto-rollback via `tryboot.txt` + `vcmailbox 0x00038064 4 4 1` + `dtparam=watchdog=on`,
- no bootupd at all (AlmaLinux even strips `efibootmgr` out of `bootupd.yaml`).

Rejected alternatives, with reasons:

- **UEFI.** `pftf/RPi5` does not exist (404). `worproject/rpi5-uefi` archived 2025-02-04.
  `NumberOneGit/rpi5-uefi` is the only live fork, last tag v0.1 (2025-05-07), RP1
  ethernet non-functional. Tianocore edk2-platforms has no RaspberryPi5 directory.
  `pftf/RPi4` is healthy (v1.53, 2026-08-31) but we have a Pi 5.
- **U-Boot.** Mainline gained Pi5 PCIe/RP1 in v2026.07, but `CONFIG_NVME_PCI` is still
  absent from `rpi_arm64_defconfig`, and ALARM ships `uboot-raspberrypi` 2025.01-2, two
  cycles behind that work. openSUSE runs this chain and still reports USB boot and NVMe
  broken. It also conflicts with `linux-rpi`.
- **bootupd.** `coreos/bootupd#651` and `#959` (ARM firmware payloads) are open and
  unmerged; PR #1073 validated on a real Pi 4 but not merged as of today. Nothing to
  wait for.

### bootc storage backend: ostree. composefs deployment format: kept on

Corrected 2026-09-11. An earlier version of this document said the Pi image had to set
`composefs enabled = no`, on the grounds that `--bootloader=none` is unsupported on the
composefs backend. That reasoning conflated two separate things that share a word.

`[composefs] enabled` in `/usr/lib/ostree/prepare-root.conf` controls whether the **ostree
backend** stores its per-deployment checkouts as composefs images, for fsverity and
integrity. It still keeps `/ostree/repo`, `/sysroot/ostree/deploy/...` and
`/boot/loader/entries/ostree-N.conf`, which are exactly the paths the sync hook reads.

`--composefs-backend` is a different thing: bootc's experimental composefs-rs storage
backend, with its own on-disk format at `/composefs` and `/state/deploy/...` and no ostree
repository at all. That is what `--bootloader=none` cannot be combined with.

Verified empirically rather than argued. `quay.io/almalinuxorg/almalinux-bootc-rpi:10`,
pulled and inspected directly, ships:

    [composefs]
    enabled = yes
    [sysroot]
    readonly = true

That image is reported working on real Pi 3, 4 and 5 hardware through the same
native-firmware boot path this project is copying. It also matches the x86_64 sibling,
whose `Taskfile.yml` validate task already asserts `enabled = yes` as an invariant.

So: keep composefs enabled, use the ostree backend, pass `--bootloader none`, do not pass
`--composefs-backend`, and do not ship a UKI, because a UKI makes bootc select the
composefs backend automatically. This is now one less divergence from `Containerfile.pc`,
not one more.

### Base: Arch (ALARM), confirmed stocked

Checked against the live ALARM aarch64 package databases on 2026-09-11:

| package | version | note |
| --- | --- | --- |
| `linux-rpi` | 6.18.50-1 | built 2026-09-09, RPi downstream kernel, 4K pages |
| `linux-rpi-16k` | 6.18.50-1 | 16K pages, the Pi 5 `kernel_2712` equivalent |
| `linux-aarch64` | 7.2.4-1 | mainline, not used here |
| `raspberrypi-bootloader` | 20260907-1 | VideoCore firmware blobs |
| `firmware-raspberrypi` | 20260311-1 | wifi/BT |
| `dracut` | 111-1 | so no mkinitcpio bridge is needed |
| `ostree` | 2026.4-1 | |
| `composefs` | 1.0.8-1 | present but deliberately unused |
| `systemd` | 261.2-1 | matches x86_64 Arch exactly |

`linux-rpi` depends on mkinitcpio and conflicts with `uboot-raspberrypi`, confirming the
direct-kernel-boot model. Use dracut anyway and mask the mkinitcpio hooks, matching
`Containerfile.base`.

### Two gaps to close, both small

1. **No aarch64 Arch container base exists.** `docker.io/archlinux/archlinux:latest` is a
   single amd64 manifest, not a manifest list (verified locally). ALARM publishes no
   first-party OCI image. Bootstrap `FROM scratch` from
   `ArchLinuxARM-aarch64-latest.tar.gz` (mirror copy dated 2026-08-05).
2. **dtb location.** AlmaLinux's kernel RPM puts dtbs at
   `/usr/share/raspberrypi2-kernel*/*/boot/` and the sync hook hardcodes that glob.
   Arch's `linux-rpi` puts them under `/boot`, which bootc requires to be empty. Relocate
   to `/usr/lib/raspberrypi/boot/` at build time and change `DTB_SRC` in a vendored copy
   of the hook. That is the entire port.

### Build-host notes

- Build bootc for aarch64 in a `--platform=$BUILDPLATFORM` cross-compile stage and
  `COPY --from=` the binary, so no aarch64 binary executes under qemu-user during the
  build. That avoids the SIGILL-on-freshly-built-binary class of bug and bootc's own
  `bwrap` EINVAL issue under emulation.
- `bootc container lint` needs `--skip var-tmpfiles --skip utf8` under qemu-user
  (`set_robust_list` returns ENOSYS; bootc-dev/bootc#1481, still open). Run the unskipped
  lint on the Pi.

### Known limitations, accepted

- `bootc upgrade` moves kernel, initrd, dtbs and overlays. It does **not** update the
  VideoCore firmware or the EEPROM. AlmaLinux documents the same gap. On a Pi 5 the
  second-stage firmware lives in EEPROM anyway, so this mostly means
  `raspberrypi-bootloader` updates in the image need a manual sync or a reimage.
- ALARM is effectively single-maintainer. Leaf packages track upstream closely
  (`systemd` 261.2 matches x86_64 exactly, `linux-rpi` is 2 days old), but the toolchain
  batches: `glibc` 2.43+r22 and `gcc` 16.1.1 are both ~3 months behind x86_64 Arch.
  Acceptable for an appliance image, worth stating out loud.

## Phase 2 — hardware inventory


Neither documented Pi is usable right now.

| Target | Address | Result |
| --- | --- | --- |
| `node1` | <build-host> | **Not a Pi.** This address belongs to this build host (`enp10s0`). SSH to it tripped a host-key mismatch because it is the local sshd. |
| `node2` | <node2> | Offline. No ARP reply, 100% packet loss. |

LAN sweep of <gateway>-60 found only .1 (router), .2, and .5 (this host). No Pi is on
the network.

The k3s cluster is a **single node and it is this x86_64 box** (`oci-native-archlinux`,
control-plane, v1.36.4+k3s1, 11 days uptime). No Pi participates in it, so no Pi work
can disrupt the live services.

**Open question for Prasanth:** where are the Pis physically, which models, and is the
plugged-in `citadel` card expendable?

## Phase 3 — build and test


Not started. Layout decision (new repo here vs. a `Containerfile.rpi` inside
`oci-native/archlinux`) still needs a call from Prasanth.

## Team

Five agents running under Herdr in workspace w2, all Sonnet at high effort, all working
out of this directory. Shared context lives in `docs/TEAM-BRIEF.md`.

| agent | owns | writes |
| --- | --- | --- |
| `almaport` | line-by-line spec of the AlmaLinux mechanism and the exact Arch diff | `docs/port-spec.md`, `docs/rpi-bootc-bootloader.arch-proposed` |
| `alarmbase` | building a trustworthy aarch64 Arch rootfs, since none is published | `docs/base-image.md`, `Containerfile.rootfs` |
| `bootcbuild` | cross-compiling the bootc binary for aarch64 without running it under qemu | `docs/bootc-build.md`, `Containerfile.bootc` |
| `kernellayout` | real package manifests for `linux-rpi`, firmware, dtbs, and the dracut config | `docs/kernel-layout.md` |
| `distroscout` | adversarial review of the Arch choice, and harvesting `bootcrew/mono` | `docs/base-distro-eval.md` |

## Decisions


1. Native Pi firmware boot with `os_prefix` A/B, ported from AlmaLinux. No UEFI, no
   U-Boot, no bootupd.
2. ostree backend, composefs disabled, for this target only.
3. Arch via ALARM aarch64, `linux-rpi` kernel, dracut initramfs.
4. New repo `oci-native/archlinux-rpi`. Nothing pushed until the layout is approved.
5. Target hardware is a Pi 5. The `citadel` SD card is treated as expendable, but I will
   confirm again at the moment of writing to it.

## Blockers


None blocking the build. Still open: Pi 5 is not yet on the network, so the first boot
test needs the card written and the board attached.

### Already established from local evidence

The SD card plugged into this host is prior art and answers part of the boot question.
It is a NixOS aarch64 SD image, hostname `citadel`, last written 2026-07-20:

- MBR/dos label. p1 `FIRMWARE` FAT16 30 MiB, p2 `NIXOS_SD` ext4 59.4 GiB.
- `config.txt` sets `kernel=u-boot.bin`. The VideoCore firmware loads U-Boot, not a
  kernel. `cmdline.txt` is empty.
- U-Boot then reads `/boot/extlinux/extlinux.conf` off the ext4 root, which points at
  `LINUX`/`INITRD`/`FDTDIR` under `/boot/nixos/`.
- Kernel is mainline `6.18.39`, with `FDTDIR` pointing at the full mainline dtb tree
  (`broadcom/bcm2711-rpi-4-b.dtb`, `bcm2712-rpi-5-b.dtb`, `bcm2837-*` all present).
- The firmware partition carries `start4*.elf`/`fixup4*.dat` plus `bcm2712-*` dtbs and
  a `[pi5]` section in config.txt, so the image targets Pi 3 / 4 / 5 from one card.
- `/etc/nixos/configuration.nix` uses `boot.loader.generic-extlinux-compatible` and
  installs `bootc`, `ostree`, `skopeo`, `podman`, `buildah` — an earlier attempt at
  this same goal. The default extlinux entry is labelled
  `NixOS bootc OCI - ttl.sh/bupd/nix-bootc:latest`.

So: firmware -> U-Boot -> extlinux is a proven-working chain on this hardware with a
mainline kernel. Whether bootc can drive that chain (rather than an ESP + systemd-boot)
is the open question the research threads are answering.

Card was mounted read-only through udisks and unmounted again. Nothing was written.

### Build host capability (verified)

- `oci-native-archlinux`, ASUS PRIME B550M-K, x86_64, 12 cores, 31 GiB RAM, 521 GiB free
  on `/var`. Itself an Arch bootc host on LUKS+Btrfs, kernel 7.2.4-arch1-2.
- podman 6.1.1 rootless, buildah 1.45.0.
- `qemu-user-static` 11.1.1 with binfmt `qemu-aarch64` registered, flags `PF` (the `F`
  fix-binary flag is set, which is the one containers need).
- Verified end to end: `podman run --platform linux/arm64 alpine uname -m` -> `aarch64`.
- Gap: no `qemu-system-aarch64` installed, needed for VM boot tests.

