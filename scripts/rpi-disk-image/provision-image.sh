#!/bin/bash
# Everything that happens to a disk image *after* `bootc install to-disk`
# has written the ostree deployment into it: VideoCore firmware seeding,
# host secrets injection, the initial rpi-bootc-bootloader sync, and
# in-place verification.
#
# Split out of build-disk-image.sh on purpose. The install step must run
# on a native aarch64 kernel (see build-disk-image.sh's arch guard for
# why), but nothing in *this* script does -- it is loop-mounts, file
# copies, and one podman run of a plain bash script. So an x86_64 box can
# take a CI-built unprovisioned .img and turn it into the real, private,
# ready-to-flash card locally, which is the only place secrets.env is
# allowed to exist.
#
# Loopback only. Never point $IMG at /dev/sdb or any physical device;
# this script creates no partitions and writes to nothing but the file it
# is given and the loop device mapped onto it. Flashing is a separate,
# manual step done by hand.
#
# Usage:
#   sudo ./scripts/rpi-disk-image/provision-image.sh IMG [SECRETS_ENV] [IMAGE_REF]
#
#   IMG          an .img already installed to by `bootc install to-disk`
#   SECRETS_ENV  gitignored secrets file (default: ./secrets.env). If it
#                does not exist, the image is left unprovisioned.
#   IMAGE_REF    image supplying rpi-bootc-bootloader (default:
#                localhost/archlinux-rpi:latest)

set -euo pipefail

IMG="${1:?usage: provision-image.sh IMG [SECRETS_ENV] [IMAGE_REF]}"
SECRETS_ENV="${2:-secrets.env}"
IMAGE_REF="${3:-localhost/archlinux-rpi:latest}"

if [[ $EUID -ne 0 ]]; then
	echo "Error: must run as root (losetup/mount need it). Use sudo." >&2
	exit 1
fi

if [[ ! -f "$IMG" ]]; then
	echo "Error: $IMG does not exist." >&2
	exit 1
fi

# Refuse a block device outright rather than trusting the caller to have
# passed a file. This script only ever operates on image files.
if [[ -b "$IMG" ]]; then
	echo "Error: $IMG is a block device. This script is loopback-only." >&2
	exit 1
fi

# secrets.env is intentionally optional: this same script runs both
# locally (where it exists) and in CI (where it must never exist -- it's
# gitignored and this repo is public, and CI has no business seeing real
# credentials). Without it the image is still valid and bootable, just
# with no hostname/user/wifi/ssh-password-auth configured.
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
	echo "Note: $SECRETS_ENV not found -- leaving the image unprovisioned." >&2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRATCH="$(mktemp -d)"
LOOP=""
BOUND=0

cleanup() {
	set +e
	if [[ "$BOUND" -eq 1 ]]; then
		umount "$SCRATCH/sysroot/boot" 2>/dev/null
	fi
	if [[ -n "$LOOP" ]]; then
		umount "$SCRATCH/firmware" 2>/dev/null
		umount "$SCRATCH/sysroot" 2>/dev/null
		losetup -d "$LOOP" 2>/dev/null
	fi
	rm -rf "$SCRATCH"
}
trap cleanup EXIT

echo "==> Setting up loop device for $IMG"
LOOP="$(losetup --find --show --partscan "$IMG")"
udevadm settle 2>/dev/null || true
sleep 1

FW_PART="${LOOP}p1"
ROOT_PART="${LOOP}p2"
[[ -b "$FW_PART" ]] || FW_PART="${LOOP}1"
[[ -b "$ROOT_PART" ]] || ROOT_PART="${LOOP}2"

if [[ ! -b "$FW_PART" || ! -b "$ROOT_PART" ]]; then
	echo "Error: expected 2 partitions on $LOOP; is $IMG really installed to?" >&2
	exit 1
fi

mkdir -p "$SCRATCH/sysroot" "$SCRATCH/firmware"
mount "$ROOT_PART" "$SCRATCH/sysroot"
mount "$FW_PART" "$SCRATCH/firmware"

DEPLOY_DIR="$(compgen -G "$SCRATCH/sysroot/ostree/deploy/default/deploy/*/" | head -1)"
if [[ -z "$DEPLOY_DIR" ]]; then
	echo "Error: no ostree deployment found under $SCRATCH/sysroot" >&2
	exit 1
fi

echo "==> Seeding VideoCore firmware blobs"
"$REPO_ROOT/scripts/rpi-disk-image/seed-firmware.sh" \
	"$SCRATCH/firmware" "${DEPLOY_DIR}usr/lib/raspberrypi/boot"

if [[ "$PROVISION" -eq 1 ]]; then
	echo "==> Injecting host configuration (from $SECRETS_ENV, never into any image layer)"
	"$REPO_ROOT/scripts/rpi-disk-image/provision-secrets.sh" "$SCRATCH/sysroot" "$SECRETS_ENV"
else
	echo "==> Skipping host provisioning (no $SECRETS_ENV)"
fi

echo "==> Running rpi-bootc-bootloader sync"
# Our 2-partition layout has no separate /boot partition -- bind-mount the
# root partition's own /boot onto itself so the hook's hardcoded
# /boot/loader/entries/ostree-N.conf resolves inside the container. Matches
# AlmaLinux's validated `mount ${LOOP}p3 /sysroot && mount ${LOOP}p2 /boot`
# pattern, adapted for boot-as-a-directory. See docs/disk-image.md.
#
# This podman run is emulated on an x86_64 host, and that is fine:
# rpi-bootc-bootloader is a plain bash script, and the one binary it calls
# (`bootc status --format json`) does not touch namespaces. Confirmed by
# hand under emulation -- it returns booted:null/staged:null, which is
# exactly the fresh-install case the script's single-deployment fallback
# handles. `bootc install to-disk` is the only step emulation breaks.
mount --bind "$SCRATCH/sysroot/boot" "$SCRATCH/sysroot/boot"
BOUND=1
podman run --rm --privileged \
	--mount "type=bind,src=$SCRATCH/sysroot,dst=/sysroot" \
	--mount "type=bind,src=$SCRATCH/sysroot/boot,dst=/boot" \
	"$IMAGE_REF" \
	rpi-bootc-bootloader sync

echo "==> Verifying (read-only, same mounts, before any upload/download round-trip)"
# Verification happens here, in-place, rather than after downloading the
# .img elsewhere: a large mostly-sparse disk image does not necessarily
# survive an upload-artifact/download-artifact round-trip intact (hit this
# by hand -- a downloaded, truncate-restored copy came back with real ext4
# corruption that a fresh e2fsck found, while the CI job's own build log
# showed a clean `Installation complete!`). Checking here means the checks
# run against exactly what is on disk right now.
FAIL=0
check() { if eval "$2"; then echo "  OK   $1"; else echo "  FAIL $1"; FAIL=1; fi; }

check "config.txt exists" "[[ -f $SCRATCH/firmware/config.txt ]]"
check "bootc/entries/ostree-1/ exists" "[[ -d $SCRATCH/firmware/bootc/entries/ostree-1 ]]"
check "  vmlinuz present" "[[ -f $SCRATCH/firmware/bootc/entries/ostree-1/vmlinuz ]]"
check "  initrd present" "[[ -f $SCRATCH/firmware/bootc/entries/ostree-1/initrd ]]"
check "  cmdline.txt present" "[[ -f $SCRATCH/firmware/bootc/entries/ostree-1/cmdline.txt ]]"
check "  dtbs present" "compgen -G '$SCRATCH/firmware/bootc/entries/ostree-1/*.dtb' >/dev/null"
check "os_prefix points at ostree-1" "grep -q 'os_prefix=bootc/entries/ostree-1/' $SCRATCH/firmware/config-bootc-default.txt"
check "ostree deployment exists" "compgen -G '$SCRATCH/sysroot/ostree/deploy/default/deploy/*/' >/dev/null"
check "ostree repo exists" "[[ -d $SCRATCH/sysroot/ostree/repo ]]"

if [[ "$PROVISION" -eq 1 ]]; then
	check "hostname is $RPI_HOSTNAME" "[[ \"\$(cat ${DEPLOY_DIR}etc/hostname)\" == '$RPI_HOSTNAME' ]]"
	check "NM wifi profile exists, mode 600" "[[ \"\$(stat -c%a ${DEPLOY_DIR}etc/NetworkManager/system-connections/${RPI_WIFI_SSID}.nmconnection 2>/dev/null)\" == '600' ]]"
	check "user $RPI_USER in passwd" "grep -q '^${RPI_USER}:' ${DEPLOY_DIR}etc/passwd"
	check "user $RPI_USER has a hashed password" "grep -q '^${RPI_USER}:\\\$6\\\$' ${DEPLOY_DIR}etc/shadow"
	check "user $RPI_USER in wheel" "grep -q '^wheel:.*\\b${RPI_USER}\\b' ${DEPLOY_DIR}etc/group"
	check "sshd enabled" "[[ -e ${DEPLOY_DIR}etc/systemd/system/multi-user.target.wants/sshd.service ]]"
	check "NetworkManager enabled" "[[ -e ${DEPLOY_DIR}etc/systemd/system/multi-user.target.wants/NetworkManager.service ]]"
else
	echo "  SKIP hostname/user/wifi/sshd/NM checks (unprovisioned image)"
fi

if [[ "$FAIL" -eq 1 ]]; then
	echo "==> Verification FAILED, see FAIL lines above" >&2
	exit 1
fi

echo "==> Done. Image: $IMG ($(du -h "$IMG" | cut -f1) actual, $(stat -c%s "$IMG") bytes apparent)"
if [[ "$PROVISION" -eq 1 ]]; then
	echo "==> Provisioned as '$RPI_HOSTNAME'. Ready to flash by hand."
else
	echo "==> Unprovisioned. Re-run with a secrets.env present to configure it."
fi
