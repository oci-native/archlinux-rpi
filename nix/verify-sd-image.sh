#!/usr/bin/env bash
# Check that an SD image actually has something bootable on its FAT partition.
#
# This exists because the first two images built here did not, and nothing
# caught it: the partition table was right, the filesystem was right, the
# VideoCore blobs were right, and there was no kernel.
#
# Read-only. Uses mtools through the nix container, so it needs no root and no
# loopback device.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
img="${1:?usage: verify-sd-image.sh IMAGE}"
[[ -f $img ]] || { echo "not a file: $img" >&2; exit 1; }
[[ -b $img ]] && { echo "refusing to read a block device; pass an image file" >&2; exit 1; }

fw_start_sectors="$(sfdisk -d "$img" | awk '/1 *: *start=/ {gsub(/,/,""); print $4}')"
fw_offset=$(( fw_start_sectors * 512 ))

rel="${img#"$repo_root"/}"

fails=0
ok() {
    local label="$1" shift_rc=0
    shift
    if "$@" >/dev/null 2>&1; then printf 'OK    %s\n' "$label"
    else printf 'FAIL  %s\n' "$label"; fails=$((fails + 1)); fi
}

listing="$(
    "$repo_root/nix/nixrun.sh" sh -c \
        "nix shell nixpkgs#mtools -c mdir -b -/ -i '/repo/${rel}@@${fw_offset}' ::" 2>/dev/null
)"

has() { grep -qiF -- "$1" <<<"$listing"; }

ok "firmware partition readable"        test -n "$listing"
ok "kernel image present"               has "::/Image"
ok "initrd present"                     has "::/initrd"
ok "cmdline.txt present"                has "::/cmdline.txt"
ok "config.txt present"                 has "::/config.txt"
ok "Pi 5 base DTB present"              has "bcm2712-rpi-5-b.dtb"
ok "overlay_map.dtb present"            has "overlays/overlay_map.dtb"
ok "hat_map.dtb present"                has "overlays/hat_map.dtb"

read_file() {
    "$repo_root/nix/nixrun.sh" sh -c \
        "nix shell nixpkgs#mtools -c mtype -i '/repo/${rel}@@${fw_offset}' '::$1'" 2>/dev/null
}

cmdline="$(read_file /cmdline.txt || true)"
configtxt="$(read_file /config.txt || true)"

ok "cmdline names an init"               grep -q 'init=/nix/store/' <<<"$cmdline"
ok "config.txt names the kernel"         grep -q '^kernel=Image' <<<"$configtxt"
ok "config.txt loads the initramfs"      grep -q '^initramfs initrd followkernel' <<<"$configtxt"

echo
echo "cmdline.txt: $cmdline"
echo
echo "$fails failure(s)"
[[ $fails -eq 0 ]]
