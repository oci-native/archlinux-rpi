# Disk image and provisioning

Owner: `diskimage` workstream. This document was cut short by a team collapse
(see HANDOFF at the end) partway through part 3; parts 1, 2, and most of 4 and
5 are solid and evidence-backed. Read the HANDOFF section before acting on
anything here.

## 1. How AlmaLinux actually builds their release images

Traced end to end from `.github/workflows/build.yml`,
`.github/actions/shared-steps/action.yml`, `bib-config.toml`, `Makefile`, and
confirmed against real release assets with `gh api
repos/AlmaLinux/bootc-images-rpi/releases`.

The pipeline is not "bootc-image-builder produces a bootable Pi image." It's
five distinct stages, only one of which is bootc-image-builder:

1. `make image` builds the ordinary bootc container
   (`quay.io/almalinuxorg/almalinux-bootc-rpi:10`) from `10-rpi/Containerfile`.
   Standard bootc container build, nothing Pi-specific in the mechanism, but
   the image itself ships the VideoCore firmware blobs and a placeholder
   `config.txt` under `/usr/lib/ostree-boot/` (that path is the confirmed
   source; see step 4).
2. `make rechunk` runs `bootc-base-imagectl rechunk` for OCI layer chunking.
   Irrelevant to the firmware question.
3. A separate "bootstrap image" (`10-rpi/bootstrap-image/Dockerfile`) layers
   `cloud-init` and `cloud-utils-growpart` on top of the built image, plus a
   `10-bootc-growpart.cfg` cloud-init drop-in (`growpart: devices: [/sysroot]`)
   and a `user-data`/`README.txt` pair. This bootstrap image is used only as
   the chroot target for step 4/5's post-processing; it is not what ships.
4. `bootc-image-builder` runs against the bootstrap image with
   `bib-config.toml`, type `raw`, `--rootfs xfs`. `bib-config.toml` declares
   three explicit partitions via `customizations.disk.partitions`: a vfat
   partition labelled `CIDATA` at `/boot/efi` (min 1 GiB), an xfs partition
   at `/boot` (min 1 GiB), and an xfs partition at `/` (min 4 GiB). This
   is **not** bootc's own default partitioning; it's bib's custom-partition
   feature, used specifically to get a third partition bootc's own installer
   doesn't produce (see part 3). The output is `output/image/disk.raw`.
5. Post-processing, entirely shell script in `shared-steps/action.yml`, no
   bootc-image-builder involved:
   - loop-mounts `disk.raw`, `fatlabel`s partition 1 `CIDATA`, mounts it,
     and copies cloud-init's `user-data`/`README.txt` onto it (from the host).
   - runs the **bootstrap image** container with `/sysroot` bind-mounted to
     partition 3 and `/boot` bind-mounted to partition 2, and inside that
     chroot: `cp -a --no-preserve=links /usr/lib/ostree-boot/* /tmp/` where
     `/tmp` is bind-mounted to the host's mount of partition 1. **This is the
     line that seeds the firmware partition.** `/usr/lib/ostree-boot/` is
     the confirmed source of the VideoCore blobs and the placeholder
     `config.txt` shipped by the container image itself (this matches
     `config.txt` in the repo root, which is a bare `[pi3]`/`[pi4]`/`[all]`
     stub, not the sync hook's generated one).
   - runs `rpi-bootc-bootloader version && rpi-bootc-bootloader sync` in that
     same chroot, **manually**, once, right after install. This confirms the
     `ostree-finalize-staged.service` drop-in does **not** fire on the initial
     `bootc install`; AlmaLinux has to invoke `sync` explicitly as a
     provisioning step. First-deploy sync is not automatic.
   - copies `disk.raw` to a second file, converts it to a hybrid MBR via
     `sgdisk --typecode="1:0700"` and `sgdisk -m 1:2:3`, then
     `sfdisk --part-type ... 1 e` (MBR type 0x0e, FAT16 LBA), producing the
     "fat" variant. The pure-GPT file is the "gpt" variant. Both are
     released; confirmed via `gh api` against release `2026-03-15-1`:
     `image-almalinux-bootc-rpi-{fat,gpt}-{9,10,10-kitten}-...-arm64.raw.xz`,
     sizes matching pairwise (the hybrid-MBR step changes only a few bytes
     of partition-table metadata). README.md: "GPT image if your PI supports
     it (RPI5, RPI4). FAT image otherwise," confirming Pi 5's firmware reads
     GPT natively and the hybrid MBR exists only for older boot ROM/EEPROM
     compatibility.

**Verdict on whether to copy this**: the mechanism (seed firmware from a
build-time path, then run `sync` once, manually, as a provisioning step) is
correct and is the only way found anywhere, in this repo or AlmaLinux's, to
get VideoCore firmware onto the card. It is not something bootc or
bootc-image-builder does for you regardless of which tool orchestrates
partitioning; this matches and confirms the team brief's known-gap #3 and the
README's own admission that "bootc-image-builder alone isn't enough."

What should **not** be copied: the three-partition scheme with a separate
xfs `/boot`, driven by hand-written `bib-config.toml` customizations. Part 3
below found (partially; see HANDOFF) evidence that bootc's own `to-disk`
baseline installer already produces a usable two-partition layout for our
case, without bootc-image-builder at all, sidestepping the cross-arch
bwrap/qemu problem more thoroughly than AlmaLinux's own pipeline does. This
was not fully validated end-to-end before the wrap-up; treat it as a strong
lead, not a settled decision.

## 2. Partition layout

### Sync hook device derivation: verified safe across SD/NVMe/USB, no patch needed

The task brief asked me to check whether the sync hook survives NVMe vs SD vs
USB device naming and to specify a patch if not. **Checked directly, no
patch is needed.** The hook's derivation is:

```bash
RAW_DEV=$(mount | awk '$3 == "/sysroot" {print $1}')
MNTDEV=$(echo "$RAW_DEV" | sed -E 's/[0-9]+$/1/')
```

Tested the regex directly against all three naming schemes:

```
/dev/mmcblk0p2  -> /dev/mmcblk0p1
/dev/nvme0n1p2  -> /dev/nvme0n1p1
/dev/nvme0n1p3  -> /dev/nvme0n1p1
/dev/sda2       -> /dev/sda1
/dev/sda1       -> /dev/sda1
```

`[0-9]+$` matches only the trailing digit run at the absolute end of the
string, so it isolates the partition number regardless of whether the
separator before it is `p` (mmcblk/nvme) or nothing (sda), and regardless of
how many digits precede that separator (`nvme0n1` doesn't get touched). This
is a correct, naming-scheme-agnostic derivation as written. **The team
brief's premise that this might need a patch is wrong**, symmetrical to the
kernel-layout.md correction about the pacman hook that also turned out not
to exist. No hook patch is needed for this workstream.

Caveat, not yet checked: what happens when `/sysroot`'s device is itself
partition 1 (a single-partition disk, e.g. someone images just a root fs with
no firmware partition at all). `sed` would then substitute the trailing `1`
with `1`, a no-op, and the hook would try to mount the sysroot device itself
as the firmware partition. This shouldn't arise given the layout below (root
is always partition 2), but it means the two-partition layout is not just a
sizing convenience, it's load-bearing for this substitution to make sense.

### Filesystem and write-reduction: partially decided, not finalized

Leaning ext4 for root, not xfs, not btrfs:

- Matches kernel-layout.md's dracut module trim (already dropped the `btrfs`
  dracut module on the assumption of no btrfs root; picking btrfs here would
  force adding it back).
- bootc's own baseline installer (`crates/lib/src/install/baseline.rs`,
  confirmed by reading it directly, see part 3) unconditionally adds
  `-O verity` to `mkfs.ext4` for the root filesystem when ext4 is chosen, a
  free integrity property xfs/btrfs don't get in that code path.
- xfs cannot shrink; irrelevant here since we only ever grow, but it's one
  fewer reason to prefer it over ext4 for a small appliance root.

This was a leaning, not a checked decision, when the team collapsed.

Write-reduction measures proposed, none implemented or tested yet:

- Kernel cmdline: `rootflags=noatime`, coordinating with kernel-layout.md's
  open `kargs.d` item (already proposes `rootwait console=serial0,115200`;
  `noatime` needs to be added there, not to a separate mechanism, since
  ostree/bootc systems don't carry a conventional `/etc/fstab` root entry).
- `journald.conf.d` drop-in: `Storage=persistent` (deliberately not
  `volatile`; we explicitly want boot logs to survive a crash during Pi
  bring-up per part 5), but bounded: `SystemMaxUse=100M`, `RuntimeMaxUse=50M`,
  `Compress=yes`.
- `zram-generator.conf`: `zram0` sized `min(ram/2, 2048)`, zstd, matching the
  pattern already used in `Containerfile.base` on the x86 image. No disk
  swapfile at all; a swapfile on flash under memory pressure would be one of
  the worst write-amplification cases available to us and the Pi 5's low-RAM
  variants (2 GB/4 GB) are exactly the ones that would hit it.
- `fstrim.timer` enabled (already the pattern in `Containerfile.base`).
  Effectiveness on SD/eMMC varies by card controller; harmless to enable
  regardless, and NVMe on Pi 5 (M.2 HAT) benefits reliably.
- `coredump.conf.d`: `Storage=none`, to stop a crashing podman container from
  writing large core files to flash by default.

None of this was written into a Containerfile drop-in; it's a proposal for
whoever owns that file next.

## 3. Build path — UNFINISHED, read the HANDOFF

This is the part that was cut off mid-investigation. What's confirmed, from
reading `bootc`'s actual source (`crates/lib/src/install/baseline.rs` and
`crates/lib/src/bootloader.rs`, both fetched and read via `gh api` against
`bootc-dev/bootc@main`, not guessed):

- `bootc install to-disk`'s baseline installer creates an EFI System
  Partition **unconditionally on aarch64**, regardless of `--bootloader`
  value: `pub(crate) const ARCH_USES_EFI: bool = cfg!(any(target_arch =
  "x86_64", target_arch = "aarch64"));`, and the ESP-creation branch in
  `install_create_rootfs()` checks only `ARCH_USES_EFI`, never the bootloader
  option. So `bootc install to-disk --bootloader none` on aarch64 still
  produces a vfat ESP, sized a hardcoded 512 MiB (`EFIPN_SIZE_MB`), as
  partition 1, formatted `mkfs.fat -n EFI-SYSTEM`.
- The baseline installer only creates a **separate** `/boot` partition when
  `block_setup.requires_bootpart()`, which is true only for
  `BlockSetup::Tpm2Luks`, never for `BlockSetup::Direct`. With no LUKS (our
  settled decision), `/boot` is just a directory inside the root filesystem,
  not its own partition.
- Net result: `bootc install to-disk --via-loopback ... --filesystem ext4
  --wipe --bootloader none` (no `--composefs-backend`, matching the ostree
  backend decision) should produce a **two-partition** layout: p1 = vfat ESP
  (usable as the firmware partition), p2 = ext4 root (containing `/boot` as a
  plain directory). This is fewer partitions than AlmaLinux's three, and
  **was reasoned through but not run**. I have not actually invoked this
  command against any built container image; no such image exists in this
  repo yet (checked: no Containerfile anywhere under
  `/var/home/bupd/code/rpi` as of this writing), and this session has no
  root/sudo (`sudo -n true` failed, not in the `disk` group, `/dev/loop-control`
  is `root:disk 0660`), so loop-device mounting could not be tested even with
  a stand-in image.
- Consequence I had NOT worked through when cut off: with no separate `/boot`
  partition, the sync hook's runtime assumption that `/boot/loader/entries/`
  is readable and that `/sysroot` is a distinct mount both still hold (ostree
  always keeps `/boot` as a shared top-level directory on the physical
  sysroot partition, bind-mounted into each deployment's view; this is
  standard ostree behavior, not something specific to our layout), but the
  **offline provisioning script** needs an extra step AlmaLinux's script
  doesn't need: since our "boot partition" is a directory inside the root
  partition rather than a separate device, seeding/syncing before first boot
  requires mounting p2 at a scratch path (call it `/sysroot`) and then
  **bind-mounting `<scratch>/boot` onto `/boot`** inside the container used
  to run `rpi-bootc-bootloader sync`, so that `/boot/loader/entries/...`
  resolves correctly. AlmaLinux's script achieves the same thing for free by
  mounting their separate boot partition directly at `/boot`. This bind-mount
  step is easy to get wrong and was not written or tested.
- `bootc-dev/bootc#2111` (the cited cross-arch qemu-user bwrap issue): read
  the actual issue via `gh api repos/bootc-dev/bootc/issues/2111`. The
  failure is specifically `bwrap: Creating new namespace failed: Invalid
  argument` inside `bootc install to-filesystem`'s **bootloader installation**
  step, when it shells out to `bootupctl backend install` via `bwrap`, and
  that call only happens for `Bootloader::Grub`/similar. Confirmed by reading
  `install.rs`: the `Bootloader::None` match arm is
  `tracing::debug!("Skip bootloader installation due set to None")`, no
  bootupd, no bwrap call at all. **This means our `--bootloader none` path
  should not hit this specific bug**, whether we use plain `bootc install` or
  bootc-image-builder. This narrows, but does not eliminate, the team
  brief's blanket "bootc-image-builder cross-arch has qemu-user problems"
  concern: it rules out this specific named issue for us, it says nothing
  about other cross-arch bib/osbuild failure modes, which I did not have
  time to survey.
- The 512 MiB hardcoded ESP size was not checked against actual needs (16
  VideoCore blobs plus two slots of `bootc/entries/ostree-N/` each holding
  vmlinuz + initramfs.img + ~26 dtbs + ~386 overlays + rpi-config.txt).
  Rough math suggests low hundreds of MB per slot for kernel+initrd alone,
  which could plausibly get tight in 512 MiB for two slots plus firmware.
  Flagged, not measured against a real built initramfs.

**Nothing in part 3 was executed against a real disk image or loop device
this session.** The one thing that was written and tested is
`scripts/rpi-disk-image/seed-firmware.sh`, which only does file copying
(no partitioning, no mounting) and was verified with plain directories
standing in for a mounted partition: seeds VideoCore blobs idempotently,
writes a default `config-bootc-common.txt` only if absent, ran twice to
confirm idempotency, passes `shellcheck` clean. It does not yet cover the
`config-bootc-common.txt` UART settings being validated against real
hardware, and it takes the firmware source directory as a parameter rather
than assuming `/usr/lib/raspberrypi/boot` (that path itself depends on the
Containerfile placing things there, which doesn't exist yet either).

A second script, `scripts/rpi-disk-image/build-disk-image.sh`, meant to
orchestrate `bootc install to-disk` + loop mount + bind-mount trick +
`seed-firmware.sh` + `rpi-bootc-bootloader sync`, **was never written**. This
is the single biggest gap in the deliverable.

## 4. First boot design

Read AlmaLinux's `10-bootc-growpart.cfg` and `user-data`/`README.txt`. Their
approach is cloud-init (NoCloud datasource off the CIDATA partition) for
three things: hostname, an `almalinux` user with an SSH-authorized-keys slot
and passwordless sudo, and growpart targeting `/sysroot`.

Recommendation: skip cloud-init entirely, all three are simpler done with
plain systemd, and none of cloud-init's other features (network config,
package installs, arbitrary user scripts) are needed for an appliance image
that's supposed to be reproducible from the container build:

- **Root growth**: `systemd-repart`, not cloud-init's growpart module.
  A `/usr/lib/repart.d/50-root.conf` drop-in with `Type=root` and
  `GrowFileSystem=yes` grows the last (root) partition to fill the disk and
  triggers the matching filesystem resize (`resize2fs` for ext4), gated by
  `systemd-repart.service` which is idempotent (no-op once already grown).
  `Type=root` matches by the architecture's Discoverable Partition
  Specification GUID, which is exactly what `bootc install to-disk`'s
  baseline installer already stamps the root partition with (confirmed while
  reading `baseline.rs`: `rootpart_uuid =
  discoverable_partition_specification::this_arch_root()`). This was reasoned
  through from systemd's documented repart.d recipe for this exact use case,
  not tested against a real disk.
- **machine-id**: nothing to build. `Containerfile.base`'s existing pattern
  (`printf 'uninitialized\n' > /etc/machine-id`) is the documented systemd
  sentinel value; systemd itself, at early boot, replaces literal
  `uninitialized` with a freshly generated persistent ID and writes it back,
  independent of `systemd-firstboot.service` (which only handles
  locale/timezone/root-password prompts). No first-boot unit needed for this.
- **hostname**: propose a small first-boot oneshot unit
  (`ConditionPathExists=!/etc/hostname`, so it only runs once, no stamp file
  needed) that reads the `Serial` line from `/proc/cpuinfo` (real Pi hardware
  exposes a unique board serial there) and writes `rpi5-<last 4 hex chars>`
  to `/etc/hostname`, falling back to the first 8 chars of `/etc/machine-id`
  if `/proc/cpuinfo` has no Serial line (e.g. under QEMU). This matters
  concretely for us: two Pi 5 boards need to be distinguishable on the LAN
  without manual intervention. **Not written**, only designed.
- **SSH**: bake `authorized_keys` into the image at build time for a
  dedicated non-root user, exactly like `Containerfile.base`'s `bupd` user
  pattern (sysusers.d + tmpfiles.d + wheel + passwordless sudo), plus an
  sshd_config.d drop-in with `PasswordAuthentication no`,
  `KbdInteractiveAuthentication no`, `PermitRootLogin no`. This needs zero
  first-boot logic, the key ships in the image. This is a cross-workstream
  ask: the Containerfile doesn't exist in this repo yet, so I could not add
  it myself. For prototyping purposes I confirmed a real ed25519 public key
  is available on this host (`~/.ssh/id_rsa.pub` and an ed25519 key both
  present) that could stand in for "Prasanth's key" in a test build; did not
  fabricate one.
- Also propose masking `systemd-firstboot.service`, matching the x86 image,
  so a headless serial-only first boot never blocks on a prompt that has
  nowhere to render.

None of the first-boot unit files were actually written to this repo. This
section is a design, checked against systemd's documented behavior and the
existing x86 Containerfile's conventions, not implemented.

## 5. Hardware verification procedure (two Pi 5 boards on hand)

This section is a procedure for a human to run once a board is attached; per
house rules and the standing "read-only on any running Pi" instruction, none
of this was executed, and it must not be executed against `/dev/sdb` without
asking Prasanth at the moment of writing.

1. **Serial console first, before any SD card changes.** Wire a 3.3V
   USB-to-TTL adapter: adapter GND to Pi GND, adapter RX to Pi GPIO14 (TXD,
   physical pin 8), adapter TX to Pi GPIO15 (RXD, physical pin 10). Do not
   connect the adapter's 5V/3.3V power pin. On the build host:
   `picocom -b 115200 /dev/ttyUSB0` (or `minicom`). This must be live and
   capturing before the board is powered on, since first-boot failures are
   exactly the case we have no other visibility into.
2. **Write the image.** After `docker/../rpi.img` exists and part 3's build
   path is actually implemented and tested in loopback first: confirm the
   target device with the human present (`lsblk`), then
   `sudo dd if=rpi.img of=/dev/sdX bs=4M status=progress oflag=direct`,
   `sync`. Never assume `/dev/sdX`; re-derive it at the moment of writing.
3. **First boot.** Expect on serial: VideoCore firmware banner, then
   `config.txt`/`os_prefix` selection (nothing to see here normally),
   kernel decompression, then a normal Arch/systemd boot log ending in a
   login prompt on the serial console (the `console=serial0,115200` karg
   should give us a `serial-getty@` automatically, no explicit enablement
   expected to be needed, not yet confirmed). Confirm hostname is the
   expected `rpi5-<suffix>` and differs between the two boards.
4. **Confirm boot chain matches design.** Once booted: `bootc status`,
   check `/etc/machine-id` is not literally `uninitialized`, check root
   partition has actually grown (`lsblk`, `df -h /`), check
   `journalctl -b` for the `rpi-bootc-bootloader` sync run and for any dracut
   module load failures.
5. **SSH in.** From the build host, as the dedicated user, confirm key-only
   auth (`ssh -o PreferredAuthentications=publickey ...`), confirm password
   auth is refused.
6. **bootc upgrade/rollback smoke test.** `bootc switch`/`bootc upgrade` to a
   second build, reboot, confirm the sync hook re-ran
   (`bootc/entries/ostree-2/` populated on the firmware partition,
   `os_prefix` flipped), confirm `bootc rollback` recovers the first slot.
7. **Two-board plan**, per STATUS.md's stated rationale: board A gets a
   fresh install from a clean card; board B repeats the same written
   instructions independently (clean-room check that the procedure itself is
   complete and not tribal-knowledge-dependent). Compare results.
8. **GPIO6/tryboot physical rollback**: no button wired yet, no watchdog
   behavior observed yet. Treat as untested; the `vcmailbox` calls
   (`raspberrypi-utils` provides this per kernel-layout.md) can be exercised
   by hand over SSH before wiring a physical button.

## Open blockers, all unconfirmed/unresolved at handoff

- **No Containerfile exists in this repo yet.** Everything in parts 3 and 4
  that depends on the container image's exact contents (firmware blob path,
  authorized_keys, dracut config) is a request to whoever builds it next,
  not something I could test against a real image.
- **Cross-workstream inconsistency, found late, since resolved**:
  `docs/rpi-bootc-bootloader.arch-proposed` (almaport's vendored, patched
  hook) originally set `DTB_SRC` to a fixed path, `/usr/lib/raspberrypi/boot`
  (package-level, not versioned with the kernel). `docs/kernel-layout.md`
  (kernellayout's decision #3, explicitly marked as superseding earlier
  assumptions) instead recommended `$BOOTDIR/dtbs`, i.e.
  `/usr/lib/modules/$kver/dtbs/`, to keep dtbs versioned with the kernel
  through the ostree commit and avoid drift on upgrade. Resolved in favor of
  `$BOOTDIR/dtbs`: dtbs are `linux-rpi` build output tied to one exact
  kernel build, and the hook already computes a per-deployment,
  per-kernel-version `BOOTDIR` for `rpi-config.txt`, so reusing it removes a
  second path to keep in sync by hand. `/usr/lib/raspberrypi/boot` still
  exists as a path, it's just reserved for `raspberrypi-bootloader`'s
  VideoCore blobs (this doc's `seed-firmware.sh` target), which are
  package-level and not read by this hook at all. `port-spec.md` D.1 and
  `rpi-bootc-bootloader.arch-proposed` are both updated to match.
- **512 MiB firmware/ESP partition size is unverified** against the actual
  size of two slots of `bootc/entries/ostree-N/` content. If it's too small,
  the fallback is bootc-image-builder with a custom
  `customizations.disk.partitions` size (or a fully manual
  `sfdisk`+`bootc install to-filesystem` pipeline), not `bootc install
  to-disk`, which has no CLI flag to change ESP size.
- **No root/sudo in this session.** `/dev/loop-control` is `root:disk`, this
  session's user isn't in `disk`, and `sudo -n true` fails. Nothing involving
  actual loopback partitioning, mounting, or running `bootc install` was
  executable here, independent of whether a container image existed.

## HANDOFF

**Done, confirmed, safe to build on:**

- Part 1 (AlmaLinux's real mechanism) is complete and precise: five stages,
  the firmware seed step is `cp -a /usr/lib/ostree-boot/* -> CIDATA
  partition` plus a manual `rpi-bootc-bootloader sync`, both post-processing,
  neither from bootc-image-builder itself. Verdict given: don't copy the
  three-partition bib-config.toml scheme, do copy the manual-sync pattern.
- Part 2's device-naming question is fully answered and tested: the sync
  hook's `sed`-based derivation is correct for mmcblk/nvme/sda as written, no
  patch needed. This closes out one of the five numbered asks completely.
- `scripts/rpi-disk-image/seed-firmware.sh` is written, shellcheck-clean, and
  tested (idempotency confirmed with fake blob files in plain directories).

**Half-done, exactly where I stopped:**

- Part 3 (build path): I had just finished reading bootc's actual Rust
  source (`baseline.rs`, `bootloader.rs`, `install.rs`) confirming that
  `bootc install to-disk --bootloader none` gives a free 2-partition layout
  (ESP + root, no separate /boot) on aarch64 without needing
  bootc-image-builder at all, and that the cited cross-arch bwrap bug
  (`bootc-dev/bootc#2111`) doesn't fire when `--bootloader none` since it
  skips bootupd entirely. I had reasoned through, but not written or tested,
  the extra bind-mount step (`<sysroot>/boot` onto `/boot`) that our
  2-partition layout needs during offline provisioning, which AlmaLinux's
  3-partition layout doesn't need. I was about to write
  `scripts/rpi-disk-image/build-disk-image.sh` to orchestrate this when the
  team collapse notice arrived. That script does not exist.
- Part 4 (first boot): fully designed (systemd-repart for growth, sentinel
  machine-id needs nothing, hostname-from-cpuinfo-serial oneshot, baked-in
  SSH key), none of it written as actual unit files or Containerfile
  snippets.
- Part 5 (verification procedure): written as a procedure, not executed
  (correctly, since no hardware is attached and this session has no
  privilege to do the disk-writing steps anyway).

**What I would do next, in order:**

1. ~~Resolve the DTB_SRC inconsistency between almaport's hook and
   kernellayout's decision~~ — done, see the blockers section above:
   `$BOOTDIR/dtbs` wins.
2. Once a Containerfile exists, get real root/sudo (or hand this to someone
   who has it) and actually run `bootc install to-disk --via-loopback
   --filesystem ext4 --wipe --bootloader none` against it, to confirm the
   2-partition layout assumption for real rather than from source-reading
   alone.
3. Write `build-disk-image.sh`: loop-mount, mount p2 at a scratch root,
   bind-mount `<scratch>/boot` onto `/boot`, run `seed-firmware.sh` against
   p1, run `rpi-bootc-bootloader sync` inside a privileged container with
   those mounts, unmount, `losetup -d`.
4. Measure actual `bootc/entries/ostree-N/` size against the 512 MiB ESP
   before trusting it fits two slots.
5. Only then move to part 4's unit files and part 5's real hardware pass.

**The trap for the next person**: don't assume the 2-partition
`bootc install to-disk` layout is settled. It's a strong, source-verified
lead, not a tested fact. If it turns out `bootc install to-disk` behaves
differently in practice than the source suggests (untested interactions
between `--bootloader none` and the ostree/ostree-finalize-staged path are
exactly the kind of thing that looks fine in source and isn't), the fallback
is bootc-image-builder with a custom `bib-config.toml`, matching AlmaLinux's
three-partition scheme, and part 2's filesystem/write-reduction reasoning
still applies either way, but part 3's script would need a rewrite, not just
a tweak.
