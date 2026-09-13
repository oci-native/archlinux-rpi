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
          # Not secrets: a hostname and a login name. Defaulting them here
          # means CI builds the real machine rather than a placeholder, and
          # nothing sensitive has to reach a public repository's runner.
          hostname = "citadel";
          user = "bupd";
          # Left empty on purpose. Access is by SSH key, so no password hash
          # is ever baked into an image.
          password = "";
          # An SSID is broadcast in the clear by every access point, so it is
          # not a secret and can be built into the image. The passphrase is,
          # and is never here: wpa_supplicant reads it at runtime from
          # secretsFile, written onto the card by scripts/provision-wifi.sh.
          wifiSsid = "BUPD";
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
        # bootc with --bootloader raspberry-pi, built against nixpkgs so it
        # runs inside the NixOS image it installs.
        bootc-rpi = import ./pkgs/bootc-rpi.nix {
          pkgs = self.nixosConfigurations.bootc.pkgs;
        };

        # Same image with composefs disabled, for bisecting whether the EROFS
        # mount is what stops the Pi booting. ostree falls back to a hardlink
        # checkout, so the boot path never touches EROFS.
        bootc-image-plain =
          let cfg = self.nixosConfigurations.bootc; in
          import ./lib/bootc-image.nix {
            pkgs = cfg.pkgs;
            inherit (cfg.pkgs) lib;
            config = cfg.config;
            bootcPackage = import ./pkgs/bootc-rpi.nix { pkgs = cfg.pkgs; };
            composefs = false;
          };

        sd-image = self.nixosConfigurations.sd.config.system.build.sdImage;
        toplevel = self.nixosConfigurations.sd.config.system.build.toplevel;

        # A script that streams the bootc-installable OCI image to stdout.
        # Pipe it into `podman load`.
        bootc-image =
          let
            cfg = self.nixosConfigurations.bootc;
            pkgs = cfg.pkgs;
          in
          import ./lib/bootc-image.nix {
            inherit pkgs;
            inherit (pkgs) lib;
            config = cfg.config;
            bootcPackage = import ./pkgs/bootc-rpi.nix { inherit pkgs; };
          };
      };
    };
}
