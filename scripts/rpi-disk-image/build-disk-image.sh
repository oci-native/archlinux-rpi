#!/bin/bash
# Build a raw, flashable .img from the built container image via
# `bootc install to-disk --via-loopback`, then hand off to
# provision-image.sh for everything after. See docs/disk-image.md.
#
# MUST RUN ON A NATIVE aarch64 KERNEL. Not a preference -- see the arch
# guard below for the kernel-level reason. In practice that means the
# GitHub Actions arm64 runner (.github/workflows/build-image.yml) or an
# actual arm64 box. On an x86_64 workstation, let CI produce the
# unprovisioned .img and run provision-image.sh against it locally; that
# half works fine on x86_64 and is the only place secrets.env belongs.
#
# Loopback only. This script never touches a real block device -- it
# creates a plain file and everything else operates on that file or a
# loop device mapped onto it. Never point $OUT at /dev/sdb or any other
# physical device.
#
# Usage:
#   sudo ./scripts/rpi-disk-image/build-disk-image.sh [OUT] [SIZE] [IMAGE_REF] [SECRETS_ENV]
#
#   OUT          output path for the .img (default: rpi-bootc.img)
#   SIZE         truncate size, sparse (default: 50G -- deliberately well
#                under a "64GB" card's ~59.6 GiB actual usable capacity)
#   IMAGE_REF    the built container image to install (default:
#                localhost/archlinux-rpi:latest)
#   SECRETS_ENV  path to the gitignored secrets file (default: ./secrets.env)

set -euo pipefail

OUT="${1:-rpi-bootc.img}"
SIZE="${2:-50G}"
IMAGE_REF="${3:-localhost/archlinux-rpi:latest}"
SECRETS_ENV="${4:-secrets.env}"

if [[ $EUID -ne 0 ]]; then
	echo "Error: must run as root (losetup/mount need it). Use sudo." >&2
	exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Hard arch guard. `bootc install to-disk` re-execs itself into the host
# mount namespace: it opens /proc/1/ns/mnt and calls setns(fd,
# CLONE_NEWNS) -- exec_in_host_mountns() in bootc's crates/lib/src/
# install.rs. setns(2) requires the calling process to be single-threaded
# for CLONE_NEWNS, because a multithreaded process shares filesystem
# attributes (CLONE_FS) with its threads; otherwise it returns EINVAL.
#
# Every binary run under qemu-user binfmt emulation is multithreaded --
# qemu spawns its RCU call thread before the guest's first instruction.
# Measured on this repo's host: a single-threaded `grep` reports
# `Threads: 1` in a native amd64 container and `Threads: 2` in an emulated
# arm64 one. So an emulated `bootc install to-disk` fails, every time,
# with:
#
#     error: Installing to disk: Gathering source info from container env
#     error: Re-exec in host mountns: setns: Invalid argument (os error 22)
#
# That is a kernel-level impossibility, not a bootc bug and not a missing
# podman flag. --privileged, --pid=host and --cgroupns=host were all tried
# and none of them change it; nothing can, short of a native kernel.
HOST_ARCH="$(uname -m)"
if [[ "$HOST_ARCH" != "aarch64" && "$HOST_ARCH" != "arm64" ]]; then
	cat >&2 <<EOF
Error: this host is $HOST_ARCH, but installing an aarch64 image needs a
native aarch64 kernel. \`bootc install to-disk\` must setns() into the host
mount namespace, which is unconditionally EINVAL under qemu-user emulation
(qemu is always multithreaded; setns(CLONE_NEWNS) requires single-threaded).
See the comment above this check.

Do this instead:
  1. Let CI build the unprovisioned image natively on arm64:
       gh workflow run "Build aarch64 bootc image"
  2. Download and restore it (zstd does not restore the apparent size):
       gh run download <run-id> -n rpi-bootc-unprovisioned-img
       zstd -d --sparse rpi-bootc.img.zst -o rpi-bootc.img
       truncate -s $SIZE rpi-bootc.img
  3. Provision it here, locally, where secrets.env lives:
       sudo ./scripts/rpi-disk-image/provision-image.sh rpi-bootc.img
EOF
	exit 1
fi

# Fail before the 50G truncate rather than after it if secrets.env is
# malformed. The file is optional: this script runs both locally and in
# CI, where it must never exist (gitignored, public repo). Without it the
# result is a valid, bootable, unprovisioned image.
if [[ -f "$SECRETS_ENV" ]]; then
	# shellcheck source=/dev/null
	source "$SECRETS_ENV"
	for var in RPI_HOSTNAME RPI_USER RPI_PASSWORD RPI_WIFI_SSID RPI_WIFI_PSK; do
		if [[ -z "${!var:-}" ]]; then
			echo "Error: $var is not set in $SECRETS_ENV" >&2
			exit 1
		fi
	done
fi

echo "==> Creating sparse ${SIZE} image at ${OUT}"
truncate -s "$SIZE" "$OUT"

echo "==> Transferring ${IMAGE_REF} into root's podman storage"
# This script runs under sudo, so `podman` here is root's own podman -- a
# completely separate image store from whichever unprivileged user
# actually built $IMAGE_REF (rootless podman storage is per-user).
# Without this, `bootc install to-disk` can't find $IMAGE_REF locally and
# falls through to a registry pull for "localhost/...", which fails.
if [[ -n "${SUDO_USER:-}" ]] && ! podman image exists "$IMAGE_REF"; then
	# $SCRATCH-style root mktemp is mode 0700 -- $SUDO_USER can't write
	# into it. Have them create and own their own tmpfile instead; root
	# can still read it to load, then remove it.
	IMAGE_TAR="$(sudo -u "$SUDO_USER" mktemp)"
	sudo -u "$SUDO_USER" podman save "$IMAGE_REF" -o "$IMAGE_TAR"
	podman load -i "$IMAGE_TAR"
	rm -f "$IMAGE_TAR"
fi

echo "==> Installing ${IMAGE_REF} to ${OUT} via loopback"
# Canonical bootc install-to-disk invocation: podman run of the very image
# being installed, --privileged + --pid=host + a containers-storage bind
# mount so bootc can resolve its own image reference. --via-loopback means
# $OUT is a plain file and bootc manages the loop device internally, so
# this script does not losetup before this step.
#
# --pid=host is mandatory; bootc checks for it explicitly and refuses to
# run without it ("This command must be run with the podman --pid=host
# flag"). --bootloader none and no --composefs-backend are settled
# decisions, see docs/TEAM-BRIEF.md. There are no --karg entries here --
# the serial console karg is static kargs.d policy in Containerfile.rpi.
podman run --rm --privileged --pid=host \
	--security-opt label=type:unconfined_t \
	-v /var/lib/containers:/var/lib/containers \
	-v /dev:/dev \
	-v "$(dirname "$(readlink -f "$OUT")")":/target \
	"$IMAGE_REF" \
	bootc install to-disk \
	--via-loopback "/target/$(basename "$OUT")" \
	--filesystem ext4 \
	--wipe \
	--bootloader none \
	--skip-fetch-check

# Firmware seeding, secrets injection, bootloader sync and verification --
# none of which need a native kernel, so they live in their own script an
# x86_64 box can run against a CI-built image.
exec "$REPO_ROOT/scripts/rpi-disk-image/provision-image.sh" \
	"$OUT" "$SECRETS_ENV" "$IMAGE_REF"
