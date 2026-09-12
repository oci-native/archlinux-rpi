# Boot the Pi 5 the way the Pi firmware wants to boot it: no U-Boot, no
# extlinux, no UEFI. The VideoCore bootloader reads config.txt off the FAT
# partition, loads the kernel and initrd named there, and jumps straight in.
#
# nixos-hardware's raspberry-pi-5 module defaults to
# generic-extlinux-compatible, which means U-Boot. We take that back out.
{ lib, pkgs, ... }:

{
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = lib.mkForce false;

  # nixos-hardware defaults to the Raspberry Pi vendor kernel, built from the
  # raspberrypi/linux fork. That derivation is not in cache.nixos.org, and
  # building an aarch64 kernel through binfmt emulation costs hours. Mainline
  # has carried BCM2712 support since 6.8 and is prebuilt for aarch64, so the
  # first iteration uses it. Swap this back if mainline turns out to be missing
  # something the Pi 5 needs.
  boot.kernelPackages = lib.mkForce pkgs.linuxPackages_latest;

  # The firmware hands the kernel its cmdline through cmdline.txt, so nothing
  # here needs a bootloader-managed entry.
  boot.kernelParams = [
    "console=serial0,115200"
    "console=tty1"
    "rootwait"
  ];

  # The Pi 5's SD slot is sdio1 / mmc@fff000, compatible "brcm,bcm2712-sdhci",
  # which drivers/mmc/host/sdhci-brcmstb.c claims. It is NOT the
  # raspberrypi,rp1-dwcmshc controller -- that one is RP1's own, and it is
  # status = "disabled" on a Pi 5 B. Every image this project built before
  # today force-loaded sdhci-of-dwcmshc instead, which is the wrong driver.
  boot.initrd.availableKernelModules = [
    "sdhci_brcmstb"
    "sdhci_pltfm"
    "mmc_block"
    "usb_storage"
    "uas"
  ];

  # enableRedistributableFirmware drags in linux-firmware, which is 1.95 GB on
  # aarch64 and almost entirely for hardware a Pi does not have. The Pi's own
  # wifi and bluetooth blobs come from raspberrypiWirelessFirmware, 3.6 MB --
  # and they are not in upstream linux-firmware at all, so this is not a
  # trade of completeness for size.
  hardware.enableRedistributableFirmware = lib.mkForce false;
  hardware.firmware = [ pkgs.raspberrypiWirelessFirmware ];
}
