#!/bin/bash
# Inject host configuration from secrets.env directly into a mounted
# ostree deployment's filesystem. Called by build-disk-image.sh after
# `bootc install to-disk` and before the first `rpi-bootc-bootloader sync`.
#
# Nothing here ever touches a Containerfile, a RUN step, or any container
# image layer -- this operates purely on the mounted loopback filesystem
# on the host, after the image has already been built and installed. That
# is the whole point: secrets.env is gitignored and must never be baked
# into anything that could be pushed to this (public) repo's registry.
#
# Deliberately does not chroot or execute anything from the deployed
# (aarch64) filesystem: user/password/service-enablement here is plain
# file and symlink manipulation, hashing runs on the host with the host's
# own openssl. Faster, and it sidesteps qemu-user entirely for this step.
#
# Usage: provision-secrets.sh <sysroot-mountpoint> <secrets-env-path>

set -euo pipefail

SYSROOT="$1"
SECRETS_ENV="$2"

# shellcheck source=/dev/null
source "$SECRETS_ENV"

DEPLOY_DIR="$(compgen -G "$SYSROOT/ostree/deploy/default/deploy/*/" | head -1)"
[[ -n "$DEPLOY_DIR" ]] || { echo "Error: no ostree deployment found under $SYSROOT" >&2; exit 1; }
DEPLOY_DIR="${DEPLOY_DIR%/}"
STATEROOT_VAR="$SYSROOT/ostree/deploy/default/var"

echo "==> hostname: $RPI_HOSTNAME"
printf '%s\n' "$RPI_HOSTNAME" > "$DEPLOY_DIR/etc/hostname"

echo "==> root and $RPI_USER passwords"
ROOT_HASH="$(openssl passwd -6 "$RPI_PASSWORD")"
USER_HASH="$ROOT_HASH"
# Same password for both, per the task: root password exists so a serial
# console login works if ssh doesn't. crypt(3) SHA-512 hashes only use
# [./0-9A-Za-z$], never the sed delimiter below.
sed -i "s|^root:[^:]*:|root:${ROOT_HASH}:|" "$DEPLOY_DIR/etc/shadow"

if grep -q "^${RPI_USER}:" "$DEPLOY_DIR/etc/passwd"; then
	echo "Error: user $RPI_USER already exists in the target image, refusing to guess intent" >&2
	exit 1
fi

UID_GID=1000
while grep -q ":${UID_GID}:${UID_GID}:" "$DEPLOY_DIR/etc/passwd"; do
	UID_GID=$((UID_GID + 1))
done

echo "==> creating user $RPI_USER (uid/gid $UID_GID, wheel)"
HOME_DIR="/var/home/${RPI_USER}"
echo "${RPI_USER}:x:${UID_GID}:${UID_GID}:${RPI_USER}:${HOME_DIR}:/bin/bash" >> "$DEPLOY_DIR/etc/passwd"
echo "${RPI_USER}:x:${UID_GID}:" >> "$DEPLOY_DIR/etc/group"
LASTCHANGED=$(( $(date +%s) / 86400 ))
echo "${RPI_USER}:${USER_HASH}:${LASTCHANGED}:0:99999:7:::" >> "$DEPLOY_DIR/etc/shadow"

WHEEL_LINE="$(grep '^wheel:' "$DEPLOY_DIR/etc/group" || true)"
[[ -n "$WHEEL_LINE" ]] || { echo "Error: no wheel group in target image's /etc/group" >&2; exit 1; }
WHEEL_PREFIX="$(cut -d: -f1-3 <<< "$WHEEL_LINE")"
WHEEL_MEMBERS="$(cut -d: -f4 <<< "$WHEEL_LINE")"
if [[ -n "$WHEEL_MEMBERS" ]]; then
	NEW_WHEEL_MEMBERS="${WHEEL_MEMBERS},${RPI_USER}"
else
	NEW_WHEEL_MEMBERS="${RPI_USER}"
fi
sed -i "s|^wheel:.*|${WHEEL_PREFIX}:${NEW_WHEEL_MEMBERS}|" "$DEPLOY_DIR/etc/group"

mkdir -p "${STATEROOT_VAR}/home/${RPI_USER}"
for f in .bash_profile .bashrc .bash_logout; do
	[[ -f "$DEPLOY_DIR/etc/skel/$f" ]] && cp "$DEPLOY_DIR/etc/skel/$f" "${STATEROOT_VAR}/home/${RPI_USER}/$f"
done
chown -R "${UID_GID}:${UID_GID}" "${STATEROOT_VAR}/home/${RPI_USER}"
chmod 0700 "${STATEROOT_VAR}/home/${RPI_USER}"

echo "==> enabling wheel sudo"
if ! grep -q '^#includedir /etc/sudoers.d' "$DEPLOY_DIR/etc/sudoers" && \
   ! grep -q '^@includedir /etc/sudoers.d' "$DEPLOY_DIR/etc/sudoers"; then
	echo "Error: /etc/sudoers has no sudoers.d includedir, refusing to hand-edit it" >&2
	exit 1
fi
install -d -m 0750 "$DEPLOY_DIR/etc/sudoers.d"
printf '%%wheel ALL=(ALL:ALL) ALL\n' > "$DEPLOY_DIR/etc/sudoers.d/wheel"
chmod 0440 "$DEPLOY_DIR/etc/sudoers.d/wheel"
chown root:root "$DEPLOY_DIR/etc/sudoers.d/wheel"

# Honours RPI_SSH_PASSWORD_AUTH rather than hardcoding it, so turning
# password auth off later is an edit to secrets.env and not to this
# script. PermitRootLogin follows it: the root password exists so a
# serial-console login works when ssh doesn't, and if password auth is
# off there is no key provisioned for root to log in with anyway.
SSH_PW_AUTH="${RPI_SSH_PASSWORD_AUTH:-yes}"
case "$SSH_PW_AUTH" in
	yes|no) ;;
	*) echo "Error: RPI_SSH_PASSWORD_AUTH must be 'yes' or 'no', got '$SSH_PW_AUTH'" >&2; exit 1 ;;
esac
echo "==> sshd: PasswordAuthentication $SSH_PW_AUTH, PermitRootLogin $SSH_PW_AUTH"
install -d "$DEPLOY_DIR/etc/ssh/sshd_config.d"
printf '%s\n' \
	'# Written by provision-secrets.sh at disk-image build time.' \
	'# Password auth for this board, from RPI_SSH_PASSWORD_AUTH.' \
	"PasswordAuthentication $SSH_PW_AUTH" \
	"PermitRootLogin $SSH_PW_AUTH" \
	> "$DEPLOY_DIR/etc/ssh/sshd_config.d/10-rpi-password-auth.conf"

echo "==> NetworkManager: wifi profile for SSID $RPI_WIFI_SSID"
install -d -m 0755 "$DEPLOY_DIR/etc/NetworkManager/system-connections"
NM_FILE="$DEPLOY_DIR/etc/NetworkManager/system-connections/${RPI_WIFI_SSID}.nmconnection"
cat > "$NM_FILE" <<EOF
[connection]
id=${RPI_WIFI_SSID}
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=${RPI_WIFI_SSID}

[wifi-security]
key-mgmt=wpa-psk
psk=${RPI_WIFI_PSK}

[ipv4]
method=auto

[ipv6]
method=auto
addr-gen-mode=default
EOF
# NetworkManager refuses to load a system connection that isn't exactly
# 600, root-owned -- it treats looser permissions as a secrets leak risk.
chmod 0600 "$NM_FILE"
chown root:root "$NM_FILE"

echo "==> enabling sshd and NetworkManager"
# systemctl --root= only reads [Install] sections and writes symlinks --
# pure metadata, no need to run anything from the (aarch64) target, so the
# host's own systemctl handles this fine.
systemctl --root="$DEPLOY_DIR" enable sshd.service NetworkManager.service

echo "==> done provisioning $DEPLOY_DIR"
