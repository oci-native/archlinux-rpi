#!/bin/bash
# Shared by build-disk-image.sh and provision-image.sh, both of which run
# under sudo and both of which need to `podman run` the built image.
#
# Under sudo, `podman` is root's podman, and rootless podman storage is
# per-user -- root's image store is a completely separate store from the
# one the unprivileged user actually built the image into. Without this,
# `podman run localhost/archlinux-rpi:latest` as root does not find the
# image locally and falls through to a registry pull for a "localhost/"
# reference, which fails outright.
#
# Not a library in any general sense; it exists so the two entry points
# can't drift apart on this one fiddly step.

# Copy $1 from $SUDO_USER's rootless podman store into root's, if root
# doesn't already have it. No-op when not running under sudo, or when the
# image is already present.
ensure_root_has_image() {
	local image_ref="$1"

	if podman image exists "$image_ref"; then
		return 0
	fi
	if [[ -z "${SUDO_USER:-}" ]]; then
		echo "Error: $image_ref not in root's podman store, and not running" >&2
		echo "under sudo, so there's no user store to copy it from." >&2
		return 1
	fi

	echo "==> Transferring ${image_ref} into root's podman storage"
	# root's own mktemp dirs are mode 0700, so $SUDO_USER can't write into
	# one. Have them create and own the tmpfile instead; root can still
	# read it to load, then remove it.
	local image_tar
	image_tar="$(sudo -u "$SUDO_USER" mktemp)"
	sudo -u "$SUDO_USER" podman save "$image_ref" -o "$image_tar"
	podman load -i "$image_tar"
	rm -f "$image_tar"
}
