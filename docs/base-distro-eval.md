# Base distro challenge: stress-testing the Arch/ALARM call

Scope: re-examine the provisional Arch-via-ALARM base decision against real evidence,
harvest whatever's reusable from `bootcrew/mono`, score the realistic alternatives, and
give a straight recommendation. This does not touch any Containerfile. Read alongside
`STATUS.md`, which records the decision this eval is checking.

Evidence gathering used live sources checked on 2026-09-11: the ALARM aarch64 package
databases (fetched directly, not summarized secondhand), `gh api`/`gh run`/`gh issue`
against the real repos, `skopeo inspect --raw` against the real registries, and web
research cross-checked against primary sources rather than blog summaries. Where a claim
below could not be independently verified this way, it says so.

## Scoring table

| Candidate | Pi kernel | ostree/bootc packaged | aarch64 OCI base image | Custom plumbing left | Verdict |
| --- | --- | --- | --- | --- | --- |
| Arch / ALARM | `linux-rpi` 6.18.50-1, built 2 days before check, actively maintained | ostree yes, bootc: build from source (not packaged anywhere on any candidate) | None. ALARM ships tarballs only | dtb relocation, own OCI bootstrap, own boot hook fork | Feasible, more of the port is ours to own |
| AlmaLinux (consume `bootc-images-rpi`) | `raspberrypi2-kernel4` etc., AlmaLinux's own RPM rebuild | Both packaged, current, official (`quay.io/centos-bootc/centos-bootc:stream10`) | Yes, multi-arch incl. arm64, verified live | Small: re-point at our repo layout, absorb their debt | Real head start, but the debt is real too |
| Debian/Ubuntu via bootcrew | Ubuntu: `linux-raspi` in main, mature. Debian: no dedicated flavor, arm64 kernel carries Pi dtbs incidentally, whole Pi pipeline mid-rewrite (GSoC 2025) | Neither packaged; bootcrew builds bootc from git HEAD, currently broken | Yes for both (official multi-arch images) | Everything Pi-specific: no firmware sync hook, no os_prefix work, wrong bootc backend (composefs) in bootcrew's own scripts | Kernel/base fine, zero Pi-boot reuse |
| Fedora | No official Pi kernel; one solo-maintainer COPR, one Fedora ARM lead's personal experimental build (SD-card-boot only, incomplete as of last post) | Both native and current, official multi-arch `quay.io/fedora/fedora-bootc` | Yes, verified live | Heavy: kernel and native-firmware boot are the two unsolved pieces, and every attempt found uses a UEFI/bootupd hack instead | Good plumbing, no working Pi5 story |
| CentOS Stream 10 | None of its own — Pi kernel work in the RHEL family is entirely AlmaLinux's separate project | Both packaged, current, official multi-arch base (same image AlmaLinux builds from) | Yes, verified live via `skopeo inspect` | Everything Pi-specific, or just become AlmaLinux | Not a distinct option from AlmaLinux in practice |
| openSUSE MicroOS | Better than expected: mainline kernel plus two SUSE-employee-maintained packages (`raspberrypi-firmware-dt`, `raspberrypi-firmware`), both patched within the last three months | dracut wired at the spec level (standard upstream `51ostree` module) but no field report of it working end to end. `bootc` 1.15.2 does exist as a package, in the `Virtualization:containers` devel project, Tumbleweed-only, not in Factory proper, and fails to resolve on Leap/Leap Micro | Tumbleweed image verified live, multi-arch incl. arm64. No MicroOS-specific image exists (`opensuse/microos` 404s) | Real Pi5 support ships today, but via U-Boot -> GRUB2 -> UEFI (SUSE's own Nov 2025 announcement), the opposite of this project's native-firmware decision. Zero os_prefix precedent anywhere in openSUSE | Substrate is more solid than it first looks, boot integration is still a from-scratch job |
| Alpine | `linux-rpi` well maintained, but tied to `mkinitfs`, not dracut | ostree packaged but solves Flatpak's problem, not host deployment; bootc not packaged anywhere, no aport, no precedent | Multi-arch official image, but none of systemd/ostree/bootc/dracut in it | Would mean building bootc against musl+OpenRC from zero, no reference anywhere | Rule out. bootc needs systemd; Alpine deliberately doesn't ship it |

## What bootcrew/mono actually is

Cloned and read in full: 4 Containerfiles, all 6 shared/CI files, all 6 GitHub workflows,
17 commits of history, and the live CI run history and issue tracker via `gh`.

It is not Pi-specific at all. `arch/`, `debian/`, `ubuntu/`, `opensuse/` each produce a
generic bootc base image meant for VMs or cloud, not for any single-board computer. None
of the four Containerfiles mention Raspberry Pi, `config.txt`, dtbs, or firmware. This
matters: it's the shared plumbing pattern that's reusable, not distro-specific Pi
knowledge, because there isn't any.

Per-directory, checked with `git log --follow` and against upstream base image manifests:

- **arch/**: builds `FROM docker.io/archlinux/archlinux:latest`, which is a single-arch
  amd64 manifest (confirmed live via `skopeo inspect --raw`, image built the day before
  this check). The build workflow is literally named "Build ArchLinux (amd64-only)" —
  bootcrew's own maintainers already hit the same wall STATUS.md records. Nothing here
  builds for aarch64, so it's the closest of the four to what we're doing conceptually,
  but it answers none of the Pi questions.
- **debian/**: `FROM docker.io/library/debian:unstable`, genuinely multi-arch including
  arm64 (verified live). CI builds amd64+arm64. Uses `linux-image-generic`, a cloud
  kernel with no Pi dtbs or overlays.
- **ubuntu/**: same shape, `FROM docker.io/library/ubuntu:questing`, multi-arch, generic
  kernel.
- **opensuse/**: `FROM registry.opensuse.org/opensuse/tumbleweed:latest` (Tumbleweed, not
  MicroOS), multi-arch, generic `kernel-default`.

Last real commit touching any of the four distro directories: 2026-05-08, four months
before this check. CI infra saw a later touch (2026-07-27, Ubuntu 26.04 bump). Total repo
history is 17 commits since a 2026-03-19 init; contributors are mostly one person
(`Tulip Blossom`, 11 of 17 commits), with Colin Walters (an actual ostree/bootc/
rpm-ostree upstream maintainer) among the other three. Small, young, not abandoned, but
not a mature reference either.

Live CI as of today is red for three of four targets. Daily scheduled runs on `main` for
Build ArchLinux, Build Debian, and Build Ubuntu have failed every day since at least
2026-09-08; only Build OpenSUSE Tumbleweed passes consistently. Root cause, traced
through the actual failed-job logs: `shared/build.sh` clones `bootc-dev/bootc` from git
`HEAD` with no version pin and builds it fresh every run. A recent upstream bootc commit
added a `selinux-sys` build dependency that needs `libselinux` headers; Arch's builder
stage doesn't install them (build fails outright) and even Debian's build, which does
install `libselinux-dev`, still fails at the same step (a `selinux-sys` build-script bug
independent of distro). A PR that would have pinned bootc to a fixed release
(`feat/ubuntu-26.04-lts`, "pinned bootc v1.15.2") was opened and then closed without
merging, which is exactly the kind of fix that would have prevented this outage. Worth
knowing regardless of base distro: building bootc unpinned from upstream `HEAD` is
fragile in a way that isn't specific to any one distro's packaging.

Beyond that, even when the container image builds, converting it to a bootable disk
image doesn't reliably work: an open issue (`disk-image build of OpenSuse fails`,
2026-08-07) shows the OpenSUSE container image building cleanly but the `bootc install
to-disk` step failing on a composefs/splitstream error, and a similar issue exists for
Ubuntu (`just disk-image` failing with a podman runroot error). None of the four
directories currently produce a verified bootable disk artifact end to end.

One structural point that matters for reuse regardless of distro: `shared/bootc-rootfs.sh`
sets `[composefs] enabled = yes` and every distro's `Justfile` disk-image recipe passes
`--bootloader systemd`. That's the opposite backend and bootloader from what this project
decided on (`STATUS.md`: ostree backend, composefs disabled, no systemd-boot). Any reuse
of `shared/bootc-rootfs.sh` or `shared/initramfs.sh` for a Pi variant means forking that
one file, not using it as-is.

### What's actually worth harvesting

- The four-stage Containerfile pattern (`ctx` scratch stage carrying `shared/` in,
  `builder` stage, `system` stage, final `bootc container lint`) is a clean shape worth
  copying regardless of base distro.
- `shared/initramfs.sh`'s dracut config is directly useful: it sets
  `systemdsystemconfdir`/`systemdsystemunitdir` so dracut's bootc module finds the right
  paths inside a container build (not a running system), and forces
  `add_dracutmodules+=" bootc "`. Small, correct, worth lifting close to verbatim.
- `shared/bootc-rootfs.sh`'s directory-symlink and tmpfiles-based `/var` layout
  (`/home`, `/srv`, `/opt`, `/mnt`, `/usr/local` all symlinked into `/var`, recreated via
  `/usr/lib/tmpfiles.d/bootc-base-dirs.conf`) is boilerplate every bootc image needs and
  is worth copying, minus the composefs line.
- The bcvk-based CI pattern (`bcvk ephemeral run-ssh`, `check` recipe asserting no failed
  systemd units) is a reasonable boot-smoke-test shape, though it only tests amd64 in CI
  even for the arm64-built images — arm64 boot is never actually exercised by bootcrew's
  own pipeline.
- Nothing Pi-specific exists to harvest, because bootcrew/mono doesn't target Pi at all.

A closer look at openSUSE is worth a paragraph since it came out better than the first
pass suggested. The kernel/firmware substrate is genuinely current: `kernel-default` is
mainline (no downstream fork needed), and `raspberrypi-firmware-dt` (Pi5/bcm2712 dtb
overlays) and `raspberrypi-firmware` (VideoCore blobs and EEPROM) are both maintained by
named SUSE employees with patches inside the last three months. `bootc` 1.15.2 is also
genuinely packaged, just not where it looks: it lives in the `Virtualization:containers`
devel OBS project, builds only for Tumbleweed, and fails to resolve against Leap or Leap
Micro's older `libostree`. None of that changes the boot-mechanism problem: openSUSE's
only shipped ostree bootloader backend is `ostree-grub2`, requiring UEFI, and SUSE's own
Pi5 announcement confirms they chose U-Boot -> GRUB2 over native firmware boot, same as
the route this project already rejected for ALARM's `uboot-raspberrypi`. So openSUSE has
better raw material than expected and zero os_prefix precedent, same as everyone except
AlmaLinux.

## Stress-testing the specific ALARM risks

**"Effectively one maintainer."** Overstated as literally one person, directionally
right as a concentration-of-leadership risk. Kevin Mihelich is the lead and dominant
committer on `archlinuxarm/PKGBUILDs`, committing daily through today, with two other
named contributors active alongside him (`graysky` on kernel/bootloader packages,
`davidbeauchamp` elsewhere). The forum is alive (posts in the Packages and ARMv8 boards
within the last week). But Arch's own developers describe ALARM as a loosely coupled
side project, not an official port: a 2025-01 Arch forum thread has a poster noting
ALARM's own devs aren't interested in becoming an official Arch port, and an Arch
developer posted in 2025-09 that a separate, uncoordinated `archlinux-ports` aarch64
effort is underway on IRC. Bus factor is thin and Arch-proper is drifting away from
ALARM rather than toward it, even if "one person" isn't literally true today.

**Toolchain lag.** Confirmed directly, not secondhand. Pulled the live ALARM aarch64
`core.db` and extracted package metadata rather than trusting a summary: `glibc`
2.43+r22, built 2026-05-03; `gcc` 16.1.1+r12, same build date. Compared against this
build host's own x86_64 Arch packages via `pacman -Si`: `glibc` 2.44+r24, built
2026-08-11; `gcc` 16.2.1+r23, same date. That's 100 days and one point release behind on
both, which matches the number in the brief closely. Critically, it's not general
staleness: `systemd` (261.2-1), `ostree` (2026.4-1), and `dracut` (111-1) are
byte-identical versions on both architectures, built the same day. The lag is specific to
the toolchain rebuild cadence, not the whole package set, and it's chronic rather than a
one-off: an ALARM forum thread from 2023-10 shows an Arch developer (not ALARM staff)
acknowledging the exact same pattern with glibc three point-releases behind at the time,
calling it something that's "been like this for a very long time" with no known cause.
This is a narrower, more defensible risk than "ALARM is behind," but it is real and it
recurs.

**Collabora Holo Core.** Real, but doesn't change the calculus. Announced 2026-07-17 as
a from-scratch aarch64 rebuild of upstream Arch, built for Valve's Steam Frame headset,
not ALARM-derived and not targeting Raspberry Pi or general aarch64 hardware. It's not
ostree- or bootc-based either; it ships binary packages and dev containers. Collabora
says they intend to eventually upstream the work to Arch proper, and their approach
(replaying Arch's build history to resolve a rolling-release aarch64 rebuild from
scratch) is solving the same underlying problem ALARM struggles with, just for a single
device. Worth watching, not usable today: no Pi target, no public package repo, tooling
explicitly not yet published.

**Has anyone shipped ALARM + ostree or ALARM + bootc?** No. Checked forum search,
GitHub, and the open bootc tracking issue for exactly this. What exists all targets
generic x86_64 Arch, not ALARM: `M1cha/archlinux-ostree` (GRUB2-oriented, single
developer, 29 commits) and its companion `M1cha/bootc-archlinux`, which is a one-commit
WIP that's actually broken (an open ostree deploy error). `tulilirockz/arch-bootc`, the
predecessor to bootcrew/mono's `arch/` directory, was the most mature of the bunch (54
commits, 101 stars) and got archived into the monorepo in March 2026. The upstream bootc
tracking issue for "demonstrate a debian or arch base image"
(`bootc-dev/bootc#865`) has been open since November 2024 with no real progress. Nobody
has combined ALARM specifically with ostree or bootc, on a Pi or anywhere else. This
project would be first.

**First-party OCI image.** Confirmed none exists. ALARM's downloads page offers rootfs
tarballs only, signed but not containerized. No `archlinuxarm` presence on Docker Hub or
ghcr.io. Third-party unofficial aarch64 Arch images exist (`agners/archlinuxarm-docker`,
`fwcd/docker-archlinux`, others) but using one means taking on an additional, unrelated
trust and maintenance dependency on top of the toolchain-lag risk, so bootstrapping from
the official tarball (as already planned) is the right call regardless.

## What the AlmaLinux reference architecture actually looks like up close

Read `AlmaLinux/bootc-images-rpi`'s `Containerfile` and `kernel.yaml` directly, and
checked the repo's real state via `gh api` rather than trusting the README.

It's `FROM quay.io/centos-bootc/centos-bootc:stream10` (confirmed live and genuinely
multi-arch: amd64, arm64, ppc64le, s390x) with AlmaLinux's own repo config swapped in,
their own `raspberrypi2-kernel4`/`raspberrypi2-firmware` RPMs installed (a package family
AlmaLinux maintains itself in a separate `AlmaLinux/raspberry-pi` project — this is not
something CentOS Stream or Red Hat ship), and, critically, the native-firmware boot hook
is not vendored: the Containerfile `curl`s `kfox1111/rpi-bootc-bootloader`'s script and
systemd drop-in straight from GitHub raw at tag `v0.0.8` on every build. That's a live
network dependency on one person's six-month-old, zero-open-issue, effectively
zero-external-adoption (1 star) repository, cut through 25 commits over a nine-day window
in February 2026 with commit messages like "fix logic" and "fix typo" right up to the
tag. Nothing about `v0.0.8` signals stability beyond it being the last tag cut; it reads
as "stopped touching it," not "hardened."

`bootc-images-rpi` itself: last push 2026-04-09, five months before this check. Commit
history is bursty — a cluster of activity in February 2026 (when RPi5 D0-revision
hardware support landed and a real breaking bug for that hardware was found and fixed,
issue #20), then almost nothing since. 7 people have contributed commits total (not one),
but the overwhelming majority (74 of roughly 100 commits) are Kevin Fox's. 4 open issues,
one from a third party asking about Compute Module 5 support (unanswered since December).
CI is green and has been for a while (500+ runs). The README says outright: "AlmaLinux
bootc images are currently experimental... Not much tuning has been done yet to minimize
writes, so cheap flash usb drives or sd cards can be used up fast." That's the
maintainer's own characterization, not an outside critique.

Net read: this is real, it works (there's a closed Pi5-specific hardware bug to prove
someone tested on actual Pi5 boards), and it's the only working example anywhere of
native-firmware bootc boot on a Pi. It is also young, single-org, mostly single-author,
self-labeled experimental, stalled for five months, and depends at build time on a
0.0.x-versioned script fetched over the network from an even smaller one-person repo.
Building on it means inheriting all of that, not just the parts that work.

## Wider bootc-on-Pi ecosystem: how solved is this, really

Not solved, and not common. Every primary source that discusses it in public
self-describes as experimental. Fedora's community attempts
(`ondrejbudai/fedora-bootc-raspi`, `renner0e/fedora-pi-bootc`) explicitly patch
`bootupd` to fake a UEFI-shaped boot path under `/boot/efi` rather than using native
firmware boot — one's README says outright "horrible hacks are included" and that
firmware/bootloader updates are broken by that approach. A dedicated
`mrguitar/fedora-rpi5-bootc` repo has sat untouched since February 2025 with an explicit
"does not yet yield a working image" banner. Fedora's own ARM lead (Peter Robinson) has
real, more recent momentum on native Fedora-on-Pi5 (posts through March 2026 describing a
usable desktop image), but that work is not bootc-based and doesn't touch the
container-image deployment model at all. No FOSDEM or DevConf 2026 talk on bootc-and-Pi
was found. Canonical's own Pi5 A/B boot work (`piboot-try`, shipping since Ubuntu 25.10)
is a real rollback mechanism but is not bootc, not container-based, and unrelated to this
project's approach. The honest summary: this project would sit at the front of a very
small pack, not behind an established path.

## Cost estimates

All three assume the boot architecture already decided in `STATUS.md` (native firmware,
ostree backend, dracut) stays fixed, and that Pi hardware becomes available partway
through for real boot testing. Estimates are for reaching a first Pi5 boot with working
`bootc upgrade`/rollback, not full production hardening.

**(i) Arch/ALARM plus our own plumbing.** 12-16 engineer-days. Breakdown: OCI bootstrap
from the ALARM tarball and pacman-database-in-/usr rework, similar to what
`bootcrew/mono`'s `arch/Containerfile` already does for x86_64 (1-2 days, mostly
adaptation); dtb relocation from `/boot` to `/usr` and matching `DTB_SRC` change in a
vendored copy of the sync hook (1-2 days); porting `rpi-bootc-bootloader` itself, since
there's no existing ALARM+ostree+bootc example to copy and the hook's assumptions
(RPM-kernel dtb globs, `/boot/loader/entries` layout) need re-verifying against Arch's
own layout (2-3 days); dracut/mkinitcpio-hook masking, matching the existing
`Containerfile.base` pattern (1 day); build-host cross-compile plumbing for bootc under
qemu-user, per the known SIGILL/SIGSEGV rule already documented (1-2 days); first boot,
debug, rollback test cycle once hardware is reachable (3-4 days, historically where most
of the AlmaLinux project's real time went by their own commit pattern); buffer for the
toolchain-lag class of surprise, e.g. a glibc/gcc mismatch tripping something in the
cross-build (2 days). This is the most expensive option and the risk is open-ended in the
sense that nobody has hit these exact walls before us.

**(ii) Start from AlmaLinux's `bootc-images-rpi` and layer on top.** 4-6 engineer-days.
Breakdown: fork and re-point at our repo layout and registry (0.5 day); vendor
`rpi-bootc-bootloader` instead of curling it at build time, since depending on live
GitHub raw content in a production build pipeline is not something to keep long-term
regardless of distro (0.5 day); swap AlmaLinux branding/repos for our own package set and
users (1 day); adapt to this repo's `Containerfile.pc`-sibling structure and Taskfile
conventions per the team brief (1 day); real hardware boot/rollback verification (1-2
days, lower than option (i) because the boot chain is already known-working on Pi5); SD
card wear tuning, since the maintainers themselves flag this as unaddressed (1 day,
optional depending on how much we care before hardware ships). Cheapest and lowest-risk
path to a working image. The cost is inheriting AlmaLinux's toolchain (glibc/RHEL
userspace instead of Arch) and its experimental, five-months-stale, single-org
dependency chain, which is a different flavor of risk than ALARM's, not necessarily a
smaller one.

**(iii) Debian or Ubuntu via bootcrew.** 14-18 engineer-days, and this is the option most
likely to blow its estimate. Breakdown: fix bootcrew's currently-broken unpinned bootc
build or pin it ourselves (0.5-1 day, small but blocking); fork `shared/bootc-rootfs.sh`
to flip composefs off and drop the systemd-boot assumption, since bootcrew's default
config is the wrong backend for this project's boot decision (1 day); swap the generic
kernel for a real Pi-capable one — straightforward for Ubuntu (`linux-raspi` is in main
and mature), materially harder for Debian, which has no dedicated Pi kernel flavor and
whose Pi image tooling is itself mid-rewrite as of a 2025 GSoC project scoped around
exactly that gap (0.5 day Ubuntu / 3-4 days Debian, meaning Ubuntu should be preferred
over Debian if this option is chosen at all); write the entire native-firmware sync hook
from scratch, since nothing in this ecosystem does that for Debian or Ubuntu — every
existing bootc-on-Pi example that isn't AlmaLinux's uses the UEFI/bootupd hack style
instead, so there's no adaptation to do, only a fresh build (4-5 days, roughly what
option (i)'s equivalent step costs, because it's the same problem with even less prior
art); dtb/firmware placement work equivalent to the Arch gap (1-2 days); first-boot and
rollback verification (3-4 days). This option pays the full cost of writing the
Pi-firmware boot mechanism from scratch, same as Arch, while adding bootcrew's currently
broken and behind-our-architecture tooling on top. It does not deserve its apparent
head-start reputation once the Containerfiles are actually read.

## Recommendation

Stay with Arch via ALARM, but go in with eyes open about what that costs, and revisit if
the hardware testing phase turns up problems the AlmaLinux precedent didn't have to face
because it's on a different toolchain.

The honest case against Arch is real: zero precedent for ALARM+ostree+bootc anywhere,
zero first-party OCI image, a confirmed and chronic toolchain lag, and a genuinely
options-cheapest path sitting right next to it in AlmaLinux's repo. If the goal were
"working Pi5 bootc image, fastest, least risk," AlmaLinux's route wins outright at
roughly a third of the engineer-days and it's the only path anyone has actually gotten to
boot on real Pi5 hardware.

But that's not quite the question this project is answering. The existing x86_64 image
this Pi target is meant to sit beside is already Arch (`Containerfile.base`,
`Containerfile.pc`), and the stated goal is a sibling image, not a second, differently-
built system living in the same fleet. Taking option (ii) solves the Pi problem cheaply
and creates a second problem: two unrelated base distros, two package managers, two
update cadences, in what's supposed to be one coherent bootc fleet. That's a real
maintenance cost this estimate doesn't capture in engineer-days because it's ongoing, not
one-time.

None of the ALARM-specific risks are disqualifying on their own. The toolchain lag is
real but narrow (compiler cadence, not general staleness) and an appliance image rebuilt
periodically absorbs a 100-day lag without much drama. The "one maintainer" framing is
overstated; there's a small but real team and a live forum. The lack of precedent is the
one that should sit with Prasanth as a genuine unknown, not a resolved risk: this project
will be the first to combine ALARM with ostree and bootc, and the AlmaLinux project's own
five-month stall and 0.0.x-versioned dependency on a single external script show that
even the working example in this space is thin ice, not a paved road.

Given the existing sibling image is Arch and Prasanth's stated preference, option (i) is
the right call, sized at 12-16 days with the understanding that the buffer at the end of
that estimate is not padding, it's the realistic cost of being first. If the first real
hardware boot attempt surfaces a wall specific to ALARM (not a general Pi bootc problem,
which option (ii) would hit too), that's the moment to seriously reconsider (ii) rather
than push through, since AlmaLinux's repo would still be sitting there as a working
fallback with less sunk cost than doubling down blind.

## Harvested from bootcrew, worth pulling into the Arch build regardless

- The `ctx`-scratch-stage-plus-`shared/` pattern for sharing build scripts across a
  Containerfile without a separate context directory.
- `shared/initramfs.sh`'s dracut container-build config (the `systemdsystemconfdir`/
  `systemdsystemunitdir` overrides and the `add_dracutmodules+=" bootc "` line) — small,
  correct, directly portable.
- The `/var`-symlink-and-tmpfiles layout from `shared/bootc-rootfs.sh`, with the
  composefs line removed to match this project's ostree-backend decision.
- The bcvk-based `check`/`ephemeral` CI pattern for automated boot smoke tests, noting
  its current gap: it never actually boot-tests arm64 images even when it builds them.
- Not harvested: anything Pi-specific, because none exists in this repo; the four
  Containerfiles target generic cloud/VM bootc, not any single-board computer.

## Blockers

None blocking a decision. Pi5 hardware is still not network-reachable (per STATUS.md
Phase 2), so nothing above has been validated against this project's actual board yet;
every ALARM-specific claim here rests on package-database and repository evidence, not a
boot test. That first real boot is the point where the ALARM-vs-AlmaLinux call gets its
first hard data instead of inference from precedent.
