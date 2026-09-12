# A plain SD-card image: GPT-less MBR, one FAT firmware partition, one ext4
# root. No ostree, no bootc. This exists to answer one question -- does this
# Pi 5, this card and this reader boot a NixOS kernel at all -- before any of
# the image-based machinery is layered on top.
{ config, lib, pkgs, modulesPath, ... }:

let
  kernelImage = "${config.boot.kernelPackages.kernel}/${config.system.boot.loader.kernelFile}";
  initrdImage = "${config.system.build.initialRamdisk}/${config.system.boot.loader.initrdFile}";
  fwBoot = "${pkgs.raspberrypifw}/share/raspberrypi/boot";

  cmdline = lib.concatStringsSep " " (
    config.boot.kernelParams ++ [ "init=${config.system.build.toplevel}/init" ]
  );

  # The Pi 5 firmware reads this off the FAT partition before anything else
  # exists. `kernel=` and `initramfs` name files at the root of that partition.
  configTxt = pkgs.writeText "config.txt" ''
    [all]
    arm_64bit=1
    enable_uart=1
    uart_2ndstage=1
    kernel=Image
    initramfs initrd followkernel
    disable_overscan=1
    camera_auto_detect=1
    display_auto_detect=1
  '';
in
{
  imports = [ (modulesPath + "/installer/sd-card/sd-image.nix") ];

  # nixos-hardware's raspberry-pi/common/firmware.nix installs its own
  # populateFirmwareCommands with lib.mkForce the moment an sdImage module is
  # in scope. Its script stages the VideoCore blobs and every Pi 0-4 DTB and
  # then stops -- it never copies a kernel, because it assumes U-Boot will
  # fetch one over extlinux. Left enabled, it overrides the block below and
  # produces a FAT partition with nothing bootable on it.
  hardware.raspberry-pi.firmware.enable = lib.mkForce false;

  sdImage = {
    imageBaseName = "nixos-rpi5";
    compressImage = false;
    firmwareSize = 512;

    populateFirmwareCommands = lib.mkForce ''
      cp ${fwBoot}/bootcode.bin firmware/ 2>/dev/null || true
      cp ${fwBoot}/start*.elf    firmware/
      cp ${fwBoot}/fixup*.dat    firmware/

      # The base DTB has to match the kernel, so it comes from the kernel, not
      # from the firmware package. The overlays directory comes from the
      # firmware package because the VideoCore firmware itself reads
      # overlay_map.dtb and hat_map.dtb out of it, and the kernel tree has
      # neither.
      cp ${config.boot.kernelPackages.kernel}/dtbs/broadcom/bcm2712*-rpi-5*.dtb firmware/
      mkdir -p firmware/overlays
      cp -r ${fwBoot}/overlays/. firmware/overlays/

      cp ${kernelImage} firmware/Image
      cp ${initrdImage} firmware/initrd
      cp ${configTxt}   firmware/config.txt
      echo '${cmdline}' > firmware/cmdline.txt
    '';

    populateRootCommands = ''
      mkdir -p ./files/boot
    '';
  };
}
