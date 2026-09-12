{
  description = "NixOS for the Raspberry Pi 5, booted the way NixOS boots a Raspberry Pi 5";

  inputs = {
    # nixos-raspberrypi is the project that implements the native Pi firmware
    # boot path for NixOS: the vendor kernel from the raspberrypi/linux fork
    # built with bcm2712_defconfig, matched firmware and wireless blobs, and
    # per-generation kernel/initrd/cmdline under os_prefix on the FAT
    # partition. It also publishes a binary cache, so the vendor kernel and
    # the 16K-page package set are downloads rather than an overnight
    # emulated build.
    #
    # This replaces an earlier attempt that used mainline linuxPackages_latest
    # to avoid building a kernel. The Pi 5 loaded that kernel and never
    # reached userspace.
    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/main";
  };

  nixConfig = {
    extra-substituters = [ "https://nixos-raspberrypi.cachix.org" ];
    extra-trusted-public-keys = [
      "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
    ];
  };

  outputs = { self, nixos-raspberrypi }:
    let
      system = "aarch64-linux";

      # Host-specific values live outside git. secrets.nix is generated from
      # secrets.env by nix/mksecrets.sh and is gitignored; the fallback keeps
      # the flake evaluable where no secrets exist, such as in CI.
      secrets =
        if builtins.pathExists ./secrets.nix
        then import ./secrets.nix
        else {
          hostname = "rpi5";
          user = "pi";
          password = "";
          wifiSsid = "";
          wifiPsk = "";
        };
    in
    {
      # lib.nixosSystem is nixos-raspberrypi's drop-in replacement for
      # nixpkgs.lib.nixosSystem. It carries the overlay that provides
      # linux_rpi5 and the matched raspberrypifw, and it trusts their cache.
      nixosConfigurations.sd = nixos-raspberrypi.lib.nixosSystem {
        specialArgs = { inherit nixos-raspberrypi; };
        modules = [
          {
            imports = with nixos-raspberrypi.nixosModules; [
              raspberry-pi-5.base
              # The vendor kernel is built from bcm2712_defconfig, which sets
              # CONFIG_ARM64_16K_PAGES. jemalloc compiled for 4K pages aborts
              # at runtime, so the package set has to be rebuilt to match.
              # This is the same pair of modules their own rpi5 installer
              # image uses, which is why it is all in the cache.
              raspberry-pi-5.page-size-16k
              sd-image
            ];
          }
          ./modules/base.nix
          { _module.args.secrets = secrets; }
        ];
      };

      # The same NixOS system, shaped for ostree deployment by bootc. This is
      # what gets built into a container image and installed by
      # `bootc install to-disk --bootloader raspberry-pi`.
      nixosConfigurations.bootc = nixos-raspberrypi.lib.nixosSystem {
        specialArgs = { inherit nixos-raspberrypi; };
        modules = [
          {
            imports = with nixos-raspberrypi.nixosModules; [
              raspberry-pi-5.base
              raspberry-pi-5.page-size-16k
            ];
          }
          ./modules/bootc.nix
          ./modules/base.nix
          { _module.args.secrets = secrets; }
        ];
      };

      packages.${system} = {
        sd-image = self.nixosConfigurations.sd.config.system.build.sdImage;
        toplevel = self.nixosConfigurations.sd.config.system.build.toplevel;
      };
    };
}
