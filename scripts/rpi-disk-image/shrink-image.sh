#!/bin/bash
# Shrink an already-installed, already-provisioned .img to a smaller
# total size, by shrinking the ext4 root filesystem and its partition and
# relocating the GPT backup header.
#
# Why this exists: the deployment occupies about 3 GB no matter how large
# the image is, so the rest of a 50G image is zeroes that still have to be
# physically written to the card. Writing 50 GB to a USB card reader took
# over an hour here and the device dropped off the bus partway through
# ("device offline error" in dmesg), which is a much likelier failure the
# longer the write runs. Smaller image, shorter write, less exposure.
#
# Only the root partition moves. The firmware partition, the BLS entry and
# config.txt are untouched, and the BLS entry refers to the root by
# filesystem UUID (root=UUID=...), which resize2fs preserves -- so the
# boot chain does not care that the partition got smaller.
#
# Loopback only; never point this at a block device.
#
# Usage: sudo ./shrink-image.sh SRC.img DST.img [TOTAL_SIZE] [FS_SIZE]

set -euo pipefail

SRC="${1:?usage: shrink-image.sh SRC.img DST.img [TOTAL] [FS]}"
DST="${2:?usage: shrink-image.sh SRC.img DST.img [TOTAL] [FS]}"
TOTAL="${3:-25G}"
FS_SIZE="${4:-24G}"

[[ $EUID -eq 0 ]] || { echo "Error: must run as root." >&2; exit 1; }
[[ -f "$SRC" ]] || { echo "Error: $SRC does not exist." >&2; exit 1; }
[[ -b "$SRC" || -b "$DST" ]] && { echo "Error: block device given; loopback only." >&2; exit 1; }

LOOP=""
cleanup() { set +e; [[ -n "$LOOP" ]] && losetup -d "$LOOP" 2>/dev/null; }
trap cleanup EXIT

echo "==> Copying $SRC -> $DST (sparse)"
cp --sparse=always "$SRC" "$DST"

echo "==> Shrinking root filesystem to $FS_SIZE"
LOOP="$(losetup --find --show --partscan "$DST")"
udevadm settle 2>/dev/null || true
ROOT_PART="${LOOP}p2"; [[ -b "$ROOT_PART" ]] || ROOT_PART="${LOOP}2"
e2fsck -f -p "$ROOT_PART"
resize2fs "$ROOT_PART" "$FS_SIZE"

# Re-read the real post-shrink size rather than trusting the requested
# one; resize2fs rounds up to a block boundary.
FS_BLOCKS="$(dumpe2fs -h "$ROOT_PART" 2>/dev/null | awk -F: '/^Block count/{print $2}' | tr -d ' ')"
FS_BSIZE="$(dumpe2fs -h "$ROOT_PART" 2>/dev/null | awk -F: '/^Block size/{print $2}' | tr -d ' ')"
losetup -d "$LOOP"; LOOP=""

P2_START=1050624
P2_SECTORS=$(( FS_BLOCKS * FS_BSIZE / 512 ))
P2_END=$(( P2_START + P2_SECTORS - 1 ))
echo "==> Root fs is now $FS_BLOCKS x $FS_BSIZE blocks; partition 2 = $P2_START..$P2_END"

echo "==> Rewriting partition 2 and truncating to $TOTAL"
# sfdisk rather than sgdisk: util-linux is everywhere, gptfdisk is not.
# Dumping and re-applying the table preserves both partitions' GUIDs and
# types instead of inventing new ones. `last-lba` has to go, or sfdisk
# would keep the backup header at the old (pre-truncate) location.
TABLE="$(mktemp)"
sfdisk -d "$DST" > "$TABLE"
python3 - "$TABLE" "$P2_SECTORS" <<'PYEOF'
import re, sys
path, sectors = sys.argv[1], sys.argv[2]
out = []
for line in open(path):
    if line.startswith("last-lba:"):
        continue
    if re.search(r"start=\s*1050624\b", line):
        line = re.sub(r"(size=\s*)\d+", r"\g<1>" + sectors, line)
    out.append(line)
open(path, "w").writelines(out)
PYEOF
truncate -s "$TOTAL" "$DST"
sfdisk --force "$DST" < "$TABLE" >/dev/null
rm -f "$TABLE"

echo "==> Verifying the shrunk filesystem"
LOOP="$(losetup --find --show --partscan "$DST")"
udevadm settle 2>/dev/null || true
ROOT_PART="${LOOP}p2"; [[ -b "$ROOT_PART" ]] || ROOT_PART="${LOOP}2"
e2fsck -f -n "$ROOT_PART"
losetup -d "$LOOP"; LOOP=""

echo "==> Done. $DST ($(du -h "$DST" | cut -f1) actual, $(stat -c%s "$DST") bytes apparent)"
sfdisk -l "$DST" 2>/dev/null | tail -4
