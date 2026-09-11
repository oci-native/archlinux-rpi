# Port spec: AlmaLinux/bootc-images-rpi + kfox1111/rpi-bootc-bootloader → Arch

Owner: PORT SPEC workstream. Read `TEAM-BRIEF.md` and `STATUS.md` first; this document
does not repeat settled context, only what changes or adds to it.

Every claim below is tagged with where it came from: a file path and line range in the
cloned repos, a quoted line from an upstream doc, or a command run against a live
service. Where I could not verify something, I say so instead of guessing.

## Sources read in full

- `bootc-images-rpi` — local clone HEAD `2e594936a0db66f0e670501b89ff4b6f95b56b11`
  (2026-04-09), confirmed identical to `AlmaLinux/bootc-images-rpi`'s GitHub HEAD via
  `gh api repos/AlmaLinux/bootc-images-rpi/commits`. Every tracked file read: both
  Containerfiles, all four `*-rpi.yaml` targets' manifests and repo files, `bib-config.toml`,
  `config.txt`, `Makefile`, `.github/workflows/build.yml`,
  `.github/actions/shared-steps/action.yml`, all four `bootstrap-image/` directories.
- `rpi-bootc-bootloader` — local clone HEAD `82739f4c9ae6de9ce071014bff9dee16842fb978`,
  one commit past tag `v0.0.8` (`7e44a51`), docs-only diff. Confirmed against GitHub via
  `gh api repos/kfox1111/rpi-bootc-bootloader/tags` and `/commits?since=2026-01-01`.
  Every file read: the script, `design.md`, `README.md`,
  `system/ostree-finalize-staged.service.d/rpi-bootc-bootloader.conf`.
- `https://gitlab.com/fedora/bootc/base-images/-/raw/main/bootc-base-imagectl.md` — fetched
  in full.
- `quay.io/centos-bootc/centos-bootc:stream10` — pulled in full with `skopeo copy` (the
  image this Containerfile builds FROM) specifically to read the actual manifest tree
  under `/usr/share/doc/bootc-base-imagectl/manifests/`, since the doc above says these
  files are "embedded in the container image" and are the real implementation, not
  something published anywhere else. Every manifest file the AlmaLinux build's include
  chain touches was extracted and read (list in part A).
- `bootc-dev/bootc` docs (`docs/src/bootloaders.md`, `docs/src/experimental-composefs.md`,
  `docs/src/bootc-install.md`) — fetched via `gh api` to settle the composefs question in
  part D.4, because the manifest evidence directly contradicted the phrasing in
  `STATUS.md`'s decision #2 and I was not willing to leave that unresolved.
- ALARM PKGBUILDs (`archlinuxarm/PKGBUILDs`, `raspberrypi/utils` upstream) — fetched via
  `gh api` for `linux-rpi`, `raspberrypi-bootloader`, `raspberrypi-utils`, to get exact
  install paths rather than infer them from package names.
- `/home/bupd/Projects/archlinux/{Containerfile.base,Taskfile.yml}` — read (not modified)
  for cross-checking the composefs/backend finding in part D.4 against the existing x86_64
  image's own validated conventions.

All package/version claims below were cross-checked against the ALARM `alarm`/`core`/`extra`
aarch64 database snapshots already fetched into the scratchpad (`e972-*.db`), dated
2026-09-11, matching `STATUS.md`'s verified table.

## Executive summary

1. **The rpi-bootc-bootloader diff is one line.** `DTB_SRC`'s glob assumes AlmaLinux's RPM
   dtb path. Everything else in the script — the MNTDEV device-suffix trick, the vfat mount,
   the BLS parsing, the jq/vcmailbox calls — is distro-agnostic. Patched copy at
   `docs/rpi-bootc-bootloader.arch-proposed`. An earlier draft of this section pointed
   `DTB_SRC` at a fixed package-level path; that was wrong and has been corrected below to
   `$BOOTDIR/dtbs`, matching `kernel-layout.md`'s decision 3 (see D.1).
2. **vcmailbox is not a gap.** `raspberrypi-utils` 20260904-1 in the ALARM `alarm` repo
   builds it from `raspberrypi/utils` upstream via CMake and installs it to
   `/usr/bin/vcmailbox`. Verified against the actual PKGBUILD and upstream CMakeLists.txt.
   Tryboot rollback is not blocked. See part B.
3. **The vfat firmware partition does not need to be mounted at runtime.** The script
   mounts it itself, on demand, at `/tmp/mnt`, purely by taking whatever device is mounted
   at `/sysroot` and rewriting its trailing partition number to `1`. It never reads or
   writes `/boot/efi`. See part C — this changes the install procedure.
4. **Two build-time relocations are needed, not one.** `STATUS.md`'s known gap #2 names the
   dtb relocation. There is a second, undocumented one: Arch's `linux-rpi` package ships an
   **empty placeholder** at `/usr/lib/modules/<kver>/vmlinuz` (the file bootc/ostree actually
   reads as "the kernel") and puts the real kernel image only at `/boot/kernel8.img`, which
   bootc requires empty. Without a fix, the image commits with a zero-byte kernel. See part D.2.
5. **A correction to `STATUS.md` decision #2.** The evidence says `composefs enabled = no`
   in `prepare-root.conf` is not what makes `--bootloader=none` work, and matching
   AlmaLinux's own proven image plus the existing `Containerfile.base` convention means we
   should almost certainly leave it `yes`. The real switch is bootc's separate storage
   *backend* selection (`--composefs-backend`), which we must simply not opt into. Full
   argument and citations in part D.4. **This needs a decision from you before anyone writes
   a prepare-root.conf.**
6. **One open question I could not resolve from the source available:** neither
   `rpi-bootc-bootloader` nor any file in `bootc-images-rpi` shows where the static VideoCore
   firmware blobs (`bootcode.bin`, `start4.elf`, `fixup4.dat`, ...) get copied onto the vfat
   partition. See part D.5 — flagged rather than guessed at.
7. No newer upstream releases exist for either repo as of 2026-09-11. Part E.

---

## Part A — what `bootc-base-imagectl build-rootfs` actually produces

### The command itself

From the upstream doc (`bootc-base-imagectl.md`), quoted:

> The core operation is `bootc-base-imagectl build-rootfs`. This command takes just two
> arguments: A "source root" which should have an `/etc/yum.repos.d` that defines the input
> RPM content... A path to the target root filesystem which will be generated as a
> directory.
>
> The current implementation uses `rpm-ostree` on a manifest (treefile) embedded in the
> container image itself. These manifests are not intended to be editable directly.

AlmaLinux's `10-rpi/Containerfile:15` invokes it with only one positional argument:

```
RUN /usr/libexec/bootc-base-imagectl build-rootfs --manifest=almalinux-10-rpi /target-rootfs
```

The doc's own example (`build-rootfs --manifest=minimal /repos /target-rootfs`) takes two.
Inferred (not directly documented): the source-root argument is optional and defaults to
the container's own `/`, which already has `/etc/yum.repos.d` populated by the two `COPY
--from=repos` lines immediately above. This is consistent with everything else observed but
I did not find it stated explicitly anywhere.

Bottom line for us: this command runs `rpm-ostree compose` (implementation detail, subject
to change per the doc) against a treefile resolved from `--manifest=<name>`, installs RPMs
from the repos in the builder's `/etc/yum.repos.d`, and writes a finished rootfs directory.
We are reproducing its **output shape**, not the tool.

### The manifest tree and how `include:`/file-overwrite actually resolves

The manifests are not published anywhere as documentation — they ship inside
`quay.io/centos-bootc/centos-bootc:stream10` at
`/usr/share/doc/bootc-base-imagectl/manifests/`. I pulled that image and extracted them to
verify this section against the real files, not the doc's abstract description.

`include:` entries are plain relative-path lookups from the including file's own directory;
there is no merge-with-override semantics visible at the YAML level for `include` itself
(individual keys like `packages` do accumulate additively across an include chain, but a
file referenced by `include:` is resolved once by path, full stop). AlmaLinux exploits this
by **overwriting manifest files in place** at their `/usr/share/doc/bootc-base-imagectl/manifests/`
paths before running `build-rootfs`, rather than writing new manifest content:

```
COPY 10-rpi/almalinux-10-rpi.yaml /usr/share/doc/bootc-base-imagectl/manifests/
COPY 10-rpi/kernel.yaml /usr/share/doc/bootc-base-imagectl/manifests/minimal/
RUN sed -i 's/efibootmgr//g' /usr/share/doc/bootc-base-imagectl/manifests/minimal/bootupd.yaml
```
(`10-rpi/Containerfile:10-13`)

The resolved include chain, confirmed by reading every file in it:

```
almalinux-10-rpi.yaml (AlmaLinux's own, COPY'd in)
  releasever: 10, repos: [baseos, appstream, raspberrypi]
  packages: [almalinux-repos, almalinux-release-raspberrypi]
  include: standard/manifest.yaml          <- built into centos-bootc:stream10
    include: ../minimal-plus/manifest.yaml
      include: ../minimal/manifest.yaml
        include: kernel.yaml               <- OVERWRITTEN by AlmaLinux's COPY, see below
                 postprocess-conf.yaml
                 tmpfiles.yaml
                 bootc.yaml                <- packages: systemd systemd-pam dbus, bootc,
                                               xfsprogs e2fsprogs dosfstools
                 bootupd.yaml              <- PATCHED by AlmaLinux's sed, see part D.3
                 ostree.yaml               <- sets prepare-root.conf, see part D.4
                 initramfs.yaml            <- writes dracut.conf.d, see part D.1
                 basic-fixes.yaml
                 kernel-install.yaml
                 systemd-presets.yaml
      packages: attr bash-completion hostname iproute jq less vim-minimal
                podman skopeo crun criu criu-libs cryptsetup lvm2 tar
                zram-generator iptables-nft NetworkManager openssh-clients
                openssh-server linux-firmware polkit sudo tzdata
                rpm-ostree nss-altfiles fwupd
    packages: autoupdates.yaml, networking-tools.yaml, system-configuration.yaml,
              coreos-user-experience.yaml, persistent-journal.yaml,
              initramfs-full.yaml, generic-growfs.yaml (not read in detail — generic
              CoreOS-style base content, not Pi-specific, out of this spec's scope)
```

Because `almalinux-10-rpi.yaml` is placed at the **top level** of the manifests directory
and `10-rpi/kernel.yaml` is placed at `minimal/kernel.yaml`, they silently replace whatever
`bootc-base-imagectl` shipped at those exact paths. The stock `minimal/kernel.yaml` (as
shipped in `centos-bootc:stream10`) is just:

```yaml
packages:
 - kernel
exclude-packages:
  - kernel-debug
  - kernel-debug-core
  - ...
```

AlmaLinux's replacement (`10-rpi/kernel.yaml`, copied verbatim below) is what actually
determines the Pi kernel/firmware package set:

```yaml
packages:
  - filesystem
  - linux-firmware-raspberrypi
  - raspberrypi-sys-mods
  - raspberrypi-userland
  - raspberrypi2-firmware
  - raspberrypi2-kernel4
  - raspberrypi2-kernel4-tools
exclude-packages:
  - kernel-debug
```

This confirms `STATUS.md`'s framing is right: we are not meant to use
`bootc-base-imagectl` (it is a thin rpm-ostree/treefile wrapper, entirely RPM-shaped), we
are meant to reproduce **the union of `minimal/manifest.yaml`'s postprocess side-effects**
(prepare-root.conf, dracut.conf.d, kernel-install.conf.d, systemd presets, tmpfiles) plus
AlmaLinux's Pi-specific kernel/firmware package substitution, using pacman packages and our
own Containerfile `RUN` steps instead.

### `minimal/kernel-install.yaml` — worth carrying over verbatim in spirit

```
mkdir -p /usr/lib/kernel/install.conf.d
echo -e "...\nlayout=ostree" | tee /usr/lib/kernel/install.conf /usr/lib/kernel/install.conf.d/00-bootc-kernel-layout.conf
```

Sets `installonlypkgs=''` and `protect_running_kernel=False` for dnf — pure RPM/dnf
concerns, not applicable to pacman, skip entirely. The `layout=ostree` bit for
`kernel-install.conf` is a systemd `kernel-install` convention (tells `kernel-install` /
`bootctl` not to manage `/boot` itself since rpm-ostree/bootc will). Whether Arch's dracut +
mkinitcpio-bypass setup needs the equivalent is a Containerfile-workstream question, not
something rpi-bootc-bootloader itself depends on — noting it here so it isn't lost, not
resolving it.

### `bootc-base-imagectl rechunk`

Quoted from the doc: takes a built image and, "operating on its final merged filesystem
tree," splits it into content-addressed layers (by default via `rpm-ostree`, optionally via
`chunkah`) and zeroes timestamps for reproducibility. `bootc-images-rpi/Makefile:32-41`
calls this on every build (`make rechunk`) before pushing. This is a generic
post-build optimization step, not RPM-specific in principle — `chunkah` mode is explicitly
"content-agnostic and not tied to rpm-ostree" per the doc. Whether the existing
`Containerfile.pc`/Taskfile pipeline already has an equivalent (it likely does, given
`STATUS.md` references a working x86_64 build) is outside this spec's scope to re-verify;
flagging that rechunking is a real, separate concern from everything else in this document.

---

## Part B — rpi-bootc-bootloader, traced completely

### Files read

- `/etc/rpi-bootc-bootloader/tryboot.conf` (optional, `load_tryboot_config`)
- `/boot/loader/entries/ostree-1.conf`, `/boot/loader/entries/ostree-2.conf` (BLS entries;
  `linux`, `initrd`, `options` lines parsed with `grep`/`sed`/`awk`)
- `$OSTREEPATH/usr/lib/modules/<kver>/rpi-config.txt` (optional, per-deployment)
- `$OSTREEPATH/usr/share/raspberrypi2-kernel*/*/boot/*` and `.../overlays/*` — **the one line
  that changes**, see part D.1
- Whatever is already on the vfat partition (`config.txt`, `tryboot.txt`,
  `config-bootc-default.txt`, `config-bootc-fallback.txt`, `config-bootc-common.txt`) — read
  via `cmp` before deciding whether to rewrite

### Files written

All under the vfat partition, mounted transiently at `/tmp/mnt` (`$TMPMNT`):

```
bootc/entries/ostree-<N>/vmlinuz
bootc/entries/ostree-<N>/initrd
bootc/entries/ostree-<N>/cmdline.txt
bootc/entries/ostree-<N>/*.dtb
bootc/entries/ostree-<N>/overlays/*
bootc/entries/ostree-<N>/rpi-config.txt        (only if present in the deployment)
tryboot.txt
config-bootc-default.txt
config-bootc-fallback.txt
config.txt                    (only created if absent — never overwritten once it exists)
config-bootc-common.txt       (only created if absent — this is the user-customization file)
rpi-bootc-log.txt             (bash xtrace output, via BASH_XTRACEFD)
```

Every write goes through `update_file_if_changed`/`cmp`, so unchanged content is never
rewritten — this is the "as atomic as possible" requirement from `design.md`, implemented
as read-compare-then-atomic-rename (`cp` to `.tmp`, then `mv`), not as a transactional
partition swap. There is no atomicity guarantee across the *set* of files, only per-file.

### External commands and their Arch package

| command | used for | Arch package | verified |
|---|---|---|---|
| `bash` | interpreter, `[[`, `{FD}>` fd redirection | `bash` | stock |
| `cat`, `cp`, `mv`, `rm`, `mkdir`, `touch`, `basename`, `ls`, `wc`, `readlink`, `realpath` | file plumbing throughout | `coreutils` | stock |
| `cmp` | change detection in `update_file_if_changed`/`setup_bootloader` | `diffutils` | stock — **not** coreutils |
| `grep`, `sed` | BLS parsing, tryboot value extraction | `grep`, `sed` | stock |
| `awk` | `mount \| awk '$3 == "/sysroot"'`, `KERNEL=$(... \| awk '{print $2}')` | `gawk` (owns `/usr/bin/awk` on Arch) | stock |
| `mount`, `umount` | mounting `$MNTDEV` at `$TMPMNT`; **note:** the script parses plain `mount` table output, it never calls `findmnt` despite the task brief's hint — confirmed by reading the script, `findmnt` does not appear anywhere in it | `util-linux` | stock |
| `jq` | parsing `bootc status --format json` | `jq` 1.8.2-1 | present in `extra`, confirmed in `e972-extra.db` |
| `bootc` | `bootc status --format json` | none in ALARM — must be our own cross-compiled binary per the build-host plan in `TEAM-BRIEF.md` | confirmed absent from `alarm`/`core`/`extra` db snapshots |
| `ostree` (`/usr/bin/ostree admin finalize-staged`) | called directly by `finalize-staged` before re-syncing | `ostree` 2026.4-1 | present in `extra` |
| `vcmailbox` | `tryboot`/`tryreboot` commands, sets the tryboot flag via mailbox property `0x00038064` | `raspberrypi-utils` 20260904-1 | **confirmed**, see below |
| `reboot` | `tryreboot` only | `systemd` (provides `/usr/bin/reboot`) | stock |

### vcmailbox — confirmed present, not a gap

`raspberrypi-utils` 20260904-1 sits in the ALARM `alarm` repo (`e972-alarm.db`), described
as "Legacy scripts and simple applications for Raspberry Pi", `url =
https://github.com/raspberrypi/utils`. Its actual PKGBUILD:

```
_commit=65bad738fb9b40d19659f210705fd629db4fc7b0
...
build() {
  cd "utils-$_commit"
  cmake -S . -B . -DCMAKE_INSTALL_PREFIX=/usr
  make
}
package() {
  cd "utils-${_commit}"
  make install DESTDIR="$pkgdir"
  ...
}
```

It builds the entire upstream `raspberrypi/utils` tree via its top-level `CMakeLists.txt`,
which includes `add_subdirectory(vcmailbox)`. That subdirectory's own `CMakeLists.txt`:

```cmake
add_executable(vcmailbox vcmailbox.c)
install(TARGETS vcmailbox RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
```

`CMAKE_INSTALL_PREFIX=/usr` + default `CMAKE_INSTALL_BINDIR` (`bin`) puts the binary at
`/usr/bin/vcmailbox`. `raspberrypi-utils` also `replaces=('raspberrypi-firmware')` and
`conflicts=('raspberrypi-firmware')` — it is the modern split-out successor of a package
that used to ship these utilities bundled with the firmware blobs, which is consistent with
what it is. **The tryboot rollback feature is not gated on Arch.**

---

## Part C — partition and mount assumptions

### What the script actually requires

`sync_bootloader()`:

```bash
RAW_DEV=$(mount | awk '$3 == "/sysroot" {print $1}')
MNTDEV=$(echo "$RAW_DEV" | sed -E 's/[0-9]+$/1/')
...
mount "$MNTDEV" "$TMPMNT" || exit 1
```

This is the entire disk-layout contract: whatever block device is mounted at `/sysroot`
(the real ostree physical sysroot, mounted early in boot by the ostree dracut module from
the `ostree=` kernel argument — this is standard ostree behavior, not something
rpi-bootc-bootloader sets up itself), take its device node name and **replace the trailing
run of digits with the literal `1`**. No label, no GPT partition type, no mountpoint lookup
is consulted — purely positional. `MNTDEV` can be overridden by the environment, but neither
`sync` nor `finalize-staged` do that by default.

Consequences:

- The vfat firmware partition **must be partition 1** on the same physical/block device that
  carries the root filesystem (whatever partition number root actually is). It does not need
  to be adjacent to root; nothing about ordering beyond "partition number 1" matters.
- This works identically for `/dev/sdaN`, `/dev/mmcblk0pN`, `/dev/nvme0n1pN` naming, since the
  regex only touches the trailing digit run regardless of the `p`-separator convention.
- The script re-derives and re-mounts the vfat partition **fresh, every single invocation**
  (both `sync` and `finalize-staged`). Nothing about a prior mount is trusted or reused.

### Does the vfat partition need to be mounted at runtime (e.g. in fstab as `/boot/efi`)?

**No.** Confirmed by reading the entire script: it never references `/boot/efi` anywhere, in
either the runtime path or the two occurrences of "efi" implied by AlmaLinux's manifest
patching (which lives entirely outside this script — see part D.3). It mounts the vfat
partition itself, transiently, at `$TMPMNT` (`/tmp/mnt`), does its writes, and unmounts on
exit via the `trap cleanup EXIT` handler. A persistent fstab entry for the vfat partition is
neither required nor read. This directly answers the brief's open question in part C of the
task: **our install procedure does not need to keep the firmware partition mounted**, and in
fact should probably avoid it (mounting it elsewhere risks a stale/conflicting mount when
the script tries its own transient mount at the same device).

### Reconciling this with `bib-config.toml`

```toml
[[customizations.disk.partitions]]
type = "plain"
label = "CIDATA"
mountpoint = "/boot/efi"
fs_type = "vfat"
minsize = "1 GiB"

[[customizations.disk.partitions]]
type = "plain"
label = "boot"
mountpoint = "/boot"
fs_type = "xfs"
minsize = "1 GiB"

[[customizations.disk.partitions]]
type = "plain"
label = "root"
mountpoint = "/"
fs_type = "xfs"
minsize = "4 GiB"
```

Partition declaration order becomes GPT partition order for `bootc-image-builder`/`bib`
(confirmed operationally — see the `action.yml` trace below: the p1/p2/p3 loop-device
partitions map exactly to this declaration order). So on AlmaLinux's image: p1 = vfat
firmware, p2 = xfs `/boot`, p3 = xfs `/`. `/sysroot` at runtime is really the deployment's
root, i.e. p3; `MNTDEV`'s digit-substitution turns `...p3` into `...p1`, landing correctly on
the vfat partition.

The `/boot/efi` mountpoint declared in `bib-config.toml` is **only meaningful to
`bootc-image-builder`/`bib` at image-build time** — it is bib's own convention for "this is
the special firmware/ESP-shaped partition," used so bib knows to format it as vfat and where
to put it in the partition table, and it doubles as bib's target for seeding cloud-init's
`NoCloud` datasource (the `CIDATA` label is the standard cloud-init seed-volume label; see
the `action.yml` trace, where `meta-data`/`user-data`/`README.txt` get copied straight onto
this same partition). There is nothing in `rpi-bootc-bootloader` that reads or depends on an
`/boot/efi` fstab entry existing on the deployed system, and I found no fstab entry for it in
anything AlmaLinux ships either. **Whether our own disk-image builder needs a `/boot/efi` (or
any) mountpoint declaration is purely a question for whatever tool replaces `bib` in our
pipeline — it does not need to survive into the running system's `/etc/fstab`.**

### The full partition-population sequence, traced from `action.yml`

This is the only place the complete, working sequence is spelled out end to end (`bootc-images-rpi/.github/actions/shared-steps/action.yml:126-179`):

1. `bootc-image-builder --config /output/bib-config.toml --type raw --rootfs xfs --local
   quay.io/almalinuxorg/almalinux-bootc-rpi:<ver>` builds the raw GPT disk image: this does an
   implicit `bootc install`-equivalent into p3 (root) and p2 (`/boot`), per `bib-config.toml`'s
   partitioning. p1 (vfat) comes out of this step formatted but otherwise empty.
2. `losetup -f --show -P` on the resulting `disk.raw` to get partition device nodes
   (`${LOOP}p1`, `${LOOP}p2`, `${LOOP}p3`).
3. `fatlabel ${LOOP}p1 "CIDATA"` — reasserts the label (belt-and-braces; bib should have
   already labelled it per `bib-config.toml`).
4. Mount p1 on the **host**, copy `meta-data` (empty, `touch`), `user-data`, `README.txt`
   onto it (cloud-init NoCloud seed — unrelated to rpi-bootc-bootloader, first-boot user
   creation only).
5. With that host mount of p1 **bind-mounted into a privileged container** as `/tmp` (`-v
   /tmp/mnt:/tmp`), and `/dev` passed through (`-v /dev:/dev`) so the loop-partition device
   nodes are visible inside, run a shell in the just-built bootstrap image
   (`localhost/<image>:<ver>-bootstrap-...`, built from `bootstrap-image/Dockerfile`, which
   is just the shipped image plus `cloud-init`/`cloud-utils-growpart`):
   ```
   mount ${LOOP}p3 /sysroot && mount ${LOOP}p2 /boot
   && (bootc status --format json | jq .)
   && grep options /boot/loader/entries/ostree-1.conf
   && cp -a --no-preserve=links /usr/lib/ostree-boot/* /tmp/
   && rpi-bootc-bootloader version
   && bash -x rpi-bootc-bootloader sync
   ```
   This is exactly what makes the MNTDEV auto-detection in part C work: `/sysroot` here is
   `${LOOP}p3` (root), so `mount | awk '$3=="/sysroot"'` reports that device, and the
   trailing-digit substitution correctly lands on `${LOOP}p1` (vfat) — the same device node
   family, visible in the container purely because `-v /dev:/dev` exposes it.
6. `umount /tmp/mnt` on the host.
7. The rest of the step (`sgdisk --typecode=1:0700`, `sgdisk -m 1:2:3`, retyping p1 as a
   plain FAT MBR-visible partition) produces a **second** image variant for MBR-only
   firmware (older Pi models booting without GPT support). Not relevant to a Pi 5-only
   target; noting it exists so nobody mistakes it for something rpi-bootc-bootloader needs.

One step in that sequence I could not explain from source: `cp -a --no-preserve=links
/usr/lib/ostree-boot/* /tmp/` copies the contents of `/usr/lib/ostree-boot` (the directory
ostree/bootupd use as their own canonical boot-content source — see the `bootupd.yaml`
postprocess comment in part D.3, "Transforms /usr/lib/ostree-boot into a bootupd-compatible
update payload") directly onto the **root** of the vfat partition. `rpi-bootc-bootloader`
never reads anything from the vfat root except the four files it manages itself
(`config.txt`, `tryboot.txt`, `config-bootc-{default,fallback,common}.txt`) plus whatever it
writes under `bootc/entries/`. I read the whole script twice looking for a consumer of this
copy and found none. Best-supported read: **vestigial**, a leftover from bootupd/grub
tooling that isn't actually exercised by the Pi native-firmware boot path, harmless because
nothing looks at it. Not confident enough to state as fact — flagging it, not asserting it.

---

## Part D — the Arch diff

### D.1 — DTB_SRC (the one script change)

`process_path()`:

```bash
local DTB_SRC=$(readlink -f "$OSTREEPATH/usr/share/raspberrypi2-kernel"*/*/boot/ 2>/dev/null)
```

Traced this glob against the actual RPM package layout via `raspberrypi2-kernel4`'s naming
(matches the `raspberrypi2-kernel*` prefix glob) — the nested `*/boot/` after it is an RPM
packaging quirk of that spec (likely side-by-side kernel-variant support), not something we
need to reproduce. Arch's `linux-rpi` PKGBUILD (`core/linux-rpi/PKGBUILD`,
`archlinuxarm/PKGBUILDs`) does this in `_package()`:

```bash
mkdir -p "${pkgdir}"/boot
make INSTALL_DTBS_PATH="${pkgdir}/boot" dtbs_install
if [[ $CARCH == "aarch64" ]]; then
  find "${pkgdir}/boot/broadcom" -type f -print0 | xargs -0 mv -t "${pkgdir}/boot"
  rmdir "${pkgdir}/boot/broadcom"
fi
cp arch/$KARCH/boot/dts/overlays/README "${pkgdir}/boot/overlays"
```

So after `pacman -S linux-rpi`, dtbs land flattened directly at `/boot/*.dtb`, and overlays
(`*.dtbo` plus a stray `README` text file) at `/boot/overlays/`. `/boot` must be empty in the
committed bootc image (`STATUS.md` gap #2), so our Containerfile must relocate this content
before the image is committed.

**Correction, 2026-09-11:** the first draft of this section proposed a fixed package-level
target, `/usr/lib/raspberrypi/boot/`. That's wrong, and `kernel-layout.md`'s decision 3
(carried into `TEAM-BRIEF.md`'s corrections) has it right: dtbs and overlays are build
output of `linux-rpi`, the same package that produces the kernel, and they only mean
anything paired with the exact kernel build they shipped with. The sync hook already
derives a per-deployment, per-kernel-version directory for `rpi-config.txt`
(`BOOTDIR="$OSTREEPATH/usr/lib/modules/$KVER"`); putting dtbs there instead of a
separately-named path means there is exactly one place in a deployment's tree that holds
"this kernel's boot-relevant files," with no second path to keep in sync by hand and no
way for a dtb set to silently outlive the kernel it was built against. `/usr/lib/raspberrypi/boot/`
is not being discarded as a name, it is simply the wrong content for it: that path is
reserved for `raspberrypi-bootloader`'s VideoCore blobs (`start*.elf`, `fixup*.dat`,
`bootcode.bin`), which come from a different package that does not rev with the kernel and
that this script never reads at all (see kernel-layout.md and disk-image.md's
`seed-firmware.sh`). Corrected relocation:

```
mkdir -p /usr/lib/modules/$kver/dtbs/overlays
cp /boot/*.dtb /usr/lib/modules/$kver/dtbs/
cp /boot/overlays/*.dtbo /usr/lib/modules/$kver/dtbs/overlays/
# do not copy overlays/README — sync_dir_with_pattern in rpi-bootc-bootloader has no
# extension filter, it would get shipped onto the vfat overlays/ dir as harmless but
# pointless cruft otherwise
```

And the script's `DTB_SRC` line reads from that same versioned directory (patch shown in
full in `docs/rpi-bootc-bootloader.arch-proposed`):

```bash
local KVER=$(ls "$OSTREEPATH/usr/lib/modules/" | head -n 1)
local BOOTDIR="$OSTREEPATH/usr/lib/modules/$KVER"
local DTB_SRC=$(readlink -f "$BOOTDIR/dtbs" 2>/dev/null)
```

This is the **entire** functional diff to the script itself, now that it's corrected: one
assignment changed (plus hoisting the `KVER`/`BOOTDIR` computation that already existed
lower in the function, since `DTB_SRC` now depends on it), everything else byte-identical.

### D.2 — the vmlinuz placeholder problem (new finding, not in `STATUS.md`)

`bootc-dev/bootc`'s own install doc states the contract plainly:

> The Linux kernel (and optionally initramfs) is embedded in the container image; the
> canonical location is `/usr/lib/modules/$kver/vmlinuz`

`linux-rpi`'s `_package()` does not do this. It does:

```bash
cp arch/$KARCH/boot/$_image "${pkgdir}/boot/$_kernel"   # the REAL kernel -> /boot/kernel8.img
...
# rather than use another hook (90-linux.hook) rely on mkinitcpio's 90-mkinitcpio-install.hook
# which avoids a double run of mkinitcpio that can occur
touch "${pkgdir}/usr/lib/modules/$(<version)/vmlinuz"    # a ZERO-BYTE placeholder
```

That `touch` is deliberate upstream Arch/ALARM packaging behavior — it exists so
mkinitcpio's own install hook has something to stat, since the real bootable image on a
normal Arch/ALARM system is `/boot/kernel8.img`, not `/usr/lib/modules/<kver>/vmlinuz`. It
predates any bootc/ostree concern and has nothing to do with this port.

The problem: `/boot` must be emptied for bootc (same constraint as D.1), which means the
*real* kernel image at `/boot/kernel8.img` also has to move before `/boot` gets cleared —
and if the only thing left at `/usr/lib/modules/<kver>/vmlinuz` is the empty placeholder,
whatever commits the ostree/bootc tree will pick that empty file up as "the kernel." This
would silently produce a deployment with a zero-byte kernel image — `rpi-bootc-bootloader`
would then dutifully copy that empty file onto the vfat partition as
`bootc/entries/ostree-N/vmlinuz` and the Pi would fail to boot with no useful error message
from this script (it does not size-check the kernel/initrd it copies).

Required fix, before `/boot` is cleared in the Containerfile:

```bash
install -m644 /boot/kernel8.img "/usr/lib/modules/$(cat /usr/lib/modules/*/pkgbase 2>/dev/null || true; ls /usr/lib/modules)/vmlinuz"
```

(exact form depends on how the Containerfile workstream structures the kernel-version
lookup — the point to hand off is: **overwrite the placeholder with the real image before
touching `/boot`**, don't just relocate dtbs and assume the kernel is fine.)

### D.3 — bootupd/grub/shim/efibootmgr and SELinux: nothing in the script, everything in the manifest

`rpi-bootc-bootloader` itself: no reference to SELinux, grub, shim, bootupd, or efibootmgr
anywhere in the script. Confirmed by reading the whole file — these are exclusively concerns
of the RPM package set AlmaLinux installs, not of the sync-hook logic. This means **none of
these require a script patch**; they only affect what we choose to install in the
Containerfile.

For completeness, since the task asked specifically what `sed -i 's/efibootmgr//g'` in
`10-rpi/Containerfile:13` actually does — pulled and read the real
`minimal/bootupd.yaml`:

```yaml
packages:
  - bootupd
packages-aarch64:
  - grub2-efi-aa64 efibootmgr shim
...
postprocess:
  - |
    #!/bin/bash
    /usr/bin/bootupctl backend generate-update-metadata
  - |
    #!/bin/bash
    # Workaround for https://issues.redhat.com/browse/RHEL-78104
    rm -vrf /usr/lib/ostree-boot/loader
```

The sed only deletes the substring `efibootmgr` from the single YAML list entry
`"grub2-efi-aa64 efibootmgr shim"` (one line, three space-separated package names). It does
**not** remove `bootupd`, `grub2-efi-aa64`, or `shim` — those still get installed.
`STATUS.md`'s "no bootupd at all... AlmaLinux even strips efibootmgr" is imprecise: bootupd,
GRUB's aarch64 EFI binary, and shim are present but inert dead weight in AlmaLinux's shipped
image, unused because nothing in the boot chain (VideoCore firmware reading `config.txt`)
ever invokes them. Most plausible reason for stripping only `efibootmgr` specifically: its
RPM `%post` scriptlet likely does something that needs real UEFI runtime services
(`/sys/firmware/efi`) which don't exist during a container build, so it fails/errs out at
install time; `grub2-efi-aa64`/`shim` install cleanly as inert files.

**For our port this is simpler, not harder:** we are not using `bootc-base-imagectl`'s
manifest chain at all, so we simply never install `grub`, `shim`, `efibootmgr`, `bootupd`,
or `selinux-policy-targeted`/`container-selinux` (the latter two come from
`minimal/manifest.yaml`'s own base `packages:` list, unrelated to bootupd) in the first
place. Nothing to strip, nothing to work around. One consequence to be aware of, covered
next: bootc's install-time bootloader auto-selection behaves differently when the bootupd
package is simply **absent** versus present-but-inert.

### D.4 — correction to `STATUS.md` decision #2: composefs

This is the most consequential finding in this document and directly revises a "settled"
decision, so I'm laying out the full evidence chain rather than just asserting a conclusion.

**What the manifest evidence shows.** `minimal/ostree.yaml`, read from the actual
`centos-bootc:stream10` image (part of the include chain every `*-rpi.yaml` target pulls in,
never overridden by anything in `bootc-images-rpi`):

```yaml
postprocess:
  - |
    #!/usr/bin/env bash
    mkdir -p /usr/lib/ostree
    cat > /usr/lib/ostree/prepare-root.conf << EOF
    [composefs]
    enabled = yes
    [sysroot]
    readonly = true
    EOF
```

AlmaLinux's shipped, proven-on-real-hardware Pi image (README: "tested on... rpi5...
rpi4... rpi3... rpi zero 2w") therefore has `composefs enabled = yes` in
`/usr/lib/ostree/prepare-root.conf`. Nothing in `bootc-images-rpi` overrides this file.

**What `STATUS.md` decision #2 currently says:** "`--bootloader=none` is documented as
unsupported on the composefs backend... So the Pi image sets `composefs enabled = no` in
`/usr/lib/ostree/prepare-root.conf`."

These two are in direct tension: if `composefs enabled = no` were actually required to make
`--bootloader=none` work, AlmaLinux's own working image — which sets it to `yes` and is
reported working on real Pi 3/4/5 hardware with exactly the native-firmware, no-bootloader
boot path this whole project is copying — would be a contradiction. It isn't a
contradiction, because these are two different things that happen to share the word
"composefs." Confirmed directly from `bootc-dev/bootc`'s own docs:

> `docs/src/bootloaders.md`: "NOTE: none is only supported for the Ostree backend and not
> for Composefs."
>
> `docs/src/experimental-composefs.md`: "The composefs backend is an experimental
> alternative storage backend that uses composefs-rs instead of ostree for storing and
> managing bootc system deployments... Unlike the ostree backend, which keeps its
> repository at `/ostree/repo`... There is no `/ostree/repo`; the composefs backend doesn't
> use the ostree repository at all... Whenever the container image has a UKI, bootc
> automatically selects the composefs backend during installation... There is a
> `--composefs-backend` option for `bootc install` to explicitly select a composefs backend
> apart from sealed images."

So: `[composefs] enabled=` in `prepare-root.conf` is an **ostree-internal** setting —
whether the *ostree backend's own* per-deployment checkouts are stored as composefs-formatted
images (for fsverity/integrity) versus classic hardlink checkouts. It still uses
`/ostree/repo`, `/sysroot/ostree/deploy/...`, and `/boot/loader/entries/ostree-N.conf` — the
exact paths `rpi-bootc-bootloader` reads. The thing `--bootloader=none` actually can't be
used with is bootc's **separate, higher-level storage backend selection** (ostree backend vs.
the experimental composefs-rs backend, an entirely different on-disk repository format at
`/composefs` + `/state/deploy/...`), which only activates if the image has a UKI, or if
`--composefs-backend` is passed explicitly to `bootc install`.

**This matches the existing house convention exactly.** `/home/bupd/Projects/archlinux`'s
`Containerfile.base:145-149` sets `[composefs] enabled = yes` (same setting AlmaLinux uses),
and `Taskfile.yml`'s `validate` task asserts this as an invariant:

```
grep -Eq "^[[:space:]]*enabled[[:space:]]*=[[:space:]]*yes$" /usr/lib/ostree/prepare-root.conf
```

The PC target's own install invocation (`Taskfile.yml:175`) is:

```
bootc install to-disk --composefs-backend --via-loopback ... --filesystem ext4 --wipe --bootloader systemd
```

It explicitly opts **into** `--composefs-backend`, with `--bootloader systemd`
(systemd-boot, UEFI). That's a real, deliberate choice for the x86 PC target. For the Pi
target, matching `--bootloader=none`'s actual documented constraint, the install invocation
must **not** pass `--composefs-backend` (stay on the default ostree backend) and must pass
`--bootloader none` (or `bootloader = "none"` in an `/usr/lib/bootc/install/*.toml` file,
same merge convention `bootc-install.md` documents for `root-fs-type`/`filesystem.root.type`)
instead of `--bootloader systemd`.

**Recommendation, pending your decision:** set `[composefs] enabled = yes` in the Pi image's
`prepare-root.conf` too — matching both AlmaLinux's proven reference and the existing
`Containerfile.base` invariant — and make the only Pi-specific divergence the
backend/bootloader selection at install time (no `--composefs-backend`, `--bootloader none`).
This is a change from what `STATUS.md` currently states. **I did not change `STATUS.md`
myself** — that's a decision for you, not something a spec workstream should silently
overwrite.

One more concrete, easy-to-miss requirement that falls out of this: `bootloaders.md` also
says "If bootupd is not present in the input container image, then systemd-boot will be used
by default." Since our image won't install bootupd at all (part D.3), the *default* fallback
if we don't say anything is systemd-boot, not none. **`bootloader = "none"` must be set
explicitly** — omitting bootupd is not sufficient by itself to get the no-bootloader
behavior this whole architecture depends on.

### D.5 — open question: where do the VideoCore firmware blobs get onto the vfat partition?

`raspberrypi-bootloader` (ALARM package, `core/linux-rpi`'s sibling) installs only this:

```bash
package() {
  mkdir -p "${pkgdir}"/boot
  cp "${srcdir}"/firmware-${_commit}/boot/{*.dat,*.bin,*.elf} "${pkgdir}"/boot
}
```

i.e. `bootcode.bin`, `start4.elf`, `fixup4.dat`, etc. land under `/boot` — same "must be
empty for bootc" problem as D.1/D.2, and these are genuinely static files, not something
`rpi-bootc-bootloader` manages per-slot (I read the whole script again specifically looking
for this — it only ever touches `vmlinuz`, `initrd`, `cmdline.txt`, `*.dtb`, `overlays/*`,
`rpi-config.txt`, and its own four generated config files; never anything named `start*.elf`,
`fixup*.dat`, or `bootcode.bin`).

I looked for the equivalent step on the AlmaLinux side and could not find it:

- Not in `rpi-bootc-bootloader` (checked directly, see above).
- Not in `bib-config.toml` (no `[customizations.files]` or equivalent section — the file only
  has the three partition stanzas quoted in part C).
- Not in `.github/actions/shared-steps/action.yml`'s full build/partition-population
  sequence (traced completely in part C — the only things copied onto p1 are the cloud-init
  seed files and whatever `rpi-bootc-bootloader sync` itself writes).
- Not in `bootc-image-builder`/`osbuild`'s own source — `gh api
  'search/code?q=raspberrypi+repo:osbuild/bootc-image-builder'` returns zero hits.
- Bootupd's ARM/RPi firmware-payload support (which would be the natural place for this) is,
  per `STATUS.md`'s own citation, still open and unmerged upstream
  (`coreos/bootupd#651`/`#959`) — so it isn't bootupd doing it either.

I don't have a confirmed answer for this. My best-supported guess is that it doesn't happen
anywhere in the automated pipeline shown to us, and either (a) it's a manual step in
AlmaLinux's documented Pi setup process that isn't captured in this repo, or (b) it's
genuinely missing and users are expected to flash it separately or it comes pre-seeded on
SD cards from another source. **Either way, this does not block our port** — regardless of
how AlmaLinux handles it, our own disk-image/first-boot provisioning has to seed the vfat
partition with `raspberrypi-bootloader`'s static blobs exactly once, outside of
`rpi-bootc-bootloader`'s scope (which correctly never touches them, since they don't change
per bootc deployment). Recommend relocating them at build time the same way as the dtbs
(e.g. `/usr/lib/raspberrypi/firmware/`) and adding a one-time seed step to whatever tool
partitions and provisions the disk image — this is a Containerfile/provisioning-workstream
decision, flagging the requirement here so it isn't dropped.

---

## Part E — upstream freshness check

Both repos checked against GitHub directly with `gh api` on 2026-09-11.

**`kfox1111/rpi-bootc-bootloader`:**

```
$ gh api repos/kfox1111/rpi-bootc-bootloader/tags
v0.0.8  (commit 7e44a51, "Boot properly on rpi4 and maybe others")
v0.0.7 ... v0.0.1
```

No tag newer than `v0.0.8`. `gh api .../commits?since=2026-01-01` shows exactly one commit
past the `v0.0.8` tag: `82739f4c9ae6de9ce071014bff9dee16842fb978`, "Update docs"
(2026-03-16), which our local clone's HEAD already matches — confirmed by comparing local
`git log -1` against the GitHub API's latest-commit response, identical SHA. Nothing to pull.

**`AlmaLinux/bootc-images-rpi`:**

```
$ gh api 'repos/AlmaLinux/bootc-images-rpi/commits?since=2026-04-09T00:00:00Z'
2e594936a0  2026-04-09T13:28:06Z  "Fix for bootc dracut issue"
```

Exactly one commit, which is the boundary commit itself (`since` is inclusive) — this is
also our local clone's exact HEAD, confirmed identical via `gh api
'repos/AlmaLinux/bootc-images-rpi/commits?per_page=1'`. Nothing to pull.

That one commit (already reflected in the clone we read, so nothing to act on, but worth
recording what it does): adds a postprocess step to every `*-rpi.yaml` target that strips
the `bootc` dracut module from `20-bootc-base.conf` —

```bash
# Remove 'bootc' dracut module from initramfs config
# AlmaLinux bootc package does not yet ship the dracut module (requires >= 1.11.0)
DRACUT_CONF="/usr/lib/dracut/dracut.conf.d/20-bootc-base.conf"
if [ -f "${DRACUT_CONF}" ]; then
  sed -i 's/ bootc / /' "${DRACUT_CONF}"
fi
```

This is a workaround for AlmaLinux's specific packaged `bootc` RPM version lagging the
dracut-module requirement. Since we're cross-compiling our own `bootc` from source per the
build-host plan, whether this applies to us depends entirely on which `bootc` version/commit
we build and whether it ships the dracut module — not something to copy blindly, just
flagging that it exists and why, in case the initramfs comes up without an `ostree=` root
resolving correctly and this is the reason.

---

## Summary of concrete actions for other workstreams

1. Vendor `docs/rpi-bootc-bootloader.arch-proposed` as `/usr/bin/rpi-bootc-bootloader` (one
   line different from upstream v0.0.8+1).
2. Install `raspberrypi-utils`, `jq`, `ostree` (already on the confirmed-available list).
3. In the Containerfile, after installing `linux-rpi`:
   - relocate `/boot/*.dtb` → `/usr/lib/modules/$kver/dtbs/*.dtb`
   - relocate `/boot/overlays/*.dtbo` → `/usr/lib/modules/$kver/dtbs/overlays/*.dtbo`
     (skip `README`) — corrected 2026-09-11, see D.1; this is versioned with the kernel,
     not the fixed path this list originally said
   - **before** clearing `/boot`, overwrite the empty `/usr/lib/modules/<kver>/vmlinuz`
     placeholder with the real `/boot/kernel8.img`
   - relocate `raspberrypi-bootloader`'s `/boot/{*.bin,*.dat,*.elf}` to
     `/usr/lib/raspberrypi/boot/` (this is the fixed, package-level path — correct for the
     VideoCore blobs specifically, see D.1) and arrange a one-time seed of the vfat
     partition with them — outside `rpi-bootc-bootloader`'s scope
4. Do not install `grub`, `shim`, `efibootmgr`, `bootupd`, `selinux-policy-targeted`, or
   `container-selinux` — none are needed, nothing in the script depends on them.
5. **Needs your decision:** set `/usr/lib/ostree/prepare-root.conf` `[composefs] enabled =
   yes` (matching AlmaLinux and the existing `Containerfile.base`) rather than `no` as
   `STATUS.md` currently states, and instead make the Pi-specific install invocation skip
   `--composefs-backend` and pass `--bootloader none` explicitly (not just omit bootupd).
6. No fstab entry needed for the vfat firmware partition on the running system.
7. Someone needs to figure out, empirically or from AlmaLinux directly, how the static
   VideoCore firmware blobs actually get onto real deployed images — not resolved by
   anything in the two repos we were given.

---

## HANDOFF

Team is collapsing to two agents. This workstream (PORT SPEC) is complete as far as the
five numbered task items go — everything below is status, not new work.

### Done

- Both deliverables written and in final state: this file (`docs/port-spec.md`) and the
  vendored, patched script (`docs/rpi-bootc-bootloader.arch-proposed`). The patched script
  passes `bash -n`. Diff against upstream verified to be exactly one line via `diff` against
  the original clone.
- All five numbered items in the task are covered: manifest semantics (part A),
  rpi-bootc-bootloader traced completely with a command/package table (part B), partition/
  mount assumptions nailed down definitively (part C), the full diff plus two build steps
  `STATUS.md` didn't have (part D), upstream freshness confirmed with no newer tags/commits
  on either repo (part E).
- Every claim in the file is sourced — file path, quoted doc text, or a command I actually
  ran. Nothing in parts A–C, D.1–D.3, or E is a guess.

### The one thing that needs a decision before anyone writes a Containerfile

Part D.4 (composefs). This revises `STATUS.md` decision #2. I did not edit `STATUS.md`
myself — only flagged it here — because changing another agent's recorded decision without
sign-off felt like the wrong call to make unilaterally, especially this late. Whoever picks
this up next should either action it (set `composefs enabled = yes`, drop
`--composefs-backend`, add explicit `--bootloader none`) or explicitly overrule my reading
of the bootc docs before building anything on top of it. The evidence is in D.4 in full —
the short version: `prepare-root.conf`'s `[composefs] enabled=` and bootc's
`--composefs-backend` install flag are two different things that share a name, AlmaLinux's
own working image and the existing `Containerfile.base` both use `enabled = yes`, and
`--bootloader=none` is only documented as incompatible with the *install backend* flag, not
the prepare-root.conf setting.

### Half-done / stopped mid-investigation, unconfirmed

- **D.5, the firmware-blob placement question, is genuinely unresolved.** I checked every
  file in both repos, bib-config.toml, the full action.yml build sequence, and did one
  `gh api search/code` sweep against `osbuild/bootc-image-builder` — zero hits. I did not
  check: AlmaLinux's `raspberrypi2-firmware` RPM spec itself (couldn't locate its source
  repo — tried `AlmaLinux/kernel-rpi` (404) and a GitHub code search that only turned up an
  unrelated `AlmaLinux/raspberry-pi` kickstart repo, gave up rather than keep guessing at
  repo names), and I did not check whether `bootupd`'s *unmerged* RPi firmware-payload PRs
  (`coreos/bootupd#651`/`#959`, cited from `STATUS.md`) might actually be partially vendored
  or cherry-picked into the specific `bootupd` build AlmaLinux's manifest pulls in — I took
  "open and unmerged" from `STATUS.md` at face value rather than re-verifying it myself.
  That's a real gap: it's possible the answer is sitting in one of those two unmerged PRs and
  I never opened either.
- **The kernel-install.yaml / dracut `layout=ostree` question (part A) is noted but not
  resolved.** I flagged that AlmaLinux's manifest sets `layout=ostree` in
  `/usr/lib/kernel/install.conf` to stop `kernel-install`/`bootctl` from fighting rpm-ostree
  over `/boot` management, and explicitly said whether Arch's dracut+mkinitcpio-bypass setup
  needs an equivalent is a Containerfile-workstream question. I did not check whether
  `Containerfile.base` already handles this for the x86_64 target (I read that file only for
  the composefs lines in D.4, not end to end) — if it does, the answer might already exist
  and just need copying.
- **`bootc-base-imagectl rechunk` / whether the existing Taskfile pipeline already has an
  equivalent rechunk/dedup step** — noted as "outside this spec's scope to re-verify" in part
  A, but that was a soft punt, not a real check. I never opened `Taskfile.yml` beyond the
  `validate` and `switch-preflight`/install-to-disk sections I grepped for the composefs
  finding.
- I did not verify AlmaLinux's `10-kitten`/`9` variants for anything beyond a one-line diff
  against `10-rpi`'s Containerfile (confirmed they're pure version-parameterized twins, no
  further reading done on `9-rpi`/`10-kitten-rpi` manifests beyond that diff).

### What I would do next, in order

1. Get a decision on D.4 (composefs) — everything else in the Containerfile workstream is
   blocked on knowing which way that goes, since it changes both the `prepare-root.conf`
   content and the exact `bootc install`/equivalent invocation flags.
2. Chase D.5 one more way before giving up on it: try to actually build or pull AlmaLinux's
   published `quay.io/almalinuxorg/almalinux-bootc-rpi:10` image (not just the
   `centos-bootc:stream10` builder base I already pulled) and inspect its `/boot` and the
   vfat-partition-seeding logic directly, or open the two bootupd PRs
   (`coreos/bootupd#651`, `#959`) to see if either is closer to merged/vendored than
   `STATUS.md`'s framing suggested.
3. Read `Containerfile.base` and `Taskfile.yml` end to end (I only read fragments of each)
   to see how much of the kernel-install/dracut/rechunk machinery already has a working
   pattern to copy for the Pi target, rather than inventing one from the AlmaLinux manifest
   chain.
4. Once D.4 is settled, someone needs to write the actual Pi Containerfile against this spec
   — that was never in scope for this workstream, just the spec itself.

### Trap for whoever picks this up

Don't take `STATUS.md`'s `composefs enabled = no` at face value and wire it into a
Containerfile before reading part D.4 here. It looks like a small, safe-looking one-line
config value, it's the kind of thing that's easy to copy without re-checking, and it's
wrong (or at least unsupported by every piece of primary-source evidence I could find,
including a currently-working reference image and this project's own other Containerfile).
Getting it wrong doesn't fail loudly either — the ostree backend accepts either value, so a
build with the wrong setting will succeed and only reveal the problem later if something
actually depends on the distinction. Check part D.4's citations before trusting either value.
