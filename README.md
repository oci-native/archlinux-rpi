# Arch Linux bootc image for the Raspberry Pi

An aarch64 Arch Linux bootable container for the Raspberry Pi, built so that
`bootc upgrade` and `bootc rollback` work the way they do on a normal UEFI machine.

This is the Raspberry Pi sibling of [oci-native/archlinux](https://github.com/oci-native/archlinux).
Same idea, same tooling, different boot chain.

The current pipeline lives in `10-kitten-rpi-arch/`, adapted from the
[AlmaLinux/bootc-images-rpi](https://github.com/AlmaLinux/bootc-images-rpi)
Makefile and Containerfile framework. It is verified on real hardware: a
Raspberry Pi 5 boots the SD image in about 20 seconds, ethernet (`end0`) and
onboard wifi (`wld0`) both work, and `bootc upgrade` pulls new images from ghcr.

CI ([`.github/workflows/build-arch-rpi.yml`](.github/workflows/build-arch-rpi.yml),
running on a native `ubuntu-24.04-arm` runner) builds and pushes
`ghcr.io/oci-native/archlinux-bootc-rpi` with the tags `latest`, `bootstrap`
(latest plus cloud-init) and `<date>-<sha>`, and assembles a flashable SD image
uploaded as the workflow artifact `archlinux-bootc-rpi-sdcard-image` (about
400MB of xz, 8G raw, 14-day retention).

## Quickstart

### 1. Get the image

Download the SD image artifact from the latest green "Build Arch RPi (ghcr.io)"
workflow run:

```sh
gh run download <run-id> -R oci-native/archlinux-rpi -n archlinux-bootc-rpi-sdcard-image
```

If the latest artifact has expired, trigger a fresh build:

```sh
gh workflow run build-arch-rpi.yml -R oci-native/archlinux-rpi
```

### 2. Flash

```sh
xzcat archlinux-bootc-rpi-<date>-<sha>.raw.xz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

`dd` overwrites the partition table, so the card does not need wiping first.

### 3. Add your SSH key

Mount the FAT partition (labeled `CIDATA`, readable on any OS) and edit
`user-data`. Put your public key under `ssh_authorized_keys` for the `alarm`
user. Password SSH auth is off; `alarm` has passwordless sudo. On first boot
cloud-init grows the root partition and filesystem to fill the card.

### 4. Headless wifi (optional, read this part)

cloud-init's NoCloud `network-config` cannot configure wifi on this image.
cloud-init's NetworkManager renderer silently drops `wifis:` sections; only
netplan-based distros support them, an upstream cloud-init limitation. Ethernet
needs no configuration at all, NetworkManager DHCPs it automatically.

What works for wifi is a NetworkManager keyfile written into the root
partition's `/etc`. Mount partition 3 (xfs) and create

```
ostree/deploy/default/deploy/<checksum>.0/etc/NetworkManager/system-connections/<SSID>.nmconnection
```

owned by root:root with mode 0600, containing:

```ini
[connection]
id=<SSID>
type=wifi
interface-name=wld0
autoconnect=true
autoconnect-retries=0

[wifi]
mode=infrastructure
ssid=<SSID>
powersave=2

[wifi-security]
key-mgmt=wpa-psk
psk=<password>

[ipv4]
method=auto

[ipv6]
method=auto
```

`powersave=2` (disabled) matters. With power save on, brcmfmac dropped the Pi
off the network a few minutes after boot.

### 5. Boot

Insert the card and power on. The Pi joins the network, then:

```sh
ssh alarm@<ip>
```

### 6. Updates

```sh
sudo bootc upgrade
```

This pulls the `:bootstrap` tag from ghcr. The package is public, so anonymous
pulls work. Every push to main that touches the image paths rebuilds and pushes;
the Pi picks it up on the next upgrade.

## What is on the card

The disk layout is plain MBR:

| partition | filesystem | contents |
| --- | --- | --- |
| p1 | FAT32, label `CIDATA` | RPi firmware, `config.txt`, the `bootc/entries/` boot chain (via [kfox1111/rpi-bootc-bootloader](https://github.com/kfox1111/rpi-bootc-bootloader)), and the cloud-init NoCloud seed files |
| p2 | xfs | `/boot` |
| p3 | xfs | root |

There is no bootc-image-builder involved, since it needs bootupd and bootupd
does not exist on Arch. The install step is
`bootc install to-filesystem --bootloader none` against the pre-made
filesystems.

The kernel is `linux-rpi` (4K pages).

## Known quirks

`sudo bootc status` may print a mount hint about fstab being modified. ostree's
/etc merge refreshes `/etc/fstab`'s timestamp after systemd has already read
it. Harmless; silence it with `systemctl daemon-reload`.

The wifi regulatory domain defaults to the restrictive world domain, which
broke channel scans on reconnection (`brcmf_set_channel` reason -52).
Recommended per-device fix, using your country code:

```sh
echo 'options cfg80211 ieee80211_regdom=<CC>' | sudo tee /etc/modprobe.d/regdom.conf
```

composefs is disabled in `prepare-root.conf` for now.

## Why the boot chain is the interesting part

A Raspberry Pi has no UEFI. The VideoCore firmware reads `config.txt` off a FAT
partition and loads a kernel directly. bootc's usual world assumes an EFI system
partition, a boot loader, and `bootupd` to keep that loader updated. None of that
exists here, and `bootupd` has no Raspberry Pi support (coreos/bootupd#651 and #959
are both still open).

The way through, borrowed from [AlmaLinux/bootc-images-rpi](https://github.com/AlmaLinux/bootc-images-rpi),
is to let the firmware be the A/B boot loader. bootc and ostree write ordinary boot
loader entries. A hook on `ostree-finalize-staged.service` then mirrors each
deployment's kernel, initramfs, device trees and command line onto the FAT partition
under its own directory, and points `os_prefix` in `config.txt` at whichever one should
boot next:

    bootc/entries/ostree-1/{vmlinuz,initrd,cmdline.txt,*.dtb,overlays/}
    bootc/entries/ostree-2/{...}
    config.txt -> os_prefix=bootc/entries/ostree-N/

`os_prefix` is a stock firmware feature, and three useful things fall out of it. The
firmware's `[gpio6=1]` conditional lets a physical button select the other slot. The
`tryboot` flag plus `dtparam=watchdog=on` reverts a deployment that fails to come up.
And there is no boot loader to update, so nothing needs `bootupd` at all.

## Layout

| path | what it is |
| --- | --- |
| `10-kitten-rpi-arch/` | the current pipeline: bootc image plus the cloud-init bootstrap variant |
| `.github/workflows/build-arch-rpi.yml` | CI that builds, pushes to ghcr and assembles the SD image |
| `docs/` | design notes and the research each decision rests on |
| `STATUS.md` | what is decided, what is verified, what is still open |

## Related

- [oci-native/archlinux](https://github.com/oci-native/archlinux) is the x86_64 sibling.
- [AlmaLinux/bootc-images-rpi](https://github.com/AlmaLinux/bootc-images-rpi) is the
  reference architecture and the first working example of bootc booting a
  Raspberry Pi through native firmware.
- [kfox1111/rpi-bootc-bootloader](https://github.com/kfox1111/rpi-bootc-bootloader) is
  the sync hook that makes it work. We vendor a patched copy rather than fetching it at
  build time.

## Earlier pipelines

Two older lines live in this repo and predate `10-kitten-rpi-arch/`. They are
kept for reference.

### Containerfile.* (Arch, patched bootc)

The first Arch attempt, split across build stages:

| path | what it is |
| --- | --- |
| `Containerfile.rootfs` | bootstraps an aarch64 Arch rootfs, since none is published as a container image |
| `Containerfile.base` | the bootc base: kernel, dracut initramfs, ostree layout |
| `Containerfile.rpi` | Raspberry Pi 5 specifics: firmware, device trees, the sync hook |
| `shared/` | scripts shared between build stages |

### NixOS (`nix/`)

A NixOS variant with the same boot mechanism: native Pi firmware, bootc with
the ostree backend, composefs on, no UEFI and no U-Boot. Findings and the
rationale are in `docs/nixos-pivot.md`, which also records that every image
from the Containerfile.* line forced the wrong SD host controller driver into
its initramfs.

There is no Nix on the build host and none is required. `nix/nixrun.sh` runs
everything inside `docker.io/nixos/nix` with the store in a podman volume, and
aarch64 derivations build through the host's binfmt registration.

    ./nix/mksecrets.sh                       # secrets.env -> nix/secrets.nix
    ./nix/nixrun.sh nix build --impure \
        ./nix#nixosConfigurations.sd.config.system.build.sdImage
