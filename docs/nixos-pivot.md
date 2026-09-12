# The NixOS pivot

Started 2026-09-13, after two flashed cards that passed every offline check and
still never mounted root.

The goal has not changed: a Raspberry Pi 5 that boots from the native Pi
firmware, with `bootc upgrade` and rollback. What changed is the userland. Arch
ARM is out, NixOS is in.

## Why

Not because Arch was the cause. That is still unproven, and the card reader
remains a live suspect (see the bottom of this file). The argument for NixOS is
that the parts of this project that keep going wrong are the parts where the
image's contents are assembled imperatively and then checked after the fact: the
kernel and its modules, the initramfs and what got forced into it, the DTBs and
which of them the firmware actually reads. In a Nix expression those are values,
and a wrong one is a build failure rather than a silent omission that surfaces
as a Pi that sits on a black screen.

## Findings

### The Pi 5's SD controller is `sdhci-brcmstb`, not `sdhci-of-dwcmshc`

This is the one that matters most, because every image this project produced
before today force-loaded the wrong driver into its initramfs.

In `bcm2712.dtsi` and `bcm2712-rpi-5-b.dts`:

```dts
sdio1: mmc@fff000 {            /* SDIO1 is used to drive the SD card */
    compatible = "brcm,bcm2712-sdhci", "brcm,sdhci-brcmstb";
};
```

and `bcm2712-rpi.dtsi` aliases `mmc0 = &sdio1`.

`brcm,bcm2712-sdhci` is claimed by `drivers/mmc/host/sdhci-brcmstb.c`, config
symbol `CONFIG_MMC_SDHCI_BRCMSTB`, module `sdhci-brcmstb`.

`raspberrypi,rp1-dwcmshc` is a different controller. It is RP1's own
(`rp1_mmc0`/`rp1_mmc1` in `rp1.dtsi`) and both nodes are `status = "disabled"`
on a Pi 5 B. Mainline's `sdhci-of-dwcmshc.c` does not even carry that
compatible string; it exists only in the Raspberry Pi fork.

`Containerfile.base` has carried `force_drivers+=" sdhci-of-dwcmshc "` since
commit 3827eb6, and the dracut step asserts that string is present in the
initramfs. The assertion passed every time. It was asserting the wrong thing.

Note that `CONFIG_MMC_SDHCI_BRCMSTB` does not appear in `bcm2712_defconfig`,
which is easy to misread as absent. Its Kconfig stanza is
`default ARCH_BRCMSTB || BMIPS_GENERIC`, and `CONFIG_ARCH_BRCMSTB=y` is set, so
it is built in and `savedefconfig` drops the line.

### `bcm2712_defconfig` is a 16K-page kernel

`arch/arm64/configs/bcm2712_defconfig` line 50, in both `rpi-6.12.y` and
`rpi-6.18.y`:

```
CONFIG_ARM64_16K_PAGES=y
```

Mainline's arm64 `defconfig` sets no page-size symbol, so it takes the Kconfig
default of 4K. That is why the Pi firmware loads `kernel_2712.img` in
preference to `kernel8.img` on a Pi 5: the former is the 16K build.

The practical cost of 16K is that jemalloc compiled for 4K aborts at runtime,
which takes a chunk of the package set with it. `nvmd/nixos-raspberrypi` carries
an overlay for exactly this (`jemalloc.override { pageSizeKiB = 16; }`) and it
forces a large rebuild. Nothing equivalent exists in nixpkgs or nixos-hardware.

### There is no `start5.elf`

The Pi 5's second-stage firmware lives in the SPI EEPROM. `raspberrypi/firmware`
ships `start.elf`, `start4.elf`, `start4cd/db/x.elf` and `bootcode.bin`, and
none of them are used on a Pi 5. The EEPROM bootloader reads `config.txt` off
the FAT partition and loads the kernel, DTB and initramfs itself.

`seed-firmware.sh:47` globs `start*.elf` and hard-fails on an empty glob. That
is harmless (the files exist in the package, they are just inert on a Pi 5) but
it is worth knowing that their presence proves nothing about whether a Pi 5 can
boot the card.

### `linux_rpi5` does not exist in nixpkgs

Only `linux_rpi1` through `linux_rpi4`, and those now emit a deprecation warning
pointing at nixos-hardware. `pkgs/os-specific/linux/kernel/linux-rpi.nix` has a
`defconfig` map with keys `"1"` through `"4"` and no `"5"`.

Three places do have a Pi 5 kernel:

- `nixos-hardware`, `raspberry-pi/common/kernel.nix`, a fork of the nixpkgs
  expression with `"5" = "bcm2712_defconfig"` added. 6.18.39 at tag
  `stable_20260724`. Not built by Hydra, not in any binary cache, and the repo's
  CI does not push to cachix. Building it under emulation is hours.
- `nvmd/nixos-raspberrypi`, which provides real `linux_rpi5` /
  `linuxPackages_rpi5` attributes and a populated cachix
  (`nixos-raspberrypi.cachix.org`). It is also the only project that implements
  a firmware-level direct-boot path for NixOS on a Pi 5.
- Mainline. BCM2712 has been supported since 6.8, `linuxPackages_latest` is
  prebuilt for aarch64, and nixos-hardware's Pi 5 module has an explicit
  mainline branch (it loads `rp1_pci` and `pinctrl-rp1` when
  `kernel.pname == "linux"`). 4K pages. This is what the first iteration uses,
  because it costs a download instead of a day.

### nixos-hardware's firmware module overrides `populateFirmwareCommands`

`raspberry-pi/common/firmware.nix` contains:

```nix
sdImage.populateFirmwareCommands = lib.mkForce "${installScript} ./firmware\n";
```

unconditionally, whenever an `sdImage` module is in scope. `mkForce` is priority
50 and an ordinary definition is priority 100, so a plainly-written
`populateFirmwareCommands` is discarded outright rather than merged.

Their script stages `bootcode.bin`, `start*.elf`, `fixup*.dat`, every DTB in the
firmware package and the overlays directory. **It never copies a kernel**,
because it assumes U-Boot will fetch one over extlinux.

The first SD image built here had a FAT partition with 47 files on it and no
`Image`, no `initrd` and no `cmdline.txt`. It would have booted to nothing. The
fix is to give our own definition `mkForce` as well, which drops both to the
same priority so the `types.lines` merge applies and ours runs last.

### `hardware.enableRedistributableFirmware` costs 1.95 GB

On aarch64 it pulls `linux-firmware`, 1,947,683,840 bytes uncompressed, almost
entirely for hardware a Pi does not have. The Pi's own wifi and bluetooth blobs
are not in it at all. They come from `raspberrypiWirelessFirmware`, 3.65 MB,
which is where `brcmfmac43455-sdio.raspberrypi,5-model-b.{bin,txt,clm_blob}`
actually live. Upstream `linux-firmware` has the `,3-model-b-plus` and
`,4-model-b` variants and nothing for the Pi 5.

Setting `hardware.enableRedistributableFirmware = lib.mkForce false` and adding
`hardware.firmware = [ pkgs.raspberrypiWirelessFirmware ]` is not a trade of
completeness for size. It is strictly more correct and 1.9 GB smaller.

### A real top-level `/nix` does survive into an ostree commit, conditionally

This decides whether NixOS-in-bootc is possible at all, and it rests on code
rather than documentation.

`bootc/crates/ostree-ext/src/tar/write.rs` filters toplevel paths on import:

```rust
match part {
    "usr" => ret.push(part),
    "etc" => { ret.push("usr/etc"); }
    "var" => { ... }
    o if EXCLUDED_TOPLEVEL_PATHS.contains(&o) => { excluded = true; ret.push(part) }
    _ if config.allow_nonusr => ret.push(part),
    _ => { return Ok(NormalizedPathResult::Filtered(part)); }
}
```

So `/nix` is silently dropped unless `allow_nonusr`. In
`crates/ostree-ext/src/container/store.rs` (verified at tag v1.16.12):

```rust
let root_is_transient = if let Some(base) = base_commit.as_ref() {
    ...overlayfs_root_enabled(rootf)?
} else {
    // For generic images we assume they're using composefs
    true
};
```

`base_commit` is `None` for an image with no `ostree.diffid` label, which is
every image built `FROM scratch` with podman or buildah. So a `FROM scratch`
image keeps its `/nix`, and an image derived `FROM` an existing bootc base does
not, because Fedora bases do not set `[root] transient = true`.

**Build from scratch.** This is a one-line comment in bootc's source, not a
documented contract, and it is worth an assertion in CI.

`bootc container lint` has no lint against a populated `/nix`. Its fatal checks
are `var-run`, `etc-usretc`, `bootc-kargs`, `kernel` (exactly one
`/usr/lib/modules/$kver`), `utf8`, `api-base-directories` and `baseimage-root`.

### What NixOS has to stop doing on a read-only root

With `[composefs] enabled = yes` the whole deployment root is one read-only
image, `/usr` included. The writes NixOS makes outside `/etc` and `/var`:

- `system.activationScripts.binsh` creates `/bin/sh`. No option disables it;
  `lib.mkForce ""` is the in-tree idiom (`tasks/filesystems/envfs.nix` does it).
- `system.activationScripts.usrbinenv` creates `/usr/bin/env`. Setting
  `environment.usrbinenv = null` does **not** make it a no-op. It switches the
  script to a branch that runs `rm -f /usr/bin/env` and then tries to
  `rmdir /usr`. Use `lib.mkForce ""` here too.
- The nix-daemon's activation writes `/nix/var/nix/profiles/system`.
  `nix.enable = false` removes it, which is right for a machine whose updates
  arrive as container images.
- `stage-2-init.sh` does `mount -n -o remount,rw none /` and some `install -d`
  calls, all of which are skipped when `IN_NIXOS_SYSTEMD_STAGE1=true`, and its
  `chown`/`chmod` of `/nix/store` already use `-f` for read-only stores.

Do not enable `system.etc.overlay.enable`. It mounts an EROFS+overlay stack on
`/etc` from the initrd, which would sit straight on top of the `/etc` ostree
three-way merged at deploy time and hide it.

### The init handoff

`systemctl switch-root` reads `init=` off the kernel command line when no
argument is given, so a stock dracut initrd honours it. PID 1 then requires an
`os-release` in the target (`/etc/os-release` or `/usr/lib/os-release`) or it
refuses with "does not seem to be an OS tree".

Which `init=` to use depends on a detail that is easy to get backwards.
`nixos/modules/system/activation/top-level.nix`:

- with `boot.initrd.systemd.enable = false`, `$toplevel/init` **is** the stage-2
  script;
- with it `true`, `$toplevel/init` is a copy of the systemd binary and stage-2
  moves to `$toplevel/prepare-root`.

In the second case NixOS's own initrd compensates:
`initrd-find-nixos-closure` parses `init=` to locate the closure, and
`initrd-nixos-activation` runs `chroot /sysroot "$closure/prepare-root"` before
`initrd-switch-root`. That machinery already exists and is tested
(`nixos/tests/systemd-initrd-non-nixos.nix`), so the cheapest design is to keep
NixOS's initrd and insert exactly one unit into it: `ostree-prepare-root
/sysroot`, ordered after `sysroot.mount` and before both
`initrd-root-fs.target` and `initrd-find-nixos-closure.service`.

`ostree-prepare-root` reads the copy of `prepare-root.conf` that is inside the
initramfs, not the one in `/usr`. Shipping it in only one place leaves the
settings inert.

nixpkgs has all the pieces: `ostree` 2026.2 ships
`lib/ostree/ostree-prepare-root` and the full set of units under
`lib/systemd/system`, and `bootc` 1.6.0, `composefs` and `dracut` are packaged
for aarch64. The vendored cross-compiled bootc builder container is no longer
needed.

Also useful: nixpkgs patches systemd's `CONF_PATHS` to *add* the store prefix
rather than replace the FHS paths, so `/usr/lib/systemd/system` stays in the
search path and ostree's units should be found. Verified by reading the patch,
not at runtime.

## Build environment

There is no Nix on this host and none is needed. `nix/nixrun.sh` runs everything
in `docker.io/nixos/nix` with the store in a podman volume.

aarch64 derivations build through the host's `binfmt_misc` registration. That
registration carries the `F` (fix-binary) flag, which means the kernel holds the
interpreter open at registration time, so it resolves inside any mount
namespace, including nix's build sandbox and any container. Proven by building
an aarch64 derivation whose only job is to run `uname -m`.

Most of a NixOS closure is substituted from cache.nixos.org rather than built,
so emulation cost is confined to the handful of derivations that are unique to
this configuration.

## Still open

**Nothing has booted yet.** Two Arch cards, 22 of 22 offline checks passing each
time, and neither mounted root. The wrong SD driver is a good candidate for why,
but it is a candidate, not a conclusion.

**The reader is still a suspect.** During the AlmaLinux control flash on
2026-09-13 the card dropped off the bus mid-write, at roughly 6.05 GB of 6.15:

```
02:20:17 usb 1-3: USB disconnect, device number 20
02:20:18 usb 1-3: new high-speed USB device number 21 using xhci_hcd
02:20:20 sd 6:0:0:0: [sdb] 124735488 512-byte logical blocks
02:20:43 usb 1-3: USB disconnect, device number 21
```

That is the fourth recorded drop. The device is `14cd:1212`, a Super Top microSD
reader on USB 2.0. Any conclusion drawn from a card that fails to boot has to
survive the possibility that the bytes never landed.
