# bootc for aarch64: build approach

Owner: BOOTC BINARY workstream. Companion to `Containerfile.bootc` and
`alarm-sysroot.conf` in the repo root. Read `docs/TEAM-BRIEF.md` and
`STATUS.md` first; this doc doesn't repeat the settled decisions recorded
there.

**Status as of this writing: the build actually ran to completion of the
dependency graph and hit a real, concrete link failure, discovered via a
background monitor a few minutes after the rest of this doc was written for
handoff.** This is a genuine blocker, not a "ran out of time" gap — see the
new section immediately below and the updated HANDOFF at the end. Everything
else in this doc (version pin, sysroot assembly, toolchain choice) still
stands; the `*-sys` crates all still linked clean. The failure is narrow and
specific: two libraries, not the whole approach.

## CONFIRMED BLOCKER: final link picks up host libm.so.6, not the sysroot's

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

**Hypothesis, UNCONFIRMED — did not verify by opening the file**: glibc's
`usr/lib/libm.so` is, like `usr/lib/libc.so`, a GNU ld linker script
(`GROUP ( /lib/libm.so.6 ... )` is the standard glibc pattern) with an
absolute path baked in. GNU ld's documented behavior is to treat a leading
`/` in a linker-script `GROUP`/`INPUT` path as sysroot-relative when
`--sysroot` is active — that's exactly what made `libc.so`'s equivalent
script work when reading it by hand earlier in this build. If `libm.so`'s
script also has a leading `/lib/...`, it should get the same rewrite. Since
it apparently didn't, either: (a) our sysroot's `usr/lib/libm.so` is not
actually present/not actually a script (worth literally `cat`-ing it — not
done yet), or (b) something about how `-lm` specifically gets resolved
(versus the implicit `-lc` pulled in by `-nodefaultlibs` handling) takes a
different code path in this ld version that doesn't apply the sysroot
rewrite the same way. This needs to be checked by hand, not guessed at
further — see HANDOFF.

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

## Wall clock — PARTIAL, build not finished

Measured on `oci-native-archlinux` (x86_64, 12 cores, 31 GiB RAM, per
`STATUS.md`), iterating live inside a long-running `podman run ... sleep
infinity` container (`bootc-cross`) rather than a single `podman build` of
`Containerfile.bootc` — the Containerfile itself has not yet been built
end-to-end with `podman build`.

| step | time | status |
| --- | --- | --- |
| install cross toolchain + rustup + native build deps (pacman) | ~15s + ~3s (two separate installs, gcc was missing on first pass) | done |
| `rustup toolchain install stable --profile minimal` + target add | ~13s | done |
| resolve + download 104-package ALARM aarch64 closure | ~1m30s (`-Sy` sync + `-Swu` resolve/download) | done |
| native manpages generation (`cargo run --release --package xtask -- manpages`), full native dependency build first, retried once after adding native ostree/glib2/openssl/zstd | not timed precisely; ran for several minutes (roughly 6-8 minutes by wall-clock observation between start and completion, not captured with `time`) | done, succeeded |
| aarch64 cross build (`cargo build --release --target aarch64-unknown-linux-gnu --bins`, `CARGO_BUILD_JOBS=1`) | **in progress when stopped**: started 06:32:01 UTC, still compiling dependency crates (last observed: `gio-sys`, `composefs-storage`) at 06:34:29 UTC — roughly 2.5 minutes in, nowhere near the final link. Left running in the background (see HANDOFF) but not watched to completion. | **NOT DONE** |

**No end-to-end `time` number for the full cross build exists.** Given
`CARGO_BUILD_JOBS=1` serializes codegen and bootc's dependency tree is large
(~150+ crates observed during the native manpages build), and given the
native *parallel* build of essentially the same dependency graph took on the
order of several minutes with all 12 cores, expect the serialized aarch64
build to take meaningfully longer — this is a guess, not a measurement.

## Verification — NOT DONE

`podman run --rm --platform linux/arm64 <image> bootc --version` — not run.
No image exists yet; the cross build never reached a linked `bootc` binary
in this session.

`bootc container lint --skip var-tmpfiles --skip utf8` on a trivial image —
not run, same reason. Expectation (UNCONFIRMED) based on bootc-dev/bootc#1481
still being open as of 2026-08-25 with no merged fix: the skips are still
required under qemu-user emulation. This needs empirical confirmation
against an actual v1.16.10 aarch64 binary once one exists — the issue's
open/closed state on GitHub is not proof of behavior in this specific
version, just strong circumstantial evidence.

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

**Half-done, exactly where it stopped:**
- The live cross build (`cargo build --release --target
  aarch64-unknown-linux-gnu --bins`) was mid-flight when work stopped —
  started 06:32:01 UTC, last seen compiling `gio-sys`/`composefs-storage` at
  06:34:29 UTC, `CARGO_BUILD_JOBS=1` so it's serialized and slow. **It may
  still be running** in the background container `bootc-cross` (started
  with `podman run -d --name bootc-cross -v <scratchpad>:/sp:Z
  docker.io/archlinux/archlinux:latest sleep infinity`) — check with `podman
  exec bootc-cross bash -c 'ps aux | grep rustc'` and `tail -f
  .../scratchpad/cross-build.log`. If it finished on its own, the next step
  is `make install-all DESTDIR=/output` inside that same container (after
  the `target/release` symlink swap), then strip, then actually build a test
  image and run the verification commands in the Verification section
  above, none of which have been run yet.
- Nothing from this build has been packaged into an actual container image.
  `Containerfile.bootc` exists as a file but has never been fed to `podman
  build`.
- Wall-clock table above is partial by construction — the one number that
  actually matters (total aarch64 cross build time) is missing.

**What I'd do next, in order:**
1. Check whether `bootc-cross`'s background build finished; if not, either
   let it finish or kill it and re-run fresh via an actual `podman build -f
   Containerfile.bootc .` instead (cleaner, and it's what needs to happen
   eventually anyway — the hand-iterated container was for speed of
   debugging, not the real artifact).
2. Once a binary exists, run the two verification commands
   (`bootc --version` under `--platform linux/arm64`, and `bootc container
   lint --skip var-tmpfiles --skip utf8` against a trivial test image) and
   record actual results, not expectations.
3. Time the full cross build for real with `time`, end to end, so the wall
   clock table has a real number instead of a guess.
4. Confirm the `target/release` symlink swap and the Makefile `sed` patch
   both do what they're supposed to by actually running `make install-all
   DESTDIR=/output` and inspecting `/output` against what
   `Containerfile.base`'s `/output` looks like for x86_64.

**Traps for whoever picks this up:**
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
