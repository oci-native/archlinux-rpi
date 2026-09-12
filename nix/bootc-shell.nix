# Dev shell for building bootc from source.
#
# bootc links against ostree, glib, openssl, libselinux, zstd and the
# util-linux libraries, and selinux-sys/bindgen needs libclang. nixpkgs' own
# bootc devShell does not carry libselinux headers, so this spells the set out.
#
# Usage, from the repo root:
#   podman run ... nix develop --impure -f nix/bootc-shell.nix --command cargo build
{ system ? builtins.currentSystem
, pkgs ? (builtins.getFlake "nixpkgs").legacyPackages.${system}
}:

pkgs.mkShell {
  nativeBuildInputs = with pkgs; [
    rustc
    cargo
    pkg-config
    rustPlatform.bindgenHook
  ];

  buildInputs = with pkgs; [
    openssl
    ostree
    glib
    libselinux
    zstd
    systemd
    cryptsetup
    util-linux
    libcap
  ];
}
