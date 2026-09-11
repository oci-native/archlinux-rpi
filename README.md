# Arch Linux bootc image for the Raspberry Pi 5

An aarch64 Arch Linux bootable container for the Raspberry Pi 5, built so that
`bootc upgrade` and `bootc rollback` work the way they do on a normal UEFI machine.

This is the Raspberry Pi sibling of [oci-native/archlinux](https://github.com/oci-native/archlinux).
Same idea, same tooling, different boot chain.

## Why the boot chain is the interesting part

A Raspberry Pi has no UEFI. The VideoCore firmware reads `config.txt` off a FAT
partition and loads a kernel directly. bootc's usual world assumes an EFI system
partition, a boot loader, and `bootupd` to keep that loader updated. None of that
exists here, and `bootupd` has no Raspberry Pi support (coreos/bootupd#651 and #959
are both still open).

The way through, borrowed from [AlmaLinux/bootc-images-rpi](https://github.com/AlmaLinux/bootc-images-rpi),
is to let the firmware be the A/B boot loader. bootc and ostree write ordinary boot
loader entries. A hook on `ostree-finalize-staged.service` then mirrors each
deployment's kernel, initramfs, device trees and command line onto the FAT partition
under its own directory, and points `os_prefix` in `config.txt` at whichever one should
boot next:

    bootc/entries/ostree-1/{vmlinuz,initrd,cmdline.txt,*.dtb,overlays/}
    bootc/entries/ostree-2/{...}
    config.txt -> os_prefix=bootc/entries/ostree-N/

`os_prefix` is a stock firmware feature, and three useful things fall out of it. The
firmware's `[gpio6=1]` conditional lets a physical button select the other slot. The
`tryboot` flag plus `dtparam=watchdog=on` reverts a deployment that fails to come up.
And there is no boot loader to update, so nothing needs `bootupd` at all.

## Status

Early. Nothing has booted yet. See `STATUS.md` for what is decided, what is verified,
and what is still open, and `docs/` for the research behind each decision.

Two Raspberry Pi 5 boards are being used for hardware verification.

## Layout

| path | what it is |
| --- | --- |
| `Containerfile.rootfs` | bootstraps an aarch64 Arch rootfs, since none is published as a container image |
| `Containerfile.base` | the bootc base: kernel, dracut initramfs, ostree layout |
| `Containerfile.rpi` | Raspberry Pi 5 specifics: firmware, device trees, the sync hook |
| `shared/` | scripts shared between build stages |
| `docs/` | design notes and the research each decision rests on |

## Related

- [oci-native/archlinux](https://github.com/oci-native/archlinux) is the x86_64 sibling.
- [AlmaLinux/bootc-images-rpi](https://github.com/AlmaLinux/bootc-images-rpi) is the
  reference architecture and, so far, the only working example of bootc booting a
  Raspberry Pi through native firmware.
- [kfox1111/rpi-bootc-bootloader](https://github.com/kfox1111/rpi-bootc-bootloader) is
  the sync hook that makes it work. We vendor a patched copy rather than fetching it at
  build time.
