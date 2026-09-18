#!/bin/bash
# Builds the linux-rpi package from a chosen raspberrypi/linux commit, using
# ALARM's own PKGBUILD (vendored next to this script, untouched apart from the
# commit/version fields rewritten below). Runs as root inside the
# localhost/archlinuxarm:latest container on a native arm64 runner.
#
# Inputs (env): KERNEL_COMMIT (full sha), KERNEL_VER (e.g. 7.2.6),
#               KERNEL_PKGREL (default 1)
# Output: /out/*.pkg.tar.xz
set -euxo pipefail

: "${KERNEL_COMMIT:?}" "${KERNEL_VER:?}"
KERNEL_PKGREL=${KERNEL_PKGREL:-1}

# Same pacman prep as the image's builder stage (see the Containerfile).
sed -i '/^\[options\]/a DisableSandbox\nDisableDownloadTimeout\nParallelDownloads = 5' /etc/pacman.conf
pacman-key --init
pacman-key --populate archlinuxarm
# makedepends plus the package's own depends: makepkg checks both are
# present before building (and without -s it will not fetch them itself).
pacman -Syu --noconfirm base-devel pacman-contrib bc kmod inetutils git python \
  coreutils firmware-raspberrypi mkinitcpio raspberrypi-bootloader
# Use every core, and let xz use them too when it packs ~100MB of modules.
sed -i \
  -e "s|^#\?MAKEFLAGS=.*|MAKEFLAGS=\"-j$(nproc)\"|" \
  -e "s|^COMPRESSXZ=.*|COMPRESSXZ=(xz -T0 -c -z -)|" \
  /etc/makepkg.conf
grep -E '^(MAKEFLAGS|COMPRESSXZ|PKGEXT)=' /etc/makepkg.conf

# makepkg refuses to run as root; every makedepend is already installed, so
# the builder user never needs sudo.
useradd -m builder
cp -r /src /home/builder/pkg
chown -R builder:builder /home/builder/pkg

cd /home/builder/pkg
sed -i \
  -e "s|^_commit=.*|_commit=${KERNEL_COMMIT}|" \
  -e "s|^pkgver=.*|pkgver=${KERNEL_VER}|" \
  -e "s|^pkgrel=.*|pkgrel=${KERNEL_PKGREL}|" \
  PKGBUILD
grep -E '^(_commit|pkgver|pkgrel)=' PKGBUILD

# updpkgsums fetches the source tarball and rewrites the checksum for the
# new commit; the other files are vendored and keep their sums.
su builder -c 'updpkgsums && makepkg --noconfirm --skippgpcheck'

mkdir -p /out
cp ./*.pkg.tar.* /out/
ls -la /out
