# Contributing Raspberry Pi 5 support back to Arch Linux ARM

Research only. Nothing opened, posted, or pushed. Evidence gathered 2026-09-11 against
live ALARM sources (website, forum, GitHub) plus Raspberry Pi's own forum and issue
trackers. Every claim below has a URL behind it.

## Bottom line

Raspberry Pi 5 is not an officially documented ALARM platform, but it is much closer to
being one than the team brief assumed. The kernel work is already done and already
merged into `archlinuxarm/PKGBUILDs` master. What's missing is entirely on the
documentation side: no `/platforms` page, no wiki page, and no single tested walkthrough
that ties the already-shipping packages into an install a stranger can follow. That is a
genuinely small gap, and it is one we can close with real evidence from two physical
boards, which is exactly the kind of contribution this project is positioned to make
well. The honest risk is not that the work gets rejected. It's that ALARM's
publishing layer for `/platforms` isn't self-service, so landing this depends on getting
the attention of one of two people rather than on the technical merits alone.

## What's actually missing

### Confirmed present (checked directly, not assumed)

`linux-rpi` and `linux-rpi-16k`, both 6.18.50-1, built 2026-09-09, ship
`bcm2712-rpi-5-b.dtb` and `bcm2712d0-rpi-5-b.dtb` (the D0-stepping dtb) — see
`kernellayout`'s extraction in `docs/kernel-layout.md`. `raspberrypi-bootloader`
20260907-1 carries `start4.elf`/`fixup4.dat`, the VideoCore firmware family BCM2712
reuses (there was never a `start5.elf`). `raspberrypi-utils` 20260904-1 provides
`vcmailbox` and `vcgencmd`, which our tryboot rollback design needs and which are
already packaged, not a gap at all.

Beyond that, and not something `kernellayout` was looking for: Pi 5 mainline-kernel
support landed in ALARM's `PKGBUILDs` master in June 2026. Nick Hainke
(PolynomialDivision) opened three PRs —
[#2202](https://github.com/archlinuxarm/PKGBUILDs/pull/2202),
[#2205](https://github.com/archlinuxarm/PKGBUILDs/pull/2205), and
[#2206](https://github.com/archlinuxarm/PKGBUILDs/pull/2206), the last one titled
"Raspberry Pi 5 mainline kernel." Maintainer graysky2 debugged it live against his own
hardware, hit and root-caused a boot panic, then wrote in the PR: *"I pulled this into
my branch to do a little reworking and updates. I won't merge the PR formally in the
github UI, but all of your commits have been cherry-picked and will appear in master
shortly,"* and posted five commit SHAs as proof. All five are real and in master today
(`ae05000`, `283233`, `ed070a7`, `e966c12`, `3389271`, dated 2026-06-15/18): a new
`alarm/raspberry-pi5-armstub` package (ARM trusted firmware stub, with C0 and D0
stepping variants), `raspberrypi-overlays` now provided by both `linux-rpi` and
`linux-rpi-16k`, and `core/linux-aarch64`'s PKGBUILD documents
`raspberry-pi5-armstub: NEEDED to boot RPi5 with linux-aarch64 mainline kernel` as an
optdepend. This PR shows as CLOSED on GitHub, not MERGED, because graysky2 cherry-picked
rather than clicked the merge button — anyone scanning PR state by the UI label alone
would miss that the work landed.

So there are two working boot paths on ALARM today, not zero:

Path A, downstream kernel, no U-Boot: install `linux-rpi` or `linux-rpi-16k` plus
`raspberrypi-bootloader`, remove `uboot-raspberrypi`, boot directly off VideoCore
firmware. graysky posted this exact recipe in the forum back in 2024
([RPi 5 support](https://archlinuxarm.org/forum/viewtopic.php?f=67&t=16869)):
*"Just be sure to install linux-rpi or linux-rpi-16k kernel as there is not yet
mainline support for rpi5b and the image ships with the incompatible kernel
(linux-aarch64)."* solskogen confirmed in the same thread: *"The Pi5 works very well
with ALARM."* This is also, not coincidentally, the exact mechanism our own bootc image
already committed to (native firmware boot, no U-Boot, no UEFI — locked in
`TEAM-BRIEF.md`). Validating this path for ALARM's platform page and validating it for
our own image is close to the same work.

Path B, mainline kernel with U-Boot: `linux-aarch64` plus the new
`raspberry-pi5-armstub` package, keeping the U-Boot chain that ALARM's existing Pi 3/4
aarch64 tarball already uses. This is the path graysky2 pulled into master in June 2026,
and it matches ALARM's standing platform-page template (which always offers a vendor
armv7 tarball and a mainline aarch64+U-Boot tarball as the two choices). As of early
2025 a different contributor, lategoodbye (self-identified as an "Ex-maintainer"),
warned in the [ALARM forum](https://archlinuxarm.org/forum/viewtopic.php?f=65&t=17194)
that mainline Pi 5 support was still immature — *"current support for Rpi 5 on Mainline
is just usable for Kernel developers... months before testable."* June 2026's merge is
more recent than that warning, so Path B may now be sound, but it hasn't been publicly
re-validated since.

### Confirmed missing

No `/platforms` entry: fetching
`https://archlinuxarm.org/platforms/armv8/broadcom/raspberry-pi-5` returns a plain 404,
and the master list at `https://archlinuxarm.org/platforms` lists only Pi 2, Pi 3, Pi 4,
and Pi Zero 2 under armv8/broadcom. Pi 400 doesn't have a page either (also 404), so
Pi 5's absence isn't unique, but it's the one that matters to us.

No wiki page: `archlinuxarm/wiki` on GitHub (the repo behind the legacy `/wiki/` URL
space, separate from `/platforms/`) has `Raspberry_Pi.md`, `Raspberry_Pi_2.md`, and
`Raspberry_Pi_3.md`, no Pi 4 or Pi 5 page. Its own `Contributing.md` states: *"Supported
platforms only. Information on unsupported platforms may be discussed on the
forum."* Pi 5 isn't formally declared "supported" anywhere, so this repo won't take a
Pi 5 page through a normal PR today even though the packages exist — supportedness is
apparently a status someone has to grant, not something a working install proves on its
own.

No tested, written install walkthrough anywhere that ties Path A or Path B together with
the actual current package set, current dtb names, and confirmed hardware behavior. The
2024 forum thread is a two-line recipe from a maintainer answering a support question,
not documentation meant to be followed cold. That gap, closed with two boards' worth of
real evidence, is the contribution.

### Not missing, so don't build it

A Pi 5-specific rootfs tarball. `ArchLinuxARM-rpi-aarch64-latest.tar.gz` already exists
and already contains a bootable base; it just ships the wrong default kernel
(`linux-aarch64`) for Pi 5 out of the box. The fix is a post-extraction package swap
(Path A), not a new tarball ALARM would need to build and host. This matches the
platforms-page template already used for Pi 3/4: one tarball, kernel choice made
in the install steps, not baked into a separate download.

## Where the website lives, and the real submission route

`archlinuxarm/PKGBUILDs` is the canonical package source (confirmed: `homepage:
https://archlinuxarm.org`, actively pushed as recently as today). Its `CONTRIBUTING.md`
covers package PRs only: one package per PR, squashed commits, must build clean-chroot
on all supported arches, correct `pkgver`/`pkgrel`/checksums. It explicitly warns
*"Pull requests that fail to meet these requirements may be summarily closed without
response."* It says nothing about platform support, because platform support isn't a
PKGBUILDs-repo concern.

`archlinuxarm/wiki` is public, PR-based, Markdown content, last pushed 2026-05-17. It
governs `/wiki/`, not `/platforms/`. It's the closest thing to a self-service docs
channel ALARM has, but its own contributing rules gate it on a platform already being
"supported," which for Pi 5 is exactly the status we'd be trying to establish.

We found no public repo behind `/platforms/` at all. The org's other repos
(`archlinuxarm-keyring`, `u-boot`, `u-boot-chromebook2`, `PlugUI`, `plugbuild-UI`, both
archived) don't contain platform-page content either; `PlugUI`/`plugbuild-UI` look like
ALARM's build-farm tooling by name but weren't accessible for content inspection in this
pass. The practical conclusion: `/platforms` is database-backed and edited by site
admins, not by contributors filing PRs. There is no documented process for requesting a
new platform page, which means the actual route is asking a specific person, not filing
a specific kind of ticket.

That person is most likely Kevin Mihelich (`kmihelich`), or graysky2, or both, since
between them they account for essentially all commit and merge activity (below). Given
graysky2 has personally driven every piece of Pi 5 work in ALARM since 2022 — the
`linux-rpi-16k` kernel, the dtb fixes, the mainline cherry-pick — he's the natural first
contact, via the forum thread where he's already answered Pi 5 questions directly, or
via `#archlinuxarm` on Libera.Chat IRC (the only channel ALARM's own
[contact page](https://archlinuxarm.org/about/contact) lists — no Matrix, no Discord, no
mailing list, and GitHub issues are disabled repo-wide, confirmed by a contributor
stating so directly in [PR #2223](https://github.com/archlinuxarm/PKGBUILDs/pull/2223)).
If the ask is "can this become an official page," that's more a Kevin Mihelich
question, since commit volume suggests he's the one closer to site/build-farm control;
worth sending to both rather than guessing which one owns that specific layer.

## Test matrix and evidence plan

Both boards are on hand but not yet on the network (per current STATUS.md). Nothing
below runs until that changes and Prasanth has signed off on writing to hardware, per
the house rules already in force.

### Establish board identity first

Board revision and SoC stepping affect which dtb applies and whether known bugs apply,
so this has to happen before anything else, on both boards independently:

```
cat /proc/cpuinfo | grep Revision
vcgencmd otp_dump | grep '30:'
sudo vclog -m | grep d0
vcgencmd bootloader_version
rpi-eeprom-update
vcgencmd get_mem arm; vcgencmd get_mem gpu; free -h
```

The revision code decodes as a bit field
(`NOQuuuWuFMMMCCCCPPPPTTTTTTTTRRRR`, low 24 bits populated on Pi 5): bits 0-3 are PCB
revision, bits 20-22 are memory size, bit 23 marks the new-style scheme. Don't match the
whole code as a string — Raspberry Pi engineering staff have said directly that
manufacturing-site changes bump codes for otherwise-identical boards
([forum](https://forums.raspberrypi.com/viewtopic.php?t=358074)), so decode the fields
that matter (revision, memory) and ignore the rest. Cross-check against the community
reference decoder at
[AndrewFromMelbourne/raspberry_pi_revision](https://github.com/AndrewFromMelbourne/raspberry_pi_revision)
since the primary Raspberry Pi documentation page is JS-rendered and didn't return usable
content to an automated fetch this round — read it in a real browser before finalizing
any written claim.

`vclog -m | grep d0` is the only reliable way to tell C1 from D0 stepping: a match on
`Loaded overlay 'bcm2712d0'` means D0, no match means C1
([forum](https://forums.raspberrypi.com/viewtopic.php?t=388666)). This matters because
running a kernel that only understands C1 on D0 hardware produces a specific,
diagnosable failure: an "Asynchronous SError Interrupt" panic
([forum thread where an RPi engineer root-caused exactly this](https://forums.raspberrypi.com/viewtopic.php?t=380721)).
AlmaLinux hit the same class of bug on rev 1.1 hardware in spring 2025 and hadn't
shipped a fix as of their post
([AlmaLinux blog](https://almalinux.org/blog/2025-04-08-spring-2025-raspberrypi-updates/)).
ALARM's `linux-rpi`/`linux-rpi-16k` track the Raspberry Pi Foundation's downstream
kernel fork directly (confirmed via the package page's source URL), which has carried D0
dtb support since its 6.6.y/6.12.y branches in 2024 — well before this 6.18.50-1 build —
so this specific failure mode shouldn't reproduce on Path A. It's still worth confirming
on both boards rather than assuming.

One safety item, unrelated to kernel choice: don't run `rpi-eeprom-update` blind on
either board. **Rechecked 2026-09-11** (`raspberrypi/rpi-eeprom#817`, closed
2026-04-10, `state_reason: completed`): the picture is narrower than the earlier read
of this issue suggested. One reporter's rev 1.1 board hit nine-green-blinks after
updating through all three 2025 EEPROM releases, and Raspberry Pi's own engineers
(`timg236`) called it a duplicate of #750 and told the reporter to seek a reseller
refund rather than treating it as a firmware regression. Read #750 and the closely
related #747 in full: both are the same pattern (nine-blinks after an EEPROM update on
a board bought from a low-cost/grey-market reseller), and in every case Raspberry Pi
engineering's position is that this is defective or non-genuine hardware, not a bug in
the shipped firmware, and they explicitly refuse to support downgrading below the
firmware a board shipped with ("not supported... might work, fail to boot or randomly
fail later at runtime", #747). A GitHub search across the whole repo for "9 green" or
"rev 1.1" plus "brick" turns up only these two threads, not a wider pattern. Current
`bootloader-2712` default-channel release is `v2026.05.11-2712` (checked
2026-09-11), newer than every version implicated in #817.

Net: there is no confirmed, currently-open firmware bug that bricks genuine Pi 5 rev
1.1 boards on EEPROM update. The earlier framing of this as an active hazard to route
around was reading the bug report at face value without reading the maintainers'
disposition of it. That said, keep the caution simple and cheap: capture
`vcgencmd bootloader_version` and `rpi-eeprom-update -a` (dry run only, no `-a` apply)
output before touching EEPROM on either board (see `docs/hardware-checklist.md`), and
still confirm with Prasanth before any actual EEPROM write, same as the SD card rule
already in the team brief — not because #817 is live, but because EEPROM writes are
hard to reverse regardless of whether this specific bug applies to us.

### The actual test matrix

Once board identity is known, run Path A (`linux-rpi`, direct firmware boot) on one
board and Path B (`linux-aarch64` + `raspberry-pi5-armstub`, U-Boot) on the other, then
swap, so both paths get validated on both board revisions rather than confounding boot
method with hardware revision. If both boards turn out to be the same revision, note
that plainly in the writeup as a limitation rather than implying broader coverage than
was actually tested. Also run `linux-rpi` against `linux-rpi-16k` side by side on
identical hardware, since ALARM currently has no comparative writeup on which page size
is right for Pi 5 and a tested one is itself useful upstream, not just useful to us.

For each combination, capture: full boot log from cold power-on to login prompt,
`vcgencmd bootloader_version` and the revision/stepping identification above, working
wifi (associate, get an address, sustain a transfer), working Bluetooth
(`bluetoothctl` scan and pair), HDMI output on both micro-HDMI ports at expected
resolution, USB 2 and USB 3 device enumeration, gigabit Ethernet throughput, and NVMe
boot if either board has the M.2 HAT available — flag as untested and out of scope if
not.

Run the install a second time on the second board following only the written
instructions, with none of the tribal knowledge accumulated writing them the first time,
and log every point where the instructions were unclear or wrong. That's the clean-room
verification a maintainer can't get from a single tester's word, and it's the concrete
difference between a page graysky2 can trust enough to publish and one he has to
re-verify himself before shipping. That extra verification is exactly the leverage two
boards buys us over one.

## Prior art and governance, in full

Nobody has been rejected. There is no dead end here. graysky (Developer) has personally
driven Pi 5 support in ALARM since a testing-kernel forum post in
[August 2022](https://archlinuxarm.org/forum/viewtopic.php?t=16144), through the
`linux-rpi-16k` package
[announcement](https://archlinuxarm.org/forum/viewtopic.php?f=3&t=16696) in December
2023, dtb fixes in [January 2024](https://archlinuxarm.org/forum/viewtopic.php?t=16719),
a [January 2026 EEPROM firmware advisory](https://archlinuxarm.org/forum/viewtopic.php?t=17381),
and the June 2026 mainline-kernel cherry-pick already described. Every forum thread we
found on Pi 5 was answered, most within days, several same-day. The one cautionary note
came from lategoodbye, described as an "Ex-maintainer," warning in
[early 2025](https://archlinuxarm.org/forum/viewtopic.php?f=65&t=17194) that mainline
support specifically was still too green — advice that predates this June's merge and
may no longer hold.

GitHub issues are disabled on `PKGBUILDs`
(`has_issues: false`, confirmed via the API, and confirmed in practice by a contributor
noting it directly in PR #2223's body). Bug reports and fixes go straight into PR
bodies or the forum. There's no separate bug tracker.

Commit authorship over the last 200 commits: Kevin Mihelich 113, graysky 52, David
Beauchamp 31, and single-digit counts for three others. `mergedBy` on the last 30 merged
PRs: graysky2 merged 20, kmihelich merged 10 — no other account appears. So yes, this is
effectively a two-person project for anything that actually lands, which confirms the
team brief's suspicion, just with graysky as an equal partner to Kevin Mihelich rather
than Kevin Mihelich alone.

Turnaround is sharply bimodal. Median time from open to merge on the last 30 merged PRs
is 0.64 days — under a day — when a maintainer engages, which is exactly what happened
on the Pi 5 mainline PR (opened, actively debugged with the submitter over six days,
landed). But the open-PR queue tells the other half of the story: median age of the
current ~28 open PRs is 525 days, the oldest is 1,579 days (a cloud-init package from
May 2022, still open), and roughly a third have sat over 900 days. If a PR doesn't catch
graysky2 or kmihelich's attention quickly, it can sit indefinitely rather than getting a
firm no. There's also a currently-open, currently-relevant PR worth watching:
[#2223](https://github.com/archlinuxarm/PKGBUILDs/pull/2223), opened yesterday
(2026-09-10) by rpodgorny, fixing a U-Boot load-address overflow that broke boot on
`linux-aarch64` 7.2.4 — not Pi 5-specific, but it touches the exact U-Boot boot chain
Path B depends on, and it's a live, small, concrete thing we could independently confirm
on our own hardware once boards are up. That's a low-cost way to show up as a credible
tester before making a bigger ask.

## Ranked contributions

1. **A tested Raspberry Pi 5 install walkthrough, sent to graysky2 (forum or IRC) with
   the evidence package above, asking him to either publish it as a `/platforms` page
   himself or tell us who does.** This is the one that matters. The packaging risk is
   already retired; what's left is proving the install works cold, on two boards, with
   receipts. Given graysky2's own track record on Pi 5 (fast turnaround when he engages,
   personally invested in the platform, already answering the exact question we'd be
   answering more thoroughly), this has real odds of landing, likely in the fast half of
   his bimodal response pattern rather than the multi-year queue. The dependency we
   don't control is whether `/platforms` publishing is something graysky2 can do
   directly or whether it needs Kevin Mihelich — send to both.

2. **A comparative linux-rpi vs linux-rpi-16k writeup for Pi 5**, produced as a side
   effect of the test matrix above. ALARM has no existing guidance on which kernel
   package is right for Pi 5 users; a tested answer, even a modest one, is useful on its
   own and cheap to package once the boards are up anyway.

3. **Confirming PR #2223 on real Pi hardware** once boards are on the network. Small,
   currently open, currently relevant to the same boot chain we care about, and a way to
   build a track record with the two people who matter before item 1 lands in their
   inbox.

4. **Helping maintain the `bootc` AUR package** (currently 1.16.12-1, maintainer `jjm`,
   updated as recently as 2026-09-10 — actively maintained, not neglected) is a
   reasonable secondary-track contribution if we end up depending on it regularly, but
   it's AUR, not ALARM, and it's not blocking anything here. `bootupd` on AUR
   (`0.2.34-1`, maintainer `Hec`) depends on `grub` and `efibootmgr`, which confirms
   what STATUS.md already decided: it's irrelevant to our native-firmware boot route,
   not something worth packaging or maintaining either upstream or in AUR for this
   project.

## Honest read

This is worth doing, and it's a better bet than the team brief's working assumption.
The packaging risk that would have made this a multi-month slog is already gone — someone
else did that work in June, we just have to notice it and prove it holds up on real
hardware. The remaining risk is entirely about reaching the one or two people who can
turn a good writeup into a published page, and about whether they treat "supported" as a
status they're willing to grant based on evidence from an outside team. Nothing in the
forum or PR history suggests reluctance; if anything graysky2 has been unusually
patient and hands-on with exactly this platform for four years running. The realistic
failure mode isn't rejection, it's the request landing in the 525-day median queue
instead of the 0.64-day fast path, which is a function of whether it reaches graysky2
directly rather than sitting as an unprompted PR.

Given that, the plan is: build the evidence on both boards, write the page as if we were
handing it to graysky2 ready to publish rather than as a request for him to do more
work, and send it to him directly by the channel where he's already demonstrably
responsive (forum), not by opening a cold PR into a 37-open-issue queue and hoping. In
parallel, publish the same tested guide ourselves — in `oci-native/pkgs` or wherever this
project's own docs end up — so the work has a home regardless of ALARM's timeline, and
offer it upstream on top of that rather than instead of it. That way nothing here is
wasted even in the slow case, and Prasanth gets the honest shot he asked for rather than
a bet on one person's inbox.

## HANDOFF

Written 2026-09-11, in response to a team-collapse instruction. This doc is not a
fragment, it's a finished pass — every section above was written after its underlying
research came back, not sketched ahead of evidence. But a few things sit underneath it
that are genuinely unconfirmed or untested, listed here so whoever picks this up doesn't
mistake "written down" for "verified."

### What's done

The core question is answered with real evidence: no Pi 5 `/platforms` page exists
(404, confirmed twice), the kernel/dtb/firmware/vcmailbox packaging gap the team brief
worried about doesn't exist (confirmed against `kernellayout`'s package extraction plus
independent GitHub archaeology showing the mainline path merged in June 2026), the
website's `/platforms` layer isn't contributor-editable (no repo found after checking
every repo in the `archlinuxarm` org), and the governance picture (two people, bimodal
turnaround, graysky2 personally invested in Pi 5 specifically) is backed by hard numbers
from `gh api`, not impression. The ranked contribution list and the honest-odds
assessment are both committed positions, not hedges.

### What's half-done or unconfirmed, marked as such

- **Path B's current viability is a real open question, not settled.** The mainline
  `linux-aarch64` + `raspberry-pi5-armstub` route merged in June 2026, but the only
  public opinion on mainline Pi 5 readiness (lategoodbye, early 2025) predates that and
  said it wasn't ready. Nobody has said it's fixed. Treat Path B as untested by us and
  unconfirmed by ALARM until our own boards prove it one way or the other.
- **Whether ALARM's `linux-aarch64` 7.2.4-1 actually carries the mainline D0 device-tree
  fix — checked 2026-09-11, confirmed yes.** Downloaded the actual package
  (`linux-aarch64-7.2.4-1-aarch64.pkg.tar.xz` from the ALARM `core` mirror) and listed
  `boot/dtbs/broadcom/`: it ships both `bcm2712-rpi-5-b.dtb` and `bcm2712-d-rpi-5-b.dtb`,
  the mainline-naming D0 variant, the same one `kernel-layout.md` already noted linux-rpi
  carries under its own naming. Path B is not blocked by a missing D0 dtb.
- **Who specifically controls `/platforms` publishing is a guess, not a confirmed
  fact.** I named both graysky2 and Kevin Mihelich based on commit/merge volume, not
  because either was seen touching a platform page. `PlugUI`/`plugbuild-UI` looked like
  candidates for the actual publishing tooling by name alone; nobody got inside them to
  check.
- **`rpi-eeprom#817` (the EEPROM brick bug) — rechecked 2026-09-11.** Closed by Raspberry
  Pi engineering as a hardware/reseller issue, not a firmware regression; see the body
  text above for the full reasoning. Practical upshot unchanged (still confirm with
  Prasanth before any EEPROM write), but it's no longer an open hazard to route around.
- **No Matrix/Discord/mailing list is stated as fact but rests on ALARM's own contact
  page listing only IRC and email.** Reasonable evidence, not exhaustive — I didn't try
  to independently find a Matrix bridge the contact page simply doesn't mention.
- **Board identity (revision, stepping) for our actual two Pi 5s is not established.**
  Neither board is networked yet (per STATUS.md as of this handoff). The commands to run
  are written down in the Test matrix section; nobody has run them.

### What I'd do next, in order

1. Get either board on the network, run the identity commands, and update this doc's
   test-matrix section with real revision/stepping data instead of "unknown, commands
   listed." That single step unblocks almost everything else here.
2. Actually run Path A end to end on one board and capture the evidence package (boot
   log, vcgencmd output, wifi/BT/HDMI/USB checks) before touching Path B at all — Path A
   is the well-trodden, forum-confirmed route and the one our own bootc image already
   depends on, so it de-risks the rest.
3. Only after Path A is proven, attempt Path B on the second board, specifically to
   settle the open question above about whether the June 2026 merge actually fixed what
   lategoodbye flagged.
4. Draft the actual forum post / message to graysky2 (still not sent — nothing in this
   round was opened or posted, per instruction) once there's real evidence to attach,
   not before.

### Trap for the next person

The obvious-looking shortcut is to treat PR #2206 being CLOSED on GitHub as "closed,
unmerged, dead" and either give up on it or redo the work it already did. It's not dead;
it's merged via cherry-pick outside the GitHub UI, and the five commit SHAs in the doc
above prove the code is in master right now. Don't re-litigate the kernel/packaging
side. The gap that's actually open is documentation and tested evidence, nothing
upstream of that.

A second, smaller trap: don't assume the `rpi-aarch64` tarball needs to change or that a
new Pi-5-specific tarball needs building. It doesn't — the existing tarball plus a
kernel-package swap is the whole install-side gap, confirmed by graysky's own forum
recipe. Building a new tarball would be solving a problem that doesn't exist and would
also be the kind of thing that needs ALARM's build farm, not something we can do from
outside anyway.
