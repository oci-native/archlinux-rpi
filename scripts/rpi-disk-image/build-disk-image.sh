#!/bin/bash
# Build a raw, flashable .img from the built container image via
# `bootc install to-disk --via-loopback`. See docs/disk-image.md.
#
# Loopback only. This script never touches a real block device -- it
# creates a plain file, loop-mounts it, and everything else operates on
# that loop device or its partitions. Never point $OUT at /dev/sdb or any
# other physical device.
#
# Needs real root (losetup, mount, a --privileged podman container). Not
# achievable under this session's rootless podman without host root --
# see docs/disk-image.md for why. Designed to run either by hand with sudo
# or, natively, in the GitHub Actions workflow.
#
# Usage:
#   sudo ./scripts/rpi-disk-image/build-disk-image.sh [OUT] [SIZE] [IMAGE_REF] [SECRETS_ENV]
#
#   OUT          output path for the .img (default: rpi-bootc.img)
#   SIZE         truncate size, sparse (default: 58G -- see docs/disk-image.md
#                for why 58G and not 64G for a "64GB" card)
#   IMAGE_REF    the built container image to install (default:
#                localhost/archlinux-rpi:latest)
#   SECRETS_ENV  path to the gitignored secrets file (default: ./secrets.env)

set -euo pipefail

OUT="${1:-rpi-bootc.img}"
SIZE="${2:-58G}"
IMAGE_REF="${3:-localhost/archlinux-rpi:latest}"
SECRETS_ENV="${4:-secrets.env}"

if [[ $EUID -ne 0 ]]; then
	echo "Error: must run as root (losetup/mount need it). Use sudo." >&2
	exit 1
fi

# secrets.env is intentionally optional here, not required: this same
# script runs both locally (where it exists) and in CI (where it must
# never exist -- it's gitignored and this repo is public, and CI has no
# business seeing real credentials). Without it, this produces a base
# image with no hostname/user/wifi/ssh-password-auth configured -- still
# a valid, bootable image, just unprovisioned. Provisioning with real
# secrets is a separate, local-only step.
PROVISION=0
if [[ -f "$SECRETS_ENV" ]]; then
	# shellcheck source=/dev/null
	source "$SECRETS_ENV"
	for var in RPI_HOSTNAME RPI_USER RPI_PASSWORD RPI_WIFI_SSID RPI_WIFI_PSK; do
		if [[ -z "${!var:-}" ]]; then
			echo "Error: $var is not set in $SECRETS_ENV" >&2
			exit 1
		fi
	done
	PROVISION=1
else
	echo "Note: $SECRETS_ENV not found -- building an unprovisioned base image." >&2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRATCH="$(mktemp -d)"
LOOP=""

cleanup() {
	set +e
	if [[ -n "$LOOP" ]]; then
		umount "$SCRATCH/sysroot/boot" 2>/dev/null
		umount "$SCRATCH/sysroot" 2>/dev/null
		umount "$SCRATCH/firmware" 2>/dev/null
		losetup -d "$LOOP" 2>/dev/null
	fi
	rm -rf "$SCRATCH"
}
trap cleanup EXIT

echo "==> Creating sparse ${SIZE} image at ${OUT}"
truncate -s "$SIZE" "$OUT"

echo "==> Installing ${IMAGE_REF} to ${OUT} via loopback"
# Canonical bootc install-to-disk invocation (podman run of the very image
# being installed, --privileged + --pid=host + containers-storage bind
# mount so bootc can resolve its own image reference). --via-loopback:
# $OUT is a plain file, bootc manages the loop device internally, so this
# script does not losetup before this step.
#
# --bootloader none, no --composefs-backend: settled decisions, see
# docs/TEAM-BRIEF.md. --karg entries here are ones that can't be static
# kargs.d policy because they're install-time facts (none needed currently
# -- the serial console karg is static kargs.d in Containerfile.rpi).
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

echo "==> Setting up host loop device for post-install provisioning"
LOOP="$(losetup --find --show --partscan "$OUT")"
udevadm settle 2>/dev/null || true
sleep 1

FW_PART="${LOOP}p1"
ROOT_PART="${LOOP}p2"
[[ -b "$FW_PART" ]] || FW_PART="${LOOP}1"
[[ -b "$ROOT_PART" ]] || ROOT_PART="${LOOP}2"

mkdir -p "$SCRATCH/sysroot" "$SCRATCH/firmware"
mount "$ROOT_PART" "$SCRATCH/sysroot"
mount "$FW_PART" "$SCRATCH/firmware"

echo "==> Seeding VideoCore firmware blobs"
DEPLOY_DIR="$(compgen -G "$SCRATCH/sysroot/ostree/deploy/default/deploy/*/" | head -1)"
if [[ -z "$DEPLOY_DIR" ]]; then
	echo "Error: no ostree deployment found under $SCRATCH/sysroot" >&2
	exit 1
fi
"$REPO_ROOT/scripts/rpi-disk-image/seed-firmware.sh" \
	"$SCRATCH/firmware" "${DEPLOY_DIR}usr/lib/raspberrypi/boot"

if [[ "$PROVISION" -eq 1 ]]; then
	echo "==> Injecting host configuration (from $SECRETS_ENV, never into any image layer)"
	"$REPO_ROOT/scripts/rpi-disk-image/provision-secrets.sh" "$SCRATCH/sysroot" "$SECRETS_ENV"
else
	echo "==> Skipping host provisioning (no $SECRETS_ENV) -- base image only"
fi

echo "==> Running initial rpi-bootc-bootloader sync"
# Our 2-partition layout has no separate /boot partition -- bind-mount the
# root partition's own /boot onto /boot inside the sync container so the
# hook's hardcoded /boot/loader/entries/ostree-N.conf resolves correctly.
# Matches AlmaLinux's validated `mount ${LOOP}p3 /sysroot && mount ${LOOP}p2
# /boot` pattern, adapted for boot-as-a-directory instead of its own
# partition. See docs/disk-image.md.
mount --bind "$SCRATCH/sysroot/boot" "$SCRATCH/sysroot/boot"
podman run --rm --privileged \
	--mount "type=bind,src=$SCRATCH/sysroot,dst=/sysroot" \
	--mount "type=bind,src=$SCRATCH/sysroot/boot,dst=/boot" \
	"$IMAGE_REF" \
	rpi-bootc-bootloader sync

echo "==> Done. Image: $OUT ($(du -h "$OUT" | cut -f1) actual, $(stat -c%s "$OUT") bytes apparent)"
