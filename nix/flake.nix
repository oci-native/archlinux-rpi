{
  description = "NixOS for the Raspberry Pi 5, booted by the Pi firmware directly";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-hardware.url = "github:NixOS/nixos-hardware";
  };

  outputs = { self, nixpkgs, nixos-hardware }:
    let
      system = "aarch64-linux";
      # The host running this build is x86_64. aarch64 derivations go through
      # the host's binfmt_misc registration, which carries the F (fix-binary)
      # flag and therefore resolves inside nix's build sandbox as well.
      pkgs = nixpkgs.legacyPackages.${system};

      # Host-specific values live outside git. secrets.nix is generated from
      # secrets.env by nix/mksecrets.sh and is gitignored; the fallback keeps
      # the flake evaluable in CI, where no secrets exist.
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

      common = [
        nixos-hardware.nixosModules.raspberry-pi-5
        ./modules/rpi5-firmware-boot.nix
        ./modules/base.nix
        { _module.args.secrets = secrets; }
      ];
    in
    {
      nixosConfigurations = {
        # A plain SD-card image. No bootc, no ostree -- this is the control
        # experiment that proves the kernel, firmware and card all work.
        sd = nixpkgs.lib.nixosSystem {
          inherit system;
          modules = common ++ [ ./modules/sd-image.nix ];
        };
      };

      packages.${system} = {
        sd-image = self.nixosConfigurations.sd.config.system.build.sdImage;
        toplevel = self.nixosConfigurations.sd.config.system.build.toplevel;
      };
    };
}
