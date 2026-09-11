# Kernel choice for the Pi 5: ALARM's `linux-rpi`, verified

Debian trixie was parked before `docs/debian-bootc.md` got written, so there is nothing
to mark abandoned there. One line for the record: the reason Debian looked attractive
was a weak-Pi5-kernel worry about Arch. That worry doesn't survive contact with evidence
(below), and trixie stable ships Linux 6.12 with no Pi 5 support at all (Debian's own
wiki: "we cannot plan for including RPi5 support at least until regular, upstream,
mainline Linux kernels are able to boot on it"), so Debian would have been a downgrade,
not a hedge.

Scope of this doc: is ALARM's `linux-rpi` current and trustworthy, and does it cover
what a bootc/ostree container-host appliance needs. Read alongside `docs/kernel-layout.md`
(package manifests, dtb/firmware relocation) and `docs/base-distro-eval.md` (why Arch over
other distros generally) — this doc doesn't repeat either.

## Verdict

Use ALARM's `linux-rpi` package as-is. Don't build our own kernel.

It tracks the Raspberry Pi Foundation's own downstream fork (`raspberrypi/linux`) on the
branch that fork's maintainers themselves call `rpi-6.18.y` and keep as the repo's default
branch, ALARM rebuilds it every few days, the diff against ALARM's generic aarch64 kernel
is a single four-line patch, and the config already carries everything podman/k3s need.
Building from source would mean owning kernel builds forever for a package that's already
this close to upstream with this little Arch-specific delta.

## 1. What ALARM's `linux-rpi` 6.18.50-1 actually is

PKGBUILD (`archlinuxarm/PKGBUILDs`, `core/linux-rpi/PKGBUILD`) fetches source as:

```
linux-$pkgver-${_commit:0:10}.tar.gz::https://github.com/raspberrypi/linux/archive/${_commit}.tar.gz
```

commit `0ac97ba3443f519b61bbc96079736cd8b881ea22`, i.e. a pinned commit snapshot of the
Raspberry Pi Foundation's own downstream kernel fork, not a release tarball and not
mainline. `raspberrypi/linux`'s default branch, checked live, is `rpi-6.18.y`, last
updated 2026-09-10 — one day before this check, and one day after ALARM's own build
(2026-09-09). ALARM's commit history for this package (`git log core/linux-rpi`) shows a
bump roughly every 3-9 days going back through July: `6.18.38-3` on Jul 16 up through
`6.18.50-1` on Sep 9, ten bumps in eight weeks, all by the same maintainer (`graysky`).
This is a live-tracked package, not a stale fork.

Patch set: exactly one, `0001-Make-proc-cpuinfo-consistent-on-arm64-and-arm.patch`
(normalizes `lscpu` output between armv7h and aarch64 builds — cosmetic, not functional).
No other patches. ALARM is not carrying its own driver forks or quirks on top of
Raspberry Pi's tree.

Config: `make bcm2711_defconfig` (the shared Broadcom-family defconfig; aarch64 build
target is `config8`/`Image`/`kernel8.img`), then ALARM's `archarm.diffconfig` is applied
via `scripts/config`, then `make olddefconfig` resolves everything else to Kconfig
defaults and `select` dependencies. That build sequence matters for section 4 below.

## 2. Head-to-head

| Candidate | RP1 eth/USB | PCIe/NVMe | KMS/video | wifi/BT | IOMMU | Pages | ostree/dracut | Verdict |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| ALARM `linux-rpi` 6.18.50-1 (downstream, 4K) | Yes, native, years mature | Yes, `CONFIG_BLK_DEV_NVME=y`, mature EEPROM-boot feature since 2023 | Yes, downstream KMS/VC4 driver | Yes, via `firmware-raspberrypi` blobs | `CONFIG_BCM2712_IOMMU=y`, present and on | 4K | Both work, no gaps found | **Recommended** |
| ALARM `linux-rpi-16k` 6.18.50-1 (downstream, 16K) | Same as above | Same as above | Same as above | Same as above | Same | 16K | Same | Rejected per `kernel-layout.md` decision 1 (ELF alignment breakage on generic container images), unchanged by this doc |
| ALARM `linux-aarch64` 7.2.4-1 (mainline, generic) | No RP1 dtb/config at all; this is the generic aarch64 kernel, not Pi-targeted | Untested for Pi5 NVMe boot specifically | No Pi-specific KMS/overlay support | No Pi firmware wiring | Driver exists upstream but under review, not merged (see §3) | 4K | Would need a hand-built Pi5 dtb and manual driver enablement | Not a real candidate: it's not a Pi kernel, it's the vanilla ALARM package with zero Pi wiring |
| `raspberrypi/linux` built by us | Same coverage as ALARM's build, we'd just be rebuilding the same commit | Same | Same | Same | Same | Either | We'd own the dracut/config wiring ourselves, no functional gain | Rejected: identical result to ALARM's package at the cost of owning CI, cross-compile, and rebuild cadence ourselves |
| Vanilla mainline built by us | RP1 eth/USB landed only in 6.18, and even then with rev-1.1 caveats (§3) | Minimal boot support only (SD/UART); no confirmed Pi5 NVMe-boot validation | No Pi5-specific overlays; needs hand-authored dtb/config work | No native wiring, would need out-of-tree firmware loading | Driver under review, not merged | 4K, manual | Would work but every Pi-specific piece is DIY | Rejected: strictly worse coverage than downstream, for more of our own maintenance |

## 3. Checking the specific claims, one by one

**BCM2712 IOMMU "reportedly still unmerged."** True for mainline, irrelevant for us.
Daniel Drake's mainline IOMMU driver (adapted from Raspberry Pi's own downstream author,
Nick Hollinghurst) is confirmed still under review, not merged, as of this check
(Phoronix, and the driver's own list threads). But that's the wrong kernel to be worried
about: the downstream fork we actually build from has carried
`drivers/iommu/bcm2712-iommu.c` since at least `rpi-6.1.y`, and `bcm2711_defconfig` in
`rpi-6.18.y` sets `CONFIG_BCM2712_IOMMU=y` outright (confirmed by direct grep against the
raw defconfig, not an LLM summary — see method note below). **Overturned as a risk**: it
only applies to a kernel we're not using.

**Rev 1.1 device-tree panic.** Real, confirmed, and also mainline-only. A Raspberry Pi
Forums thread (`t=394796`) traces it precisely: mainline v6.18.0 is missing
`bcm2712-d-rpi-5-b.dts` (the D0/rev-1.1 device tree), so a rev 1.1 board fed the wrong DT
takes an "Asynchronous SError Interrupt" panic. A Raspberry Pi engineer confirms the fix
lands in mainline 6.19-rc1. The downstream fork never had this bug — it's had the D0 dtb
for multiple release cycles, which is exactly what `kernel-layout.md`'s package extraction
already confirmed independently (`bcm2712d0-rpi-5-b.dtb` present in both `linux-rpi` and
`linux-rpi-16k`, 26/8 dtb counts respectively). **Confirmed as description, overturned as
a concern**: it's a real mainline bug that simply doesn't reach the kernel we ship.

**NVMe boot "incomplete."** Not supported by evidence for the kernel we're using.
Raspberry Pi 5 NVMe boot (EEPROM-level PCIe boot support) has been an official, documented
Raspberry Pi Foundation feature since 2023, built on the downstream kernel, not mainline.
`bcm2711_defconfig` carries `CONFIG_BLK_DEV_NVME=y`, `CONFIG_NVME_HWMON=y`,
`CONFIG_PCI=y`, `CONFIG_PCIEPORTBUS=y` outright. The one concrete "Pi 5 NVMe boot kernel
panic" report found (Raspberry Pi Forums `t=388353`) turned out to be an Ubuntu-specific
`update-initramfs` misconfiguration after switching root devices, fixed by rebuilding the
initramfs — not a kernel or driver gap, and not applicable to us since we build the
initramfs with dracut and `hostonly=no` rather than Ubuntu's `update-initramfs` tooling.
**Overturned**: no evidence NVMe boot is incomplete on the kernel we're shipping.

Net: two of the three risks Prasanth flagged are real but only for mainline, which we
were never going to ship. Downstream — what ALARM actually packages — doesn't carry any
of them.

Method note on evidence quality: earlier passes in this doc used WebFetch's built-in
summarizer against raw GitHub config files and it silently dropped real lines (it first
reported "CONFIG_IOMMU not present" and "CONFIG_SECCOMP absent" against the same file that
a direct `curl` + `grep` showed differently, see below). Every config claim in this doc is
from `curl`+`grep` against the raw file, not the summarizer.

## 4. Container-host config check (cgroups, overlayfs, netfilter, seccomp, BPF)

Extracted `bcm2711_defconfig` from `raspberrypi/linux` at `rpi-6.18.y` (the exact defconfig
ALARM's PKGBUILD runs `make bcm2711_defconfig` against) plus ALARM's `archarm.diffconfig`,
both via direct download and `grep`, not summarization.

Present and correct in the base defconfig alone:

```
CONFIG_NAMESPACES=y          CONFIG_USER_NS=y
CONFIG_BLK_CGROUP=y          CONFIG_CGROUP_PIDS=y       CONFIG_CGROUP_FREEZER=y
CONFIG_CGROUP_DEVICE=y       CONFIG_CGROUP_CPUACCT=y    CONFIG_CGROUP_PERF=y
CONFIG_CGROUP_BPF=y          CONFIG_CGROUP_NET_PRIO=y
CONFIG_OVERLAY_FS=m          CONFIG_BRIDGE=m            CONFIG_VETH=m
CONFIG_BRIDGE_NETFILTER=m    CONFIG_BRIDGE_NF_EBTABLES=m (+ full ebtables module set)
CONFIG_BPF_SYSCALL=y         CONFIG_BPF_JIT=y           CONFIG_NET_CLS_BPF=y
CONFIG_BCM2712_IOMMU=y
```

ALARM's `archarm.diffconfig` adds on top:

```
CONFIG_IP_NF_NAT=m   CONFIG_IP6_NF_NAT=m   CONFIG_NETFILTER_XT_MATCH_CGROUP=m
CONFIG_NFT_BRIDGE_META=m   CONFIG_IP_NF_IPTABLES_LEGACY=m   CONFIG_IP6_NF_IPTABLES_LEGACY=m
CONFIG_IP_NF_RAW=m   CONFIG_IP6_NF_RAW=m   CONFIG_IP6_NF_SECURITY=m
CONFIG_SECURITY_LANDLOCK=y   CONFIG_LSM="landlock"
```

Two options — `CONFIG_SECCOMP` and `CONFIG_NF_NAT`/`CONFIG_NETFILTER_NETLINK` — don't
appear as an explicit line in either file. That's not a gap; it's how these particular
config files are maintained. Raspberry Pi's defconfigs are `savedefconfig`-minimized (1786
lines, not a full ~10k-line `.config`), meaning only settings that differ from Kconfig's
computed default are listed at all. The PKGBUILD's final build step is `make
olddefconfig`, which fills every unlisted option from its Kconfig default and resolves
`select` chains:

- `CONFIG_SECCOMP` defaults to `y` on arm64 unconditionally (`arch/arm64/Kconfig` selects
  `HAVE_ARCH_SECCOMP`/`HAVE_ARCH_SECCOMP_FILTER`, and `kernel/Kconfig` sets `SECCOMP`
  `default y` when that's present). This isn't a guess: every arm64 distro kernel in
  general use, including stock Raspberry Pi OS, ships seccomp on, which is why Docker and
  k3s already run on Raspberry Pi OS today without anyone patching this in.
- `CONFIG_IP_NF_NAT=m` (explicit in ALARM's diffconfig) Kconfig-`select`s `CONFIG_NF_NAT`
  and pulls in `CONFIG_NF_CONNTRACK`; `CONFIG_NF_TABLES` (needed by `CONFIG_NFT_BRIDGE_META`,
  also in the diffconfig) similarly selects `CONFIG_NETFILTER_NETLINK`. `olddefconfig`
  resolves these automatically at build time even though neither appears as its own line.

No PKGBUILD contribution needed here, and nothing feeds `alarmcontrib`. The honest
caveat: this is defconfig-plus-select-chain analysis, not a built `.config` inspected on
a booted Pi. If it matters before hardware arrives, the fast way to settle it for real is
`podman run --platform linux/arm64 archlinuxarm/... zcat /proc/config.gz` on an actual Pi
once one is reachable, or extracting the built kernel's `.config` from the package build
log. Flagging as open, not blocking.

## 5. Kernel cmdline / `os_prefix` boot chain: nothing downstream-specific found

No new requirement beyond what `kernel-layout.md` §5 already decided (`rootwait`,
`console=serial0,115200`, no hardcoded `root=`, kargs supplied via `/usr/lib/bootc/kargs.d/`
rather than a static cmdline). Checked specifically for known legacy Pi cmdline quirks
(`dwc_otg.lpm_enable=0`, `8250.nr_uarts=`, `smsc95xx.turbo_mode=`) — all are USB-gadget-era
Pi 3/4 workarounds for controllers the Pi 5's RP1 southbridge doesn't use; none apply here.
`linux-rpi`'s own stock `boot/cmdline.txt` (extracted in `kernel-layout.md`) carries none
of them either. Nothing to add.

## Blockers

Same one `kernel-layout.md` already flagged and still open: nothing here has run on real
hardware. Every claim in this doc is package/source/forum evidence, cross-checked where
possible, not a boot log. The container-host config caveat in §4 (Kconfig-default
reasoning vs. an inspected built `.config`) is the one item worth a five-minute check the
moment a Pi is reachable, ahead of anything else.

## HANDOFF

Team is collapsing to two agents; this is a stop-here writeup, not a finished workstream
closed out by choice.

**Done, and I'd stand behind it:**

- Verdict: use ALARM's `linux-rpi` 6.18.50-1 as-is, don't build our own kernel. Confirmed
  it tracks `raspberrypi/linux`'s own `rpi-6.18.y` default branch at a pinned commit, one
  day behind that branch's HEAD at build time, rebuilt every 3-9 days by one active
  maintainer, carrying exactly one cosmetic patch.
- Three of Prasanth's stated risks checked individually against real sources (§3): the
  rev 1.1 device-tree panic is real but mainline-only (fixed in mainline 6.19-rc1,
  downstream never had it); the BCM2712 IOMMU driver being unmerged is true for mainline
  only, irrelevant since downstream has shipped `CONFIG_BCM2712_IOMMU=y` since at least
  `rpi-6.1.y`; "NVMe boot incomplete" isn't supported by evidence for downstream — the one
  concrete NVMe-boot-panic report found was an Ubuntu `update-initramfs` bug, not a kernel
  gap, and doesn't apply to our dracut-based build.
- Container-host config check (§4) via direct `curl`+`grep` against the real defconfig +
  ALARM's diffconfig, not the WebFetch summarizer (which I caught silently dropping real
  lines mid-investigation — see the method note in §3, worth remembering as a trap in its
  own right). cgroups, namespaces, overlayfs, bridge/veth, BPF all explicitly present.
  Cmdline/`os_prefix` check (§5) turned up nothing downstream-specific beyond what
  `kernel-layout.md` already decided.

**Half-done / unconfirmed, flagged as such in the doc but worth restating plainly here:**

- §4's SECCOMP and NF_NAT/NETFILTER_NETLINK conclusions rest on Kconfig `default`/`select`
  reasoning (arm64 selects `HAVE_ARCH_SECCOMP` unconditionally; `IP_NF_NAT` selects
  `NF_NAT`; `NFT_BRIDGE_META` pulls in `NF_TABLES`→`NETFILTER_NETLINK`), not an inspected
  built `.config`. I'm confident in the reasoning and it matches universal real-world
  experience (Docker/k3s already run on stock Raspberry Pi OS), but nobody has actually
  run `zcat /proc/config.gz` against ALARM's shipped binary. This is the single fastest
  thing to check the moment a Pi is reachable — five minutes, not a research task.
- I did not measure the exact commit distance between ALARM's pinned commit
  (`0ac97ba3443f519b61bbc96079736cd8b881ea22`) and `rpi-6.18.y`'s HEAD in commits — only
  in calendar days (built 2026-09-09, branch touched 2026-09-10). Days-not-commits is what
  was asked for and what I delivered; if someone wants commit-count precision later, `git
  log --oneline <commit>..origin/rpi-6.18.y` in a real clone answers it directly.
- Never got to the `linux-rpi-16k` deep-dive beyond confirming it inherits the same
  downstream coverage as `linux-rpi` — not needed since `kernel-layout.md` already
  rejected 16k pages on ELF-alignment grounds and nothing here changes that call.

**What I'd do next, in order, if the workstream continued:**

1. The five-minute `/proc/config.gz` check above, first thing once a Pi is booted at all
   — it's the one place this doc's confidence is inference rather than direct evidence.
2. Nothing else in this doc is blocking. The real next step for the *project*, not this
   kernel-choice question specifically, is unchanged from `STATUS.md`: get a Pi on the
   network and attempt a real boot. This doc doesn't own that step.

**Trap for whoever picks this up:** don't trust WebFetch's page-summarizer for anything
where a missing line matters (kernel configs, package manifests, anything where absence
of a token is itself the finding). It hallucinated two false negatives in this session
(`CONFIG_IOMMU not present`, `CONFIG_SECCOMP absent`) against a file where direct
`curl | grep` showed the real picture was different or more nuanced. Every load-bearing
config claim in this doc was re-verified that way after I caught the discrepancy — but if
you're extending this doc, re-verify anything you inherit from an LLM-summarized fetch
before citing it as fact.

Debian: parked, nothing written to `docs/debian-bootc.md` before the pivot, so there's
nothing to clean up there. The one finding worth keeping from that dead-end (top of this
doc): Debian trixie stable ships Linux 6.12 with the Debian wiki's own team stating no
Pi 5 support is even planned until mainline itself can boot the board. Backports
(`linux-image-arm64` 7.1.8-1~bpo13+1 in `trixie-backports`, confirmed live) is far newer
and would likely work, but `raspi.debian.net`'s own FAQ still gates Pi 5 to Debian
testing/unstable, not stable+backports — that gap was never resolved before the pivot and
would be the first thing to chase if Debian ever comes back into scope.
