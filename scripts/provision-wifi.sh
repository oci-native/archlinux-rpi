#!/usr/bin/env bash
# Put the wifi passphrase onto a freshly flashed card, before first boot.
#
# The Pi has no ethernet, so wifi is the only way in and it has to work on the
# first try.
#
# The image declares the network with pskRaw = "ext:psk_wifi", which makes
# wpa_supplicant read the passphrase at runtime from secretsFile instead of
# embedding it. That is why this can be written here rather than baked in:
# nothing sensitive reaches the nix store, this repository, or CI.
#
# Note that wpa_supplicant's BindReadOnlyPaths entry for secretsFile has no '-'
# prefix, so the unit fails to start if this file is missing. On a headless,
# ethernet-less box that means no way in at all -- run this before first boot.
#
# The passphrase is never printed.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dev="${1:-}"
env_file="${2:-$repo_root/secrets.env}"

if [[ -z $dev ]]; then
    echo "usage: sudo $0 <root-partition> [secrets.env]" >&2
    echo "  e.g. sudo $0 /dev/sdb2" >&2
    exit 2
fi
[[ $EUID -eq 0 ]] || { echo "needs root: mounting a filesystem" >&2; exit 1; }
[[ -b $dev ]] || { echo "not a block device: $dev" >&2; exit 1; }
[[ -r $env_file ]] || { echo "no secrets file: $env_file" >&2; exit 1; }

# shellcheck disable=SC1090
set -a; source "$env_file"; set +a
: "${RPI_WIFI_SSID:?RPI_WIFI_SSID is unset}"
: "${RPI_WIFI_PSK:?RPI_WIFI_PSK is unset}"

# wpa_supplicant treats an 8..63 character value as a passphrase and exactly 64
# as a hex PMK; anything else is rejected at connect time with "Unexpected PSK
# length", which on this box would be invisible.
len=${#RPI_WIFI_PSK}
if (( len < 8 || len > 64 )); then
    echo "passphrase is $len characters; wpa_supplicant accepts 8-63, or exactly 64 hex" >&2
    exit 1
fi

# Refuse to touch anything that is not the NixOS root we just wrote.
fstype="$(blkid -s TYPE -o value "$dev" || true)"
[[ $fstype == ext4 ]] || { echo "$dev is '$fstype', expected ext4" >&2; exit 1; }

mnt="$(mktemp -d)"
cleanup() { umount "$mnt" 2>/dev/null || true; rmdir "$mnt" 2>/dev/null || true; }
trap cleanup EXIT

mount "$dev" "$mnt"
[[ -d $mnt/nix/store ]] || { echo "$dev has no /nix/store; wrong partition?" >&2; exit 1; }

install -d -m 0700 -o 0 -g 0 "$mnt/var/lib/wireless"
secrets="$mnt/var/lib/wireless/secrets.conf"

# Format is NAME=VALUE, split on the first '=', value taken verbatim to end of
# line. No quoting, no escapes. The name must match the ext: reference in the
# image, which is psk_wifi.
umask 077
printf 'psk_wifi=%s\n' "$RPI_WIFI_PSK" > "$secrets"
chmod 0600 "$secrets"
chown 0:0 "$secrets"

sync
echo "wrote the passphrase for SSID '${RPI_WIFI_SSID}' to /var/lib/wireless/secrets.conf (root:root 0600)"
echo "it was not printed and is not in the image"
