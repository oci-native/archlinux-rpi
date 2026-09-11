#!/bin/bash
# Read-only verification of a built Pi image, against either an .img file
# or the flashed card itself. Mounts both partitions read-only and checks
# the boot chain, the ostree deployment and the provisioned host config.
#
# Takes a block device as well as a file on purpose: verifying the .img
# proves the build was right, but only reading the card back proves the
# *write* was right, and a long USB write is exactly where things break
# (see docs/disk-image.md). Read-only throughout -- it never writes to
# whatever it is pointed at.
#
# Usage: sudo ./verify-image.sh /path/to.img | /dev/sdX

set -euo pipefail

TARGET="${1:?usage: verify-image.sh IMG_OR_DEVICE}"
[[ $EUID -eq 0 ]] || { echo "Error: must run as root (mount needs it)." >&2; exit 1; }
[[ -e "$TARGET" ]] || { echo "Error: $TARGET does not exist." >&2; exit 1; }

S="$(mktemp -d)"; LOOP=""
cleanup() {
	set +e
	umount "$S/fw" 2>/dev/null; umount "$S/root" 2>/dev/null
	[[ -n "$LOOP" ]] && losetup -d "$LOOP" 2>/dev/null
	rm -rf "$S"
}
trap cleanup EXIT

if [[ -b "$TARGET" ]]; then
	# Already a block device; its partitions are just $TARGET+N.
	BASE="$TARGET"
	echo "==> Verifying flashed device $TARGET (read-only)"
else
	LOOP="$(losetup --find --show --partscan --read-only "$TARGET")"
	udevadm settle 2>/dev/null || true; sleep 1
	BASE="$LOOP"
	echo "==> Verifying image $TARGET via $LOOP (read-only)"
fi

FW="${BASE}p1"; ROOT="${BASE}p2"
[[ -b "$FW" ]]   || FW="${BASE}1"
[[ -b "$ROOT" ]] || ROOT="${BASE}2"
[[ -b "$FW" && -b "$ROOT" ]] || { echo "Error: expected 2 partitions on $BASE" >&2; exit 1; }

mkdir -p "$S/fw" "$S/root"
mount -o ro "$FW" "$S/fw"
mount -o ro "$ROOT" "$S/root"

D="$(compgen -G "$S/root/ostree/deploy/default/deploy/*/" | head -1)"
[[ -n "$D" ]] || { echo "Error: no ostree deployment found" >&2; exit 1; }

FAIL=0
ok() { if eval "$2"; then echo "  OK   $1"; else echo "  FAIL $1"; FAIL=1; fi; }

ok "config.txt"                "[ -f $S/fw/config.txt ]"
ok "bootc/entries/ostree-1"    "[ -d $S/fw/bootc/entries/ostree-1 ]"
ok "  vmlinuz"                 "[ -s $S/fw/bootc/entries/ostree-1/vmlinuz ]"
ok "  initrd"                  "[ -s $S/fw/bootc/entries/ostree-1/initrd ]"
ok "  cmdline.txt"             "[ -s $S/fw/bootc/entries/ostree-1/cmdline.txt ]"
ok "  dtbs"                    "compgen -G '$S/fw/bootc/entries/ostree-1/*.dtb' >/dev/null"
ok "  overlays"                "compgen -G '$S/fw/bootc/entries/ostree-1/overlays/*.dtbo' >/dev/null"
ok "os_prefix -> ostree-1"     "grep -q 'os_prefix=bootc/entries/ostree-1/' $S/fw/config-bootc-default.txt"
ok "VideoCore start4.elf"      "[ -s $S/fw/start4.elf ]"
ok "ostree repo"               "[ -d $S/root/ostree/repo ]"
ok "hostname set"              "[ -s ${D}etc/hostname ]"
ok "a user exists (uid 1000)"  "awk -F: '\$3==1000{f=1}END{exit !f}' ${D}etc/passwd"
ok "that user has a hash"      "awk -F: '\$2 ~ /^\\\$6\\\$/{f=1}END{exit !f}' ${D}etc/shadow"
ok "wheel has a member"        "grep -q '^wheel:[^:]*:[^:]*:.\\+' ${D}etc/group"
ok "wifi profile mode 600"     "[ \"\$(stat -c%a ${D}etc/NetworkManager/system-connections/*.nmconnection 2>/dev/null)\" = 600 ]"
ok "sshd enabled"              "[ -e ${D}etc/systemd/system/multi-user.target.wants/sshd.service ]"
ok "NetworkManager enabled"    "[ -e ${D}etc/systemd/system/multi-user.target.wants/NetworkManager.service ]"
ok "systemd-networkd disabled" "[ ! -e ${D}etc/systemd/system/multi-user.target.wants/systemd-networkd.service ]"
ok "no ALARM .network files"   "! compgen -G '${D}etc/systemd/network/*.network' >/dev/null"
ok "Pi 5 wifi firmware"        "[ -e '${D}usr/lib/firmware/updates/brcm/brcmfmac43455-sdio.raspberrypi,5-model-b.bin' ]"
ok "regulatory.db"             "[ -s ${D}usr/lib/firmware/regulatory.db ]"

# The single check most likely to catch a bad shrink or a torn write: the
# boot entry finds the root by filesystem UUID, so the two must agree.
FSUUID="$(blkid -s UUID -o value "$ROOT")"
BLSUUID="$(grep -o 'root=UUID=[^ ]*' "$S/root/boot/loader/entries/ostree-1.conf" | head -1 | cut -d= -f3)"
ok "BLS root=UUID matches fs"  "[ -n '$FSUUID' ] && [ '$FSUUID' = '$BLSUUID' ]"
echo "       fs=$FSUUID"
echo "       bls=$BLSUUID"

if [[ "$FAIL" -eq 0 ]]; then
	echo "==> ALL CHECKS PASSED"
else
	echo "==> VERIFICATION FAILED" >&2
	exit 1
fi
