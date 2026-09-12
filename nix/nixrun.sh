#!/usr/bin/env bash
# Run a command inside the pinned nixos/nix container.
#
# The host has no Nix. Everything Nix-related in this repo happens inside this
# container, with the store kept in a podman volume so it survives between runs.
# The container is x86_64; aarch64 derivations build through the host's binfmt
# registration, which uses the F (fix-binary) flag and therefore works inside
# any mount namespace without qemu-aarch64-static being present in the image.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image="${NIX_IMAGE:-docker.io/nixos/nix:latest}"
volume="${NIX_STORE_VOLUME:-nixstore}"

podman volume inspect "$volume" >/dev/null 2>&1 || podman volume create "$volume" >/dev/null

exec podman run --rm -i \
    --security-opt seccomp=unconfined \
    --security-opt label=disable \
    -v "$volume:/nix" \
    -v "$repo_root:/repo" \
    -v "${NIX_OUT_DIR:-$repo_root/nix/out}:/out" \
    -w /repo \
    -e NIX_CONFIG="experimental-features = nix-command flakes
extra-platforms = aarch64-linux
sandbox = false
filter-syscalls = false
max-jobs = 8
cores = 0
builders-use-substitutes = true" \
    "$image" "$@"
