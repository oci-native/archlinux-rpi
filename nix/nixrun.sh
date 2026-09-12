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

# Unauthenticated calls to api.github.com run out of rate limit quickly, and
# nix uses that API to resolve every github: flake ref. Reuse the gh CLI's
# token when there is one. It is passed through the environment rather than on
# the command line so it does not show up in ps output.
nix_extra_config=""
if gh_token="$(gh auth token 2>/dev/null)" && [[ -n $gh_token ]]; then
    nix_extra_config="access-tokens = github.com=$gh_token"
fi

# Pinned: once an arm64 nixos/nix image is in local storage, podman will
# happily resolve :latest to it and then every build runs under emulation.
exec podman run --rm -i \
    --platform linux/amd64 \
    --security-opt seccomp=unconfined \
    --security-opt label=disable \
    -v "$volume:/nix" \
    -v "$repo_root:/repo" \
    -v "${NIX_OUT_DIR:-$repo_root/nix/out}:/out" \
    -w /repo \
    -e NIX_CONFIG="$nix_extra_config
experimental-features = nix-command flakes
extra-platforms = aarch64-linux
sandbox = false
filter-syscalls = false
max-jobs = 8
cores = 0
builders-use-substitutes = true
extra-substituters = https://nixos-raspberrypi.cachix.org
extra-trusted-public-keys = nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI=" \
    "$image" "$@"
