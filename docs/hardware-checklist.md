# Hardware checklist: first contact with a Pi 5

Run this the moment either Pi 5 is reachable over SSH, before anything else touches the
board. Purpose is twofold: capture what this project needs to build and boot-test the
bootc image, and capture what an Arch Linux ARM Pi 5 platform-page contribution would
need as evidence (`docs/alarm-contribution.md`). One pass covers both.

## Safety contract

- **Tier 1 (below) is read-only.** No partition writes, no EEPROM writes, no config
  changes, no reboots. Safe to run against a board in unknown state, including whichever
  SD card happens to be in it when it first shows up on the network.
- **Never run `rpi-eeprom-update -a` or any `-d`/`-f` write flag from this checklist.**
  EEPROM writes need Prasanth's go-ahead first, same house rule as `/dev/sdb`. Bare
  `rpi-eeprom-update` with no flags is read-only status output and is fine.
- **Tier 2**, at the end, is functional verification (wifi association, Bluetooth
  scanning, physical HDMI). It changes radio/link state transiently and needs a monitor
  or peer device for some steps. Run it deliberately, separately, not as part of the
  blind first-contact pass.
- Confirm the board's IP/hostname before every command block if working across two
  boards in the same session — it's easy to run a check against the wrong one.
- This assumes SSH access already exists (whatever OS the SD card currently boots,
  stock Raspberry Pi OS or an existing ALARM image). If neither board has a network
  address yet, that's a prerequisite this checklist doesn't cover.

## Setup: evidence directory

```bash
HOST=$(hostname)
OUTDIR=~/pi5-evidence/$HOST-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$OUTDIR"
cd "$OUTDIR"
echo "Capturing to $OUTDIR"
```

Everything below appends into `$OUTDIR`. Pull the whole directory back to the build host
afterward with `scp -r pi:pi5-evidence/$HOST-* .` — a copy, nothing destructive on either
end.

## Tier 1 — identity and inventory (read-only)

### 1. Board identity: model, revision, stepping

```bash
{
  echo "== /proc/cpuinfo tail =="; tail -5 /proc/cpuinfo
  echo "== device-tree model/compatible =="
  cat /proc/device-tree/model; echo
  cat /proc/device-tree/compatible | tr '\0' '\n'
  echo "== otp_dump row 32 (authoritative revision, see rpi-eeprom#797) =="
  sudo vcgencmd otp_dump 2>/dev/null | sed -n '32p'
} | tee board-identity.txt
```

Decode the `Revision` hex against
[AndrewFromMelbourne/raspberry_pi_revision](https://github.com/AndrewFromMelbourne/raspberry_pi_revision)
by hand later; don't trust an automated summary of the JS-rendered official page.

D0 vs C1 stepping — the one command that actually answers it (forum-confirmed method,
see `docs/alarm-contribution.md`):

```bash
vclog -m 2>/dev/null | grep -i d0 | tee dtb-stepping.txt
# "Loaded overlay 'bcm2712d0'" present  -> D0 stepping
# no match                              -> C1 stepping
```

### 2. EEPROM and bootloader version (read-only)

```bash
{
  echo "== bootloader_version =="; vcgencmd bootloader_version
  echo "== bootloader_config =="; vcgencmd bootloader_config
  echo "== rpi-eeprom-update status (no -a: does not apply anything) =="
  sudo rpi-eeprom-update
  echo "== current EEPROM config (read-only dump, includes BOOT_ORDER) =="
  sudo rpi-eeprom-config
} | tee eeprom-status.txt
```

Do not act on `rpi-eeprom-update` suggesting an update is available. Per
`docs/alarm-contribution.md`'s rechecked status on `rpi-eeprom#817`, there's no confirmed
live brick bug on genuine hardware, but any EEPROM write is still a decision for Prasanth,
not this checklist.

### 3. Current boot order and boot medium

```bash
{
  echo "== root device and mounts =="; findmnt /; lsblk -o NAME,MOUNTPOINT,MODEL,SIZE,TRAN
  echo "== kernel cmdline (shows root=, actual boot device) =="; cat /proc/cmdline
  echo "== BOOT_ORDER (also in eeprom-status.txt) =="
  sudo rpi-eeprom-config | grep -i boot_order
} | tee boot-medium.txt
```

### 4. Kernel identity and config

```bash
{
  echo "== uname =="; uname -a
  echo "== os-release =="; cat /etc/os-release
  echo "== kernel package, if ALARM =="; pacman -Q linux-rpi linux-rpi-16k linux-aarch64 2>/dev/null
} | tee kernel-identity.txt

if [ -f /proc/config.gz ]; then
  zcat /proc/config.gz > kernel-config.txt
  echo "kernel-config.txt captured, $(wc -l < kernel-config.txt) lines"
  grep -E "^CONFIG_(SECCOMP|NF_NAT|NETFILTER_NETLINK|NF_CONNTRACK|NF_TABLES|BCM2712_IOMMU|BLK_DEV_NVME|IKCONFIG)" \
    kernel-config.txt | tee kernel-config-relevant.txt
else
  echo "/proc/config.gz not present (CONFIG_IKCONFIG_PROC not set on this running kernel)" \
    | tee kernel-config.txt
fi
```

Package-level values for `linux-rpi` 6.18.50-1 are already extracted and recorded in
`docs/kernel-choice.md` §4 — this step is a live cross-check against whatever kernel the
board actually boots, not a first look.

### 5. Firmware and thermal sanity

```bash
{
  echo "== vcgencmd version (firmware build date) =="; vcgencmd version
  echo "== throttled flag (undervoltage/thermal history) =="; vcgencmd get_throttled
  echo "== temperature =="; vcgencmd measure_temp
  echo "== memory split =="; vcgencmd get_mem arm; vcgencmd get_mem gpu
} | tee firmware-sanity.txt
```

### 6. Static device inventory (no association/pairing/output triggered)

```bash
{
  echo "== PCIe/NVMe =="; lspci -vv 2>/dev/null; echo "---"; lsblk -o NAME,TRAN,MODEL,SIZE
  command -v nvme >/dev/null && sudo nvme list
  echo "== USB topology =="; lsusb -t; lsusb
  echo "== network interfaces =="; ip -br link; ip -br addr
  echo "== wifi/BT radios present, powered state (no scan) =="
  rfkill list
  bluetoothctl show 2>/dev/null
  echo "== display connectors, no output changed =="
  cat /sys/class/drm/*/status 2>/dev/null
} | tee device-inventory.txt
```

`cat /sys/class/drm/*/status` reports `connected`/`disconnected` per port without
touching output — with no monitor attached both ports will read `disconnected`, that's
expected, not a failure.

### 7. Boot log

```bash
journalctl -b 0 --no-pager > boot-log-journalctl.txt
dmesg | grep -iE 'rp1|pcie|nvme|brcm|mmc|bcm2712|bootc|ostree' > dmesg-relevant.txt
```

If serial console capture from cold power-on is available (per `docs/disk-image.md` part
5's `picocom` setup), save that transcript into `$OUTDIR` too — it's the only view of
firmware-stage boot the journal doesn't have.

### 8. Wrap up

```bash
cd ~/pi5-evidence
tar czf "$HOST-evidence-$(date -u +%Y%m%dT%H%M%SZ).tar.gz" "$(basename "$OUTDIR")"
ls -la
```

Pull the tarball to the build host, then diff the two boards' `board-identity.txt` and
`dtb-stepping.txt` side by side — confirming whether the two boards are actually
different revisions is one of `STATUS.md`'s open questions.

## Tier 2 — functional verification (changes radio/link state, do deliberately)

Run each of these once Tier 1 is captured and reviewed, one board at a time, and record
results the same way (append to the board's evidence directory).

- **Wifi**: `nmcli device wifi list` or `iw dev wlan0 scan | grep SSID` to confirm the
  radio sees networks, then associate to a real AP and confirm an address
  (`nmcli device wifi connect "<ssid>" password "<psk>"`, `ip -br addr`), then a transfer
  (`curl -o /dev/null -w '%{speed_download}\n' http://<build-host>/some-test-file` or
  similar). Needs real credentials, not something to script blind.
- **Bluetooth**: `bluetoothctl scan on`, wait ~10s, `scan off`, confirm at least one
  nearby device shows up; pair against a real peripheral if one's on hand.
- **HDMI**: needs a physical monitor on each micro-HDMI port in turn. Once connected,
  `cat /sys/class/drm/*/status` should flip to `connected`; `modetest -c` (from
  `libdrm-tests`/`xorg-utils` if installed) lists detected modes without changing output.
- **Ethernet throughput**: `iperf3` against a peer on the LAN (the build host works),
  not just link-up — confirms actual gigabit, not just autonegotiation.
- **NVMe boot**: only if the M.2 HAT is attached. Requires `BOOT_ORDER` to include NVMe
  (captured already in `eeprom-status.txt`) and a physical reboot — coordinate with
  Prasanth before rebooting a board that's mid-test for anything else.

## What this feeds

- **This project**: board revision/stepping for both boards (open question in
  `STATUS.md` Phase 2), confirms whether `linux-rpi`'s D0 dtb coverage and the kernel
  config extracted in `docs/kernel-choice.md` hold on real hardware, gives the first real
  boot log to compare against the designed `os_prefix`/BLS chain once the bootc image
  exists.
- **The ALARM platform-page contribution** (`docs/alarm-contribution.md`): board
  identity, EEPROM/bootloader version, working-peripheral matrix (wifi/BT/HDMI/USB/NVMe)
  across both boards is exactly the evidence package a platform page needs, and running
  it clean-room on the second board after writing up the first is the test matrix's own
  stated verification method.

## HANDOFF

Written 2026-09-11, pre-hardware. Session closed 2026-09-14 without this checklist ever
having been run as written.

**Done:** every command above was reasoned from package/tool evidence gathered the same
session (kernel-choice.md, alarm-contribution.md, kernel-layout.md), not guessed at. The
tiering (read-only capture vs. state-changing functional checks) and the safety
guardrails (no EEPROM write, no `/dev/sdb`, confirm board before every block) match the
house rules in `TEAM-BRIEF.md` as they stood at the time.

**What actually happened instead:** by 2026-09-13, two cards had been flashed and booted
against real hardware directly, ahead of and independent of this checklist — see the
"It flashed, it verified, and it still did not boot" section in `docs/disk-image.md` and
the superseding note at the top of `docs/kernel-choice.md`. That work answered board/SD
reader reliability and kernel-boot questions this checklist never got to ask, by more
direct means (serial-adjacent evidence: firmware log reads, journal state, mount
timestamps) than the `vcgencmd`/`lsblk`/`journalctl` commands specified here. It also
surfaced a real bug this checklist would not have caught: a USB 2.0 card reader dropping
off the bus mid-write, still unresolved as of the last entry in `docs/disk-image.md`.

**Not confirmed, and now moot or open depending on how the project proceeds:** none of
Tier 1's identity/EEPROM/kernel-config capture or any of Tier 2's functional checks
(wifi, Bluetooth, HDMI, NVMe boot) has been run through this checklist specifically. If
the project reaches a board that actually mounts root and reaches a login prompt, this
checklist is still the right next step for the ALARM platform-page evidence package —
nothing above needs rewriting for that, it was never invalidated, just overtaken by a
more urgent boot-blocking bug.

**Trap for whoever picks this up:** don't assume this checklist's absence from later
commits means it was tried and abandoned. It was never run. If the reader/card
reliability question in `docs/disk-image.md` gets settled and a board boots, come back
here before improvising a fresh evidence pass — the commands are still correct, they
were just never exercised.
