# Make a NixOS system deployable by ostree.
#
# The boot handoff:
#
#   Pi firmware loads kernel+initrd from the FAT partition
#     -> NixOS systemd stage 1 comes up, mounts the physical root at /sysroot
#     -> ostree-prepare-root turns /sysroot into the deployment
#     -> initrd-find-nixos-closure reads init= off the cmdline
#     -> initrd-nixos-activation chroots in and runs activation
#     -> switch-root
#
# Everything after ostree-prepare-root is stock NixOS. The only thing this
# module adds to the boot path is that one step. Every project that does this
# today gets it from dracut's 50ostree module; NixOS has no dracut, so it is
# a unit here instead.
{ config, lib, pkgs, ... }:

let
  # ostree-prepare-root reads the copy of prepare-root.conf that is inside the
  # initramfs, not the one in /usr. Shipping it in only one of the two places
  # leaves every setting in it inert -- composefs silently falls back to
  # "maybe" and the sysroot comes up writable.
  prepareRootConf = pkgs.writeText "prepare-root.conf" ''
    [composefs]
    enabled = yes

    [sysroot]
    readonly = true
  '';
in
{
  # The physical root partition, which stage 1 mounts at /sysroot before
  # ostree-prepare-root pivots into the deployment inside it.
  fileSystems."/" = {
    device = "/dev/disk/by-label/root";
    fsType = "ext4";
  };

  # nixos-raspberrypi installs kernel, initrd, cmdline.txt and config.txt onto
  # the firmware partition from an activation script. Under ostree that
  # partition belongs to bootc's raspberry-pi backend, which writes one slot
  # directory per deployment and an os_prefix pointing at it. Two writers, one
  # partition, and the activation one has no idea about slots.
  boot.loader.raspberry-pi.enable = lib.mkForce false;
  # ...and nothing else takes over: bootc owns boot entirely. Without this
  # NixOS falls back to GRUB and asserts on boot.loader.grub.devices.
  boot.loader.grub.enable = lib.mkForce false;
  boot.loader.generic-extlinux-compatible.enable = lib.mkForce false;

  boot.initrd.systemd.enable = true;

  # If stage 1 fails, drop to a shell on the console instead of hanging. With
  # a console now configured this turns a silent brick into a readable error,
  # which is the only way ostree-prepare-root failing inside a NixOS initrd
  # will ever be diagnosable.
  boot.initrd.systemd.emergencyAccess = true;

  # composefs needs all three: an EROFS metadata image on a loop device with
  # overlayfs stacked over it.
  boot.initrd.availableKernelModules = [ "erofs" "overlay" "loop" ];

  boot.initrd.systemd.storePaths = [ "${pkgs.ostree}/lib/ostree/ostree-prepare-root" ];

  boot.initrd.systemd.contents."/usr/lib/ostree/prepare-root.conf".source = prepareRootConf;

  boot.initrd.systemd.services.ostree-prepare-root = {
    description = "Turn /sysroot into the ostree deployment";
    unitConfig = {
      DefaultDependencies = false;
      # ostree-prepare-root reads ostree= from /proc/cmdline itself. Without
      # it there is no deployment to prepare, so the unit must not run -- that
      # is what lets the same image boot as a plain NixOS system too.
      ConditionKernelCommandLine = "ostree";
    };
    requires = [ "sysroot.mount" ];
    after = [ "sysroot.mount" ];
    before = [
      "initrd-root-fs.target"
      # Must precede this: it resolves init= against /sysroot, which is not
      # the deployment until ostree-prepare-root has run.
      "initrd-find-nixos-closure.service"
    ];
    requiredBy = [ "initrd-root-fs.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.ostree}/lib/ostree/ostree-prepare-root /sysroot";
    };
  };

  # /nix/var/nix/profiles/system and the nix-daemon's store setup are writes to
  # a read-only store. There is no local nix on this machine; new versions
  # arrive as container images.
  nix.enable = false;
  system.switch.enable = false;
  users.mutableUsers = false;

  # Both of these write outside /etc and /var, which are the only writable
  # trees under composefs. The symlinks they would create are baked into the
  # image instead.
  #
  # Do not reach for `environment.usrbinenv = null` to disable the second one.
  # That does not make it a no-op -- it switches the script to a branch that
  # runs `rm -f /usr/bin/env` and then tries to rmdir /usr.
  system.activationScripts.binsh = lib.mkForce "";
  system.activationScripts.usrbinenv = lib.mkForce "";

  # NixOS can mount /etc as an EROFS+overlay stack from the initrd. ostree also
  # owns /etc: it three-way merges it at deploy time. Turning this on would
  # mount NixOS's overlay straight over ostree's result and hide it.
  system.etc.overlay.enable = false;
}
