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

No prior bootc or cloud-init knowledge assumed. Every command is spelled out;
anything in `<angle brackets>` is a placeholder you replace.

### 0. What you need

A Linux machine to flash from. `xz` and `dd` are preinstalled on every distro.
You also need the GitHub CLI to download the image; install it from your
package manager (`pacman -S github-cli`, `apt install gh`, `dnf install gh`)
and log in once:

```sh
gh auth login
```

Pick GitHub.com and follow the browser prompt. Any GitHub account works; you
only need it because workflow artifacts require a login to download.

On macOS there is no safe `dd` habit to lean on. Decompress the image
(`xz -d archlinux-bootc-rpi-<date>-<sha>.raw.xz`) and flash the resulting
`.raw` file with Raspberry Pi Imager, choosing "Use custom image". Then rejoin
at step 4.

### 1. Download the SD image

Find the id of the latest green run of the build workflow:

```sh
gh run list -R oci-native/archlinux-rpi -w "Build Arch RPi (ghcr.io)" -L1
```

The output is a single line. Check it says `completed` and `success`, then take
the long number in the ID column (the last numeric field). Download the
artifact from that run:

```sh
gh run download <run-id> -R oci-native/archlinux-rpi -n archlinux-bootc-rpi-sdcard-image
```

This drops `archlinux-bootc-rpi-<date>-<sha>.raw.xz` (about 400MB) into the
current directory. Artifacts expire after 14 days; if the download fails
because the run is old, trigger a fresh build and wait for it to go green:

```sh
gh workflow run build-arch-rpi.yml -R oci-native/archlinux-rpi
```

### 2. Find the SD card device

Get this right: `dd` will silently destroy whatever device you point it at.
List your disks before inserting the card:

```sh
lsblk -o NAME,SIZE,RM,TRAN,MODEL
```

Insert the card (or the USB reader holding it) and run the same command again.
The device that appeared is your card, typically `/dev/sdb` or similar for a
USB reader (`RM 1`, `TRAN usb`) or `/dev/mmcblk0` for a built-in slot. Use the
whole device in the next step, not a partition: `/dev/sdb`, never `/dev/sdb1`;
`/dev/mmcblk0`, never `/dev/mmcblk0p1`.

### 3. Flash

Replace `/dev/sdX` with your device from step 2:

```sh
xzcat archlinux-bootc-rpi-<date>-<sha>.raw.xz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

`dd` overwrites the partition table, so the card does not need wiping or
formatting first. It is done when the progress output stops and your prompt
returns; then flush any remaining cache:

```sh
sync
```

### 4. Put your SSH key on the card

Password SSH login is off, so the Pi is unreachable until your public key is
on the card. Check whether you already have one:

```sh
ls ~/.ssh/*.pub
```

If that lists nothing, generate a key, pressing enter at every prompt:

```sh
ssh-keygen -t ed25519
```

Print the public half and copy the whole line it outputs:

```sh
cat ~/.ssh/id_ed25519.pub
```

Now mount the card's first partition, a 1G FAT32 partition labeled `CIDATA`
(readable on any OS). With the card still plugged in:

```sh
sudo mkdir -p /mnt/cidata
sudo mount /dev/sdX1 /mnt/cidata
```

(`/dev/mmcblk0p1` if your device is `/dev/mmcblk0`.) Edit the cloud-init seed
file with any editor:

```sh
sudo nano /mnt/cidata/user-data
```

Find the `ssh_authorized_keys:` list under the `alarm` user and replace the
key that ships in the file with your own, so the block reads:

```yaml
    ssh_authorized_keys:
      - ssh-ed25519 AAAA...your key... you@yourmachine
```

Paste the full line from the `cat` above. Keep the indentation as shown, save,
and unmount:

```sh
sudo umount /mnt/cidata
```

On first boot cloud-init applies this file, grows the root partition and
filesystem to fill the card, and sets up the `alarm` user with passwordless
sudo.

### 5. Headless wifi (optional, read this part)

Skip this if the Pi will be on ethernet: NetworkManager DHCPs `end0`
automatically with no configuration.

For wifi, know that cloud-init's NoCloud `network-config` cannot configure
wifi on this image. cloud-init's NetworkManager renderer silently drops
`wifis:` sections; only netplan-based distros support them, an upstream
cloud-init limitation. What works is a NetworkManager keyfile written into the
root partition's `/etc` before first boot.

Mount the card's third partition (xfs) and locate the ostree deployment
directory:

```sh
sudo mkdir -p /mnt/sdroot
sudo mount /dev/sdX3 /mnt/sdroot
ls /mnt/sdroot/ostree/deploy/default/deploy/
```

The listing shows one directory whose name is a long checksum ending in `.0`.
That directory is the deployed root filesystem. Set a variable to it and write
the keyfile, replacing `<your network name>` and `<your wifi password>` first:

```sh
DEPLOY=/mnt/sdroot/ostree/deploy/default/deploy/<the directory ending in .0>

sudo tee "$DEPLOY/etc/NetworkManager/system-connections/wifi.nmconnection" > /dev/null <<'EOF'
[connection]
id=wifi
type=wifi
interface-name=wld0
autoconnect=true
autoconnect-retries=0

[wifi]
mode=infrastructure
ssid=<your network name>
powersave=2

[wifi-security]
key-mgmt=wpa-psk
psk=<your wifi password>

[ipv4]
method=auto

[ipv6]
method=auto
EOF

sudo chmod 600 "$DEPLOY/etc/NetworkManager/system-connections/wifi.nmconnection"
sudo umount /mnt/sdroot
```

NetworkManager ignores keyfiles with looser permissions, hence the
`chmod 600`. `powersave=2` (disabled) matters: with power save on, brcmfmac
dropped the Pi off the network a few minutes after boot.

### 6. Boot and find the Pi

Insert the card and power on. The Pi is up and on the network in about 20
seconds.

The easiest way to find its IP is your router's client list; look for the
hostname `alarm`. `ping alarm` and `ping alarm.local` will not work, since the
image ships no mDNS responder. To scan instead, first find your subnet:

```sh
ip route
```

The default route line names it, e.g. `192.168.1.0/24`. Scan it:

```sh
nmap -sn 192.168.1.0/24
```

Or wait a minute and check the neighbor table:

```sh
ip neigh
```

Either way, a Raspberry Pi is recognizable by its MAC prefix: `b8:27:eb`,
`dc:a6:32`, `e4:5f:01`, `d8:3a:dd`, `2c:cf:67` or `88:a2:9e`.

### 7. SSH in

```sh
ssh alarm@<ip>
```

The first connection prints "The authenticity of host ... can't be
established" and asks "Are you sure you want to continue connecting
(yes/no/[fingerprint])?". That is normal for any new host; type `yes`. You land
in a shell as `alarm`, and `sudo` works without a password.

### 8. Update later

On the Pi:

```sh
sudo bootc upgrade
sudo reboot
```

The upgrade pulls the `:bootstrap` tag from ghcr. The package is public, so
anonymous pulls work. Every push to main that touches the image paths rebuilds
and pushes; the Pi picks it up on the next upgrade, and the reboot switches
into the new deployment.

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

The kernel is `linux-rpi` (4K pages), but not the build Arch Linux ARM
ships. ALARM follows the Pi Foundation's LTS branch; this repo builds the
same PKGBUILD against a newer `raspberrypi/linux` branch.

## Kernel

`.github/workflows/build-kernel.yml` takes a branch name (default
`rpi-7.2.y`), looks up its tip, runs ALARM's `linux-rpi` PKGBUILD against it
on the arm64 runner, and publishes the package as a GitHub release tagged
`kernel-<version>-<pkgrel>`. It then dispatches the image build, which
downloads the newest `kernel-*` release into `10-kitten-rpi-arch/kernel-pkg/`
and installs it over the pacstrapped kernel. The compile takes about 25
minutes; the image build runs on every push and does not repeat it.

The PKGBUILD and its support files under `10-kitten-rpi-arch/kernel/` are
ALARM's, copied as they are. Only `_commit`, `pkgver` and `pkgrel` are
rewritten at build time. To pick a different branch or force a rebuild:

```sh
gh workflow run build-kernel.yml -f branch=rpi-6.18.y -f pkgrel=2
```

To build an image with ALARM's own kernel instead:

```sh
gh workflow run build-arch-rpi.yml -f kernel_tag=none
```

Check what a running Pi has with `uname -r`; the pkgrel shows up as the
`-1-rpi` suffix.

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
