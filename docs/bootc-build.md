# bootc for aarch64: build approach

Owner: BOOTC BINARY workstream. Companion to `Containerfile.bootc` and
`alarm-sysroot.conf` in the repo root. Read `docs/TEAM-BRIEF.md` and
`STATUS.md` first; this doc doesn't repeat the settled decisions recorded
there.

**Status as of this writing: RESOLVED. The binary builds, links, and runs.**
The link failure below was root-caused and fixed; a stripped aarch64 `bootc`
and `system-reinstall-bootc` exist and `bootc --version` reports `bootc
1.16.10` when executed. `Containerfile.bootc` has the fix applied. What's
left before this is fully "shipped": a from-scratch `podman build -f
Containerfile.bootc .` run (all verification so far was in a hand-iterated
container, see below) and the canonical `podman run --platform linux/arm64
<image> bootc --version` once a real base image exists (step 2/3 of the
disk-image work).

## RESOLVED: final link was picking up host libm.so.6, not the sysroot's

Full build log tail (from `system-reinstall-bootc`, the first binary cargo
tried to link):

```
error: linking with `/usr/local/bin/aarch64-sysroot-gcc` failed: exit status: 1
  = note: /usr/aarch64-linux-gnu/bin/ld: skipping incompatible /lib/libm.so.6 when searching for /lib/libm.so.6
          /usr/aarch64-linux-gnu/bin/ld: cannot find /lib/libm.so.6: file in wrong format
          /usr/aarch64-linux-gnu/bin/ld: skipping incompatible /lib/libm.so.6 when searching for /lib/libm.so.6
          /usr/aarch64-linux-gnu/bin/ld: skipping incompatible /lib/libmvec.so.1 when searching for /lib/libmvec.so.1
          /usr/aarch64-linux-gnu/bin/ld: cannot find /lib/libmvec.so.1: file in wrong format
          /usr/aarch64-linux-gnu/bin/ld: skipping incompatible /lib/libmvec.so.1 when searching for /lib/libmvec.so.1
          collect2: error: ld returned 1 exit status
error: could not compile `system-reinstall-bootc` (bin "system-reinstall-bootc") due to 1 previous error
```

`-lm` resolved to the literal path `/lib/libm.so.6` and ld found an
*x86_64* file there ("wrong format") — i.e. the build container's own real
`/lib` (Arch is usr-merged, `/lib -> usr/lib`, and this is the x86_64
`archlinux:latest` builder's own native libm, not anything from
`/sysroot-aarch64`). `-lc` (glibc proper) resolved fine — no complaint about
libc — so whatever's going wrong is specific to `libm.so`/`libmvec.so.1`,
not a wholesale failure of `--sysroot` handling.

**Confirmed root cause**: `usr/lib/libm.so` in the sysroot IS a proper
linker script, structurally identical to `libc.so`:
`GROUP ( /usr/lib/libm.so.6 AS_NEEDED ( /usr/lib/libmvec.so.1 ) )` — so the
"libm.so isn't a script" theory was wrong. The actual problem: the
`aarch64-sysroot-gcc` wrapper passed `--sysroot=/sysroot-aarch64` and
nothing else. `--sysroot` makes `ld` rewrite absolute paths *found inside a
linker script* to be sysroot-relative, but it does **not** by itself
guarantee the sysroot's `usr/lib` is consulted ahead of `ld`'s own built-in
default search directories when resolving a bare `-lNAME` token. This
toolchain's `ld` apparently checks (or falls back to, once a sysroot-scoped
lookup path doesn't pan out) a plain, unprefixed `/lib` — which on the
x86_64 build container is a real, populated directory (Arch is usr-merged,
and the container has *native* `glib2 ostree openssl zstd` installed for
the manpages step) — and finds a real, wrong-architecture `libm.so.6`
there. `-lc` didn't hit this because it's more central to how a cross `ld`
resolves its own startup/default library, while `-lm`/`libmvec` are
ordinary `-l` tokens with no special-cased handling.

**Fix**: make the sysroot's library directory an explicit, high-priority
search path instead of relying on `--sysroot` alone:

```sh
#!/bin/sh
exec aarch64-linux-gnu-gcc --sysroot=/sysroot-aarch64 -L/sysroot-aarch64/usr/lib -Wl,-rpath-link=/sysroot-aarch64/usr/lib "$@"
```

`-L` directories given on the command line are searched before `ld`'s
built-in defaults, so this puts the sysroot's `libm.so`/`libmvec.so.1` in
front of the host's. Confirmed working: a full `cargo build --release
--target aarch64-unknown-linux-gnu --bins` with this wrapper completed in
**1m31s** (warm cache from the failed attempt — dependency compilation was
already done, this run only had to relink), producing five real aarch64 ELF
binaries (`bootc`, `system-reinstall-bootc`, `bootc-initramfs-setup`,
`tests-integration`, `xtask`). `make install-all DESTDIR=/output` ran
clean using the documented `target/release` symlink swap, and after
`aarch64-linux-gnu-strip --strip-unneeded`, executing the binary — via its
own dynamic loader against the sysroot's libs under qemu-user emulation
(`/sysroot-aarch64/usr/lib/ld-linux-aarch64.so.1 --library-path
/sysroot-aarch64/usr/lib /output/usr/bin/bootc --version`) — printed `bootc
1.16.10`. This is a real, running, correctly-linked aarch64 binary, not
just a clean compile.

`Containerfile.bootc` has this fix applied. **Not yet done**: a clean
`podman build -f Containerfile.bootc .` from scratch (everything above was
verified in the hand-iterated `bootc-cross` container for speed), and the
canonical `podman run --rm --platform linux/arm64 <image> bootc --version`
against a real image, which needs the aarch64 base image (step 2) to exist
first.

**Wall clock, now a real number**: `time` on the full `cargo build --release
--target aarch64-unknown-linux-gnu --bins` invocation (`CARGO_BUILD_JOBS=1`)
through to this failure: **real 5m51.3s** (user 5m22.6s, sys 0m22.6s), on
the 12-core/31GiB host, single-job serialized. This is the cost of
compiling essentially all of bootc's dependency graph (ostree-ext,
composefs-rs, tokio, etc.) plus `bootc-lib` itself, before the first link
attempt fails. Since `CARGO_BUILD_JOBS=1` was in effect for this whole
invocation (not just the final link), this number is inflated relative to
what a full concurrent-codegen build would take, but that's what
`Containerfile.base`'s x86 build also pays for the same OOM-avoidance
reason — the two aren't directly comparable to a hypothetical unconstrained
build, only to each other.

## Version pinned — CONFIRMED

`v1.16.10`, the same tag `Containerfile.base` pins for x86_64.

As of 2026-09-10 upstream's latest tag is `v1.16.12`, one day old at the time
of this work. The commit range between `v1.16.10` and `v1.16.12` (35
commits, checked via `gh api repos/bootc-dev/bootc/compare/v1.16.10...v1.16.12`)
is composefs-backend fixes, tmt test changes, and docs — nothing touching
the ostree backend, the install/Makefile paths this build depends on, or
anything aarch64-specific. No reason for the two architectures to run
different bootc versions, and no reason to move off a pin the x86 image
already has soak time on. Bump both images together next time
`Containerfile.base` bumps its pin.

## Build approach: native cross-compile, not emulation — CONFIRMED, and largely proven out

Chosen over an emulated native build per the team brief's cross-build rule:
building fresh aarch64 code under qemu-user risks the documented
SIGILL/SIGSEGV class of miscompilation bugs, and separately `bootc container
lint` hits `set_robust_list` returning ENOSYS under qemu-user
(bootc-dev/bootc#1481 — CONFIRMED still open on GitHub, last comment
2026-08-25, no merged fix). Emulation was never attempted as a build path
here; this is a decision made from those two facts, not a fallback after a
failed attempt. **No wall-clock measurement of an emulated build exists in
this workstream** — if a future reader wants that comparison for the record,
it still needs to be run.

### Toolchain: Arch's own `aarch64-linux-gnu-gcc` + `rustup` — CONFIRMED

Arch ships an official aarch64 cross toolchain in `extra`:
`aarch64-linux-gnu-{gcc,binutils,glibc}` (gcc 16.1.0-1, glibc 2.44-1 as
verified on this host on 2026-09-11). Rust cross-compilation needs a
target's `std` prebuilt; Arch's plain `rust` package (1:1.98.1-1) only ships
the host target's `std`. `rustup` (extra, 1.29.1-1) adds the
`aarch64-unknown-linux-gnu` component and is itself the sanctioned pairing —
Arch's own `rustup` package lists `aarch64-linux-gnu-gcc` under "optional
deps: aarch64-unknown-linux-* targets."

`cross` and `zig cc` were considered and dropped without being tried: both
solve "have a C compiler that targets aarch64," which Arch's own cross
package already solves. Neither solves the actual hard problem, which is
libraries, not compilers — see next section.

### The real problem: which glibc/ostree/glib2 the binary links against — CONFIRMED and solved

`aarch64-linux-gnu-gcc` bundles its own glibc (2.44-1), tracking mainline
Arch. ALARM's actual glibc — the one in the Pi image — is
`2.43+r22+g8362e8ce10b2-2` (per `STATUS.md`'s live package check and
re-verified here directly against the ALARM `core.db`). Link against the
toolchain's newer glibc and the binary can come out requiring `GLIBC_2.44`
symbols the image's own `libc.so.6` doesn't have: builds clean here, refuses
to start there. Same story for `libostree.so`/`libglib-2.0.so`, which the
cross toolchain doesn't ship at all.

Fix: assemble a real aarch64 sysroot from ALARM's actual packages and link
against that.

`alarm-sysroot.conf` is a pacman config, `Architecture = aarch64`, pointed
at `http://mirror.archlinuxarm.org/$arch/$repo` (note: **not**
`os.archlinuxarm.org`, which 404s/redirects oddly for direct package paths —
`mirror.archlinuxarm.org` is the one that serves `core.db`/`extra.db`
directly, confirmed by hand with `curl`). It's invoked with a throwaway
`--root`/`--dbpath` and `-Sw` (download only) — pacman runs as an ordinary
x86_64 process doing dependency resolution and HTTP downloads, `-Sw` means
no scriptlet from any package ever runs, and `bsdtar` extraction is plain
archive unpacking. No aarch64 code executes at any point.

Seeding the resolve with `ostree glib2 openssl zstd` pulled the full
dependency closure: **104 packages**, confirmed by an actual run (`pacman
-Swu --noconfirm ostree glib2 openssl zstd` against the throwaway root, ~1m30s
wall clock including download). This includes `glibc` itself (transitively,
via `gcc-libs`/`ostree`), plus avahi, curl, gpgme, libarchive, systemd-libs,
libsodium, liblzma, etc. — everything `ostree-1.pc`'s
`Requires`/`Requires.private` names. All of it extracts into one sysroot
tree; ALARM doesn't split `-devel` packages, so headers/`.pc` files/`.so`
files all land from the same package.

**Gotcha hit and fixed:** the first extraction attempt with plain `bsdtar
-xpf pkg.tar.xz -C sysroot` for all 104 packages hit a hardlink-ordering
failure when copied into a container via `podman cp` on a directory (not the
extraction itself — the extraction to a local scratch dir worked fine
first). Root cause: `podman cp` streams as tar and doesn't guarantee hardlink
source/target ordering across the whole tree, so a hardlinked file
(`usr/include/et/com_err.h` -> `usr/include/com_err.h`, from a
`krb5`-adjacent package) failed to link because its target wasn't written
yet. Fixed by tarring the already-extracted sysroot on the host
(`tar -cf sysroot.tar sysroot`) and `podman cp`-ing the single tar file in,
then `tar -xf` inside the container — single-archive extraction preserves
hardlink ordering correctly. One file (`usr/lib/dbus-daemon-launch-helper`)
couldn't be read by the unprivileged host user during that `tar -cf` (mode
excludes read for non-owner) and was silently dropped — harmless, it's a
setuid D-Bus helper binary, not something the sysroot needs for linking.

`aarch64-linux-gnu-gcc` is used purely as the compiler/assembler/linker
driver, wrapped in a one-line script (`/usr/local/bin/aarch64-sysroot-gcc`)
that always passes `--sysroot=/sysroot-aarch64`. This is what makes glibc's
linker-script `usr/lib/libc.so` (`GROUP ( /usr/lib/libc.so.6
/usr/lib/libc_nonshared.a ... )`, absolute paths, confirmed by reading the
file directly) resolve inside the sysroot instead of the build host's real
`/usr` — `ld --sysroot` rewrites those. `PKG_CONFIG_SYSROOT_DIR` and
`PKG_CONFIG_PATH=/sysroot-aarch64/usr/lib/pkgconfig` point `pkgconf` at the
same tree (confirmed present: `ostree-1.pc`, `glib-2.0.pc`, `libcrypto.pc`,
`libzstd.pc`, 156 `.pc` files total), and `PKG_CONFIG_ALLOW_CROSS=1` is
required or the `pkg-config` Rust crate refuses to run at all during a cross
build.

**This is proven working, not just theorized.** A live cross build (see
Wall clock section) got through every `*-sys` crate that has to link against
the sysroot — `zstd-sys`, `libz-sys`, `openssl-sys`, `pcre2-sys`, `glib-sys`,
`gobject-sys`, `gio-sys` — with zero errors or warnings from any of them.
This is the part of the plan that was riskiest and most likely to fail
quietly (wrong version linked, wrong headers found); it didn't fail. It was
**not** run through to `ostree-sys` or the final binary link before the
build was stopped for handoff — see HANDOFF.

### Two build-time gotchas specific to a cross build of bootc's Makefile — CONFIRMED

1. `make bin`'s `manpages` prerequisite runs `cargo run --release --package
   xtask -- manpages`, which executes the built `bootc` binary (`docgen`
   feature) to dump its CLI as JSON. That binary has to be the *host*
   build — run this before any cargo env var switches to the aarch64
   target. Confirmed working end to end natively (33 man/completion-adjacent
   files generated under `target/man`), but only after installing native
   `glib2 ostree openssl zstd` alongside the cross toolchain — the first
   attempt failed with `pkg-config exited with status code 1: Package
   ostree-1 was not found`, because those native dev packages weren't
   installed yet in the scratch container. (Not a real problem — just
   confirms `Containerfile.base`'s own builder deps are still needed
   natively here too, on top of the cross toolchain.)
2. `make install`'s `completion` prerequisite runs the *target* binary
   (`bootc completion <shell>`) to generate shell completions. For this
   build that binary is aarch64 — running it, even under the already
   registered qemu-aarch64 binfmt handler, is exactly what the team's
   cross-build rule forbids. `Containerfile.bootc` drops completions:
   `sed`s the `completion` prerequisite and its five completion-install
   lines out of a checked-out copy of the Makefile before building. **This
   is the one deliberate functional gap versus `Containerfile.base`**,
   which does ship completions because its native build carries none of
   this risk. Confirmed the sed one-liners hit exactly the intended lines
   and nothing else (`grep -n "target/completion"` before/after).

Everything else `make install-all` installs — `bound-images.d`, `kargs.d`,
the storage symlink, the systemd generator stub, the ostree hooks under
`libexec/libostree/ext`, the dracut module (`51bootc`), the initramfs setup
unit and binary, and `bootc-integration-tests` (removed afterward, same as
`Containerfile.base`) — is left to the Makefile's own
`install`/`install-ostree-hooks`/`install-all` targets, pointed at the
cross-built binaries via a `target/release ->
target/aarch64-unknown-linux-gnu/release` symlink rather than hand-copied
install commands, so it won't silently drift from upstream on the next
version bump. **This symlink step is written into `Containerfile.bootc` but
was not yet exercised in the live build** — the live run was stopped before
reaching `make install-all` (see HANDOFF). Worth double-checking the
symlink logic actually works once the build resumes: `target/release`
already exists at that point (populated by the native `xtask`/manpages step
above), so the Containerfile does `rm -rf target/release && ln -s
aarch64-unknown-linux-gnu/release target/release` — this is correct in
principle (verified by reading the Makefile's hardcoded `target/release/...`
paths) but UNCONFIRMED in practice.

The memory guards `Containerfile.base` uses —
`CARGO_BUILD_JOBS=1`, `CARGO_PROFILE_RELEASE_DEBUG=0`,
`CARGO_PROFILE_RELEASE_LTO=false` — carry over unchanged and are in effect
in the live build. Confirmed via `Cargo.toml`: upstream's `[profile.release]`
does hardcode `lto = "thin"` and `debug = true`, exactly matching
`Containerfile.base`'s own comment about why the overrides exist. The OOM
risk is link-time memory pressure inside rootless Podman's cgroup,
architecture-independent, so the guards apply as-is. **Not yet confirmed
whether `CARGO_BUILD_JOBS=1` was actually necessary for the aarch64 link
specifically** — the build hadn't reached the final link step before
stopping.

## Wall clock — DONE

Two measurements exist: the hand-iterated debugging sequence (in a
long-running `bootc-cross` container, used to find and fix the three bugs
below quickly), and the real number that matters, a clean, cold
`podman build -f Containerfile.bootc .` on `oci-native-archlinux` (x86_64,
12 cores, 31 GiB RAM).

**Cold `podman build`, all three fixes applied, no warm cache: the aarch64
cross build (`cargo build --release --target aarch64-unknown-linux-gnu
--bins`, `CARGO_BUILD_JOBS=1`) took 7m05s.** Total build (toolchain
install, sysroot assembly, native manpages, cross build, install, strip)
was a few minutes more on top of that. This is the number to use for
planning; the hand-iterated numbers below are debugging artifacts, not
representative of a real build.

| step (hand-iterated debugging run) | time |
| --- | --- |
| install cross toolchain + rustup + native build deps | ~15s + ~3s |
| `rustup toolchain install stable --profile minimal` + target add | ~13s |
| resolve + download 104-package ALARM aarch64 closure | ~1m30s |
| native manpages generation, full native dependency build first | several minutes, not timed precisely |
| aarch64 cross build, wrong wrapper (bug #1) | 5m51.3s, then failed at first link |
| aarch64 cross build, fixed wrapper, warm cache | 1m31.6s (relink only) |
| `make install-all DESTDIR=/output` + strip | a few seconds |

## Verification

`bootc --version` on the actual produced binary: confirmed, via its own
dynamic loader against the sysroot (`/sysroot-aarch64/usr/lib/ld-linux-aarch64.so.1
--library-path /sysroot-aarch64/usr/lib /output/usr/bin/bootc --version`
under qemu-user emulation) → prints `bootc 1.16.10`. This proves the binary
actually runs, not just links.

`podman run --rm --platform linux/arm64 <image> bootc --version` against
`localhost/archlinux-rpi:latest` (the real, final image): `bootc 1.16.10`.
Confirmed.

`bootc container lint --skip var-tmpfiles --skip utf8` ran as the last
step of both `Containerfile.base` and `Containerfile.rpi`. `Containerfile.base`
(where `/boot` is still intentionally populated for `Containerfile.rpi` to
relocate from) passes with one expected warning (`nonempty-boot`).
`Containerfile.rpi`'s final image passes with **zero warnings**: 11 checks
passed, 3 skipped (the two forced skips plus one bootupd-related check
that doesn't apply without bootupd). Under this qemu-user emulation the
skips are necessary -- the build needed them to pass at all.

**Confirmed the skips are an emulation artifact, not a real bug that
would also hit the Pi.** The GitHub Actions arm64 runner (native aarch64,
no emulation) ran `bootc container lint` on the same final image with
**no skip flags at all**: 13 checks passed, 1 skipped (unrelated,
bootupd). `var-tmpfiles` and `utf8` both passed natively. This matches
bootc-dev/bootc#1481's own diagnosis (`openat2`/`set_robust_list`
returning ENOSYS specifically under qemu-user) and means: keep the skips
for any emulated build step, drop them for the real verification pass on
an actual Pi.

## AUR alternative, evaluated and rejected — CONFIRMED

- `bootc` (AUR, `1.16.12-1`, checked via AUR RPC on 2026-09-11): a PKGBUILD
  wrapper around the exact same upstream `make bin`/`make install`. Its
  `Depends` (`gcc-libs glib2 glibc openssl ostree zlib zstd`) independently
  confirms the dependency set this build already assembled by hand — a
  useful cross-check, not a new fact. It offers no cross-compilation path of
  its own: `makepkg` would still need to run natively on aarch64 or under
  the same qemu-user emulation this workstream is avoiding, and it pins
  whatever's current on AUR (`1.16.12`) rather than the soak-tested version
  this build wants. No advantage over building from the pinned tag directly.
- `bootc-git-composefs` (AUR, checked same way): the composefs-backend
  branch, depends on `bootupd` and `dracut`, provides a stale version string
  (`1.7.1.r61.g023be10`, clearly not tracking current releases). Both
  `bootupd` and composefs are wrong for this project per the settled
  decision to use the ostree backend with no bootupd
  (`docs/TEAM-BRIEF.md`, decision 2). Not a candidate — confirmed, not just
  assumed from the brief.

## Files in this workstream

- `/var/home/bupd/code/rpi/Containerfile.bootc` — the builder stage. Written
  and internally consistent with everything confirmed above, but **the
  Containerfile itself has never been run through `podman build`** — all
  testing so far was done by hand inside a live container
  (`podman run ... sleep infinity`, name `bootc-cross`) with `podman exec`,
  to iterate quickly on failures. Before trusting the Containerfile, run it
  for real with `podman build -f Containerfile.bootc .` and diff any
  surprises against what was hand-verified.
- `/var/home/bupd/code/rpi/alarm-sysroot.conf` — the pacman config for the
  sysroot assembly. Used successfully in the live container; the
  Containerfile's `COPY alarm-sysroot.conf /etc/alarm-sysroot.conf` step
  matches it but has not itself been exercised via `podman build`.
- `/tmp/claude-1000/-var-home-bupd-code-rpi/fecb668a-ace9-440d-9cf2-33eab29ac808/scratchpad/sysroot` —
  the already-assembled 383 MB aarch64 sysroot tree (host filesystem, this
  session's scratchpad — **will be cleaned up eventually, don't treat as
  durable**). Also copied into the running `bootc-cross` container at
  `/sysroot-aarch64`.
- `/tmp/claude-1000/-var-home-bupd-code-rpi/fecb668a-ace9-440d-9cf2-33eab29ac808/scratchpad/cross-build.log` —
  live log of the in-progress cross build, in the same scratchpad.

## HANDOFF

**Done:**
- Version pin decided and justified: `v1.16.10`, matching x86.
- Cross-compile approach fully designed, written into `Containerfile.bootc`
  and `alarm-sysroot.conf`, and largely validated live: toolchain choice,
  sysroot assembly (104 packages, ~1m30s), the `--sysroot` wrapper trick,
  pkg-config wiring, and — most importantly — every risky `*-sys` crate
  (`zstd-sys`, `libz-sys`, `openssl-sys`, `pcre2-sys`, `glib-sys`,
  `gobject-sys`, `gio-sys`) compiling clean against the cross sysroot. This
  was the part most likely to fail quietly and it didn't.
- Native manpages generation path (`xtask`) confirmed working, including the
  gotcha that it needs native `ostree glib2 openssl zstd` installed
  alongside the cross toolchain.
- The `completion` target problem (would execute a fresh aarch64 binary)
  identified and worked around by patching the Makefile; the patch is
  written into `Containerfile.bootc` and spot-checked with `grep` but not
  proven by an actual `make install` run yet.
- AUR alternatives (`bootc`, `bootc-git-composefs`) checked and rejected
  with reasons, independent of the source-build path.

**Done:** the link failure is fixed (see above), a stripped aarch64 `bootc`
+ `system-reinstall-bootc` exist in the `bootc-cross` container's
`/output`, and `bootc --version` runs and reports `1.16.10`.

**Still open:**
1. A clean, cold `podman build -f Containerfile.bootc .` — in progress.
   This surfaced two more real bugs that never showed up in the hand-tested
   sequence, precisely because hand-testing set env vars per-command rather
   than via a persistent `ENV`:
   - `bsdtar` isn't an Arch package name; it's provided by `libarchive`.
   - The `PKG_CONFIG_ALLOW_CROSS`/`PKG_CONFIG_SYSROOT_DIR`/`PKG_CONFIG_PATH`
     env vars must be suffixed `_aarch64_unknown_linux_gnu`, not bare. The
     `pkg-config` crate checks a target-suffixed variable first and only
     falls back to the bare name for *every* target lacking its own --
     including the native x86_64 build the manpages step needs two `RUN`
     steps later. With bare names, that native build silently linked
     against the aarch64 sysroot's headers/libs and failed looking for
     `/usr/lib/ld-linux-aarch64.so.1`. `Containerfile.bootc` now scopes all
     three.
2. `podman run --rm --platform linux/arm64 <image> bootc --version` against
   a real tagged image, and `bootc container lint --skip var-tmpfiles
   --skip utf8` — both need the aarch64 base image (step 2) to exist first.

**Traps for whoever picks this up:**
- `--sysroot` on its own is not sufficient for a cross linker wrapper — it
  rewrites absolute paths *inside linker scripts*, but a bare `-lNAME` can
  still resolve against the host's own default library directories first.
  Always pair `--sysroot=` with an explicit `-L<sysroot>/usr/lib` (and
  `-rpath-link` for transitive needs). This one cost real time to find
  because it failed silently on the compile side (every `*-sys` crate's
  build.rs, which only needs headers/`.pc` files, worked fine) and only
  showed up at the final link.
- `os.archlinuxarm.org` is **not** the right host for package downloads —
  it 404s/redirects unhelpfully for direct `.pkg.tar.xz`/`.db` paths. Use
  `mirror.archlinuxarm.org`, confirmed working, already the one baked into
  `alarm-sysroot.conf`. (The bootstrap tarball URL in `docs/TEAM-BRIEF.md`,
  `os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz`, is a
  different, unrelated path on that host and is presumably fine — this trap
  is specifically about the per-arch package repo tree.)
- `podman cp` of a directory containing hardlinked files (glibc's
  `getconf`/`com_err.h`-style hardlinks) can fail non-deterministically
  depending on tar-stream ordering. Tar it yourself first
  (`tar -cf x.tar dir`), `podman cp` the single file, extract inside the
  container. Don't lose time on this twice.
- Do not set `CARGO_BUILD_JOBS=1` (or any of the three memory-guard env
  vars) for the **native** manpages/xtask step — they're only needed for the
  final aarch64 release link's memory pressure. Setting them globally for
  the whole session serializes the native dependency build too and wastes
  a large amount of wall clock for no reason. Scope them to the actual
  cross-build `RUN` step, which is what `Containerfile.bootc` already does
  correctly — just don't `export` them earlier when experimenting by hand.
- The native manpages/xtask step needs native `glib2 ostree openssl zstd`
  installed **in addition to** the cross toolchain — easy to forget since
  it looks redundant with the sysroot work, but it's a completely separate
  native link, not related to the aarch64 sysroot at all.
- Don't let `make install` run its default `completion` prerequisite against
  a cross-built binary — that executes the aarch64 binary during the build,
  which is the exact thing this whole approach exists to avoid. The Makefile
  patch in `Containerfile.bootc` handles this; if the Makefile changes
  upstream in a future version bump, re-check that the `sed` patterns still
  match before trusting them silently.
