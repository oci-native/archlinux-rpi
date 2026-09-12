# bootc with the raspberry-pi bootloader backend, built by nix.
#
# Built here rather than taken from a distro package for one reason: the binary
# has to run inside the NixOS container image that bootc installs. A bootc
# compiled on Fedora is dynamically linked against Fedora's libostree and
# glibc paths, so it cannot execute in a NixOS root at all -- there is no
# /lib64/ld-linux and no libostree-1.so.1 where it expects one.
#
# nixpkgs' own bootc is too old to carry the patch, and its cargoHash is tied
# to a different Cargo.lock, so this builds from the pinned upstream source
# with vendor/bootc-raspberry-pi.patch applied.
{ pkgs }:

let
  # Pinned to the same commit vendor/bootc-base-commit.txt records, so the
  # patch applies and CI and local builds agree.
  rev = "db1f3ef3266415bc91aa845ee9f806ffb53136d6";
in
pkgs.rustPlatform.buildRustPackage {
  pname = "bootc-rpi";
  version = "1.16.12-raspberry-pi";

  src = pkgs.fetchFromGitHub {
    owner = "bootc-dev";
    repo = "bootc";
    inherit rev;
    hash = "sha256-E/VoOwzssxPExXFo/AlUDHzl5wXCRIp4vSlnx5jTEfo=";
  };

  patches = [ ../../vendor/bootc-raspberry-pi.patch ];

  # The lockfile is vendored alongside the patch so nix can resolve the
  # dependency set without importing it from the fetched source.
  cargoLock = {
    lockFile = ../../vendor/bootc-Cargo.lock;
    outputHashes = {
      "bcvk-qemu-0.1.0" = "sha256-nF59OmbEu3QHcrmHwww/erw9Czf16kFIg9Z2Sta3Jto=";
      "composefs-0.9.2" = "sha256-/WkBM0XOYS5M43zVysmsvnxd2u5upAxnE6zTSh2s8N4=";
    };
  };

  # Only the CLI is wanted; the integration test harness pulls in more and is
  # not useful on a Pi.
  cargoBuildFlags = [ "-p" "bootc" ];
  buildAndTestSubdir = null;
  doCheck = false;

  nativeBuildInputs = with pkgs; [
    pkg-config
    rustPlatform.bindgenHook
  ];

  buildInputs = with pkgs; [
    ostree
    glib
    openssl
    libselinux
    zstd
    systemd
    cryptsetup
    util-linux
    libcap
  ];

  postInstall = ''
    # Fail the build rather than the install if the patch silently did not
    # take: the flag is the whole point of this derivation.
    $out/bin/bootc install to-disk --help 2>&1 | grep -q raspberry-pi
  '';

  meta = {
    description = "bootc with a raspberry-pi bootloader backend";
    mainProgram = "bootc";
  };
}
