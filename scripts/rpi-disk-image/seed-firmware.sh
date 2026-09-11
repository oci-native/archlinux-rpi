#!/bin/bash
# Seed the VideoCore firmware partition (bootc's ESP, partition 1) with the
# blobs and config that nothing in the container image or in bootc ever
# writes there. See docs/disk-image.md, section 1 and 3, for why this step
# exists and what it must not duplicate.
#
# Usage: seed-firmware.sh <firmware-partition-mountpoint> <firmware-source-dir>
#
#   <firmware-partition-mountpoint>  already-mounted vfat partition 1 (the
#                                    ESP that `bootc install to-disk` created;
#                                    doubles as the Pi firmware partition).
#   <firmware-source-dir>            /usr/lib/raspberrypi/boot inside the
#                                    built container/deployment: bootcode.bin,
#                                    start4*.elf, fixup4*.dat.
#
# What this script deliberately does NOT do: it does not write config.txt,
# config-bootc-default.txt, config-bootc-fallback.txt, tryboot.txt, or the
# bootc/entries/ostree-N/ tree. Those are `rpi-bootc-bootloader sync`'s job,
# run separately, once this partition already exists and has the VideoCore
# blobs on it. If config.txt already exists, sync leaves it alone, so it is
# safe to run this script before or after sync, but firmware blobs should
# land before the first `sync` so a stray boot attempt between steps still
# has something to load.

set -euo pipefail

usage() {
	echo "Usage: $0 <firmware-partition-mountpoint> <firmware-source-dir>" >&2
	exit 1
}

[[ $# -eq 2 ]] || usage

FW_MNT="$1"
FW_SRC="$2"

[[ -d "$FW_MNT" ]] || { echo "Error: $FW_MNT is not a directory" >&2; exit 1; }
[[ -d "$FW_SRC" ]] || { echo "Error: $FW_SRC is not a directory" >&2; exit 1; }
mountpoint -q "$FW_MNT" || echo "Warning: $FW_MNT is not a mountpoint; proceeding anyway (loopback test mode)" >&2

# The 16 VideoCore blobs plus bootcode.bin. Only start4*/fixup4* apply to
# BCM2711/BCM2712 (Pi 4 and 5); the non-'4' variants are Pi 1/2/3/Zero and
# are copied too since raspberrypi-bootloader ships them together and cost
# nothing to carry (a few hundred KB), in case a card gets reused in older
# hardware.
shopt -s nullglob
blobs=("$FW_SRC"/bootcode.bin "$FW_SRC"/start*.elf "$FW_SRC"/fixup*.dat)
shopt -u nullglob

if [[ ${#blobs[@]} -eq 0 ]]; then
	echo "Error: no VideoCore blobs found under $FW_SRC" >&2
	exit 1
fi

copied=0
for f in "${blobs[@]}"; do
	name="$(basename "$f")"
	if ! cmp -s "$f" "$FW_MNT/$name" 2>/dev/null; then
		install -m 0644 "$f" "$FW_MNT/$name"
		copied=$((copied + 1))
	fi
done
echo "Seeded $copied/${#blobs[@]} VideoCore firmware blob(s) into $FW_MNT"

# config-bootc-common.txt is explicitly user-owned territory per
# rpi-bootc-bootloader's design.md ("User manages config-boot-common.txt and
# rpi-config.txt"); sync only creates it if absent, and never overwrites it
# afterward. This is our one chance to seed non-default global settings
# (UART for the serial console, Pi 5 specifics) before that file exists.
if [[ ! -f "$FW_MNT/config-bootc-common.txt" ]]; then
	cat > "$FW_MNT/config-bootc-common.txt" <<'EOF'
# Managed by the oci-native/archlinux-rpi image build at first provisioning.
# rpi-bootc-bootloader creates config.txt / config-bootc-default.txt /
# config-bootc-fallback.txt itself and includes this file from all of them,
# so put board-wide settings here rather than editing the generated files.

[all]
arm_64bit=1
enable_uart=1

[pi5]
# BCM2712 has no arm_boost knob; kept for documentation parity with Pi 4.
EOF
	echo "Wrote default config-bootc-common.txt"
else
	echo "config-bootc-common.txt already present, leaving it alone"
fi

echo "Firmware partition contents:"
ls -la "$FW_MNT"
