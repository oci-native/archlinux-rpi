# What has to change about a NixOS system for it to survive being deployed by
# ostree, where / is a read-only composefs image and only /etc and /var are
# writable.
#
# The handoff at boot is: the Pi firmware loads kernel+initrd -> NixOS's
# systemd stage 1 comes up -> ostree-prepare-root turns /sysroot into the
# deployment -> NixOS's own initrd-find-nixos-closure reads init= off the
# cmdline to locate the system closure -> initrd-nixos-activation chroots in
# and runs activation -> switch-root. Everything after ostree-prepare-root is
# stock NixOS; we only have to insert that one step.
{ config, lib, pkgs, ... }:

let
  ostreePrepareRoot = "${pkgs.ostree}/lib/ostree/ostree-prepare-root";

  # ostree-prepare-root reads the copy of this file that is inside the
  # initramfs, not the one in /usr. Shipping it in only one of the two places
  # means the settings are silently inert -- composefs falls back to "maybe"
  # and the sysroot comes up writable.
  prepareRootConf = pkgs.writeText "prepare-root.conf" ''
    [composefs]
    enabled = yes

    [sysroot]
    readonly = true
  '';
in
{
  # /nix/var/nix/profiles/system and the nix-daemon's store setup are writes
  # to a read-only store. There is no local nix on this machine; new versions
  # arrive as container images.
  nix.enable = false;
  system.switch.enable = false;
  users.mutableUsers = false;

  # Both of these write outside /etc and /var. The symlinks they would create
  # are baked into the image instead.
  #
  # Do not reach for `environment.usrbinenv = null` to disable the second one.
  # That does not make it a no-op -- it switches the script to a branch that
  # runs `rm -f /usr/bin/env` and then tries to rmdir /usr.
  system.activationScripts.binsh = lib.mkForce "";
  system.activationScripts.usrbinenv = lib.mkForce "";

  # NixOS can mount /etc as an EROFS+overlay stack from the initrd. ostree
  # also owns /etc -- it three-way merges it at deploy time. Turning this on
  # would mount NixOS's overlay straight over ostree's result and hide it.
  system.etc.overlay.enable = false;

  boot.initrd.systemd.enable = true;

  # bootc's installer gives the root partition the discoverable-partitions
  # type GUID for aarch64 root (B921B045-1DF0-41C3-AF44-4C6F280D3FAE), which
  # is exactly what systemd's gpt-auto generator looks for. That means the
  # initrd finds the root partition without anyone having to know its UUID at
  # image build time.
  boot.initrd.systemd.root = "gpt-auto";

  boot.initrd.availableKernelModules = [ "erofs" "overlay" "loop" ];

  boot.initrd.systemd.storePaths = [ ostreePrepareRoot ];

  boot.initrd.systemd.contents."/usr/lib/ostree/prepare-root.conf".source =
    prepareRootConf;

  boot.initrd.systemd.services.ostree-prepare-root = {
    description = "Turn /sysroot into the ostree deployment";
    unitConfig = {
      DefaultDependencies = false;
      ConditionKernelCommandLine = "ostree";
    };
    requires = [ "sysroot.mount" ];
    after = [ "sysroot.mount" ];
    before = [
      "initrd-root-fs.target"
      "initrd-find-nixos-closure.service"
    ];
    requiredBy = [ "initrd-root-fs.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${ostreePrepareRoot} /sysroot";
    };
  };
}
