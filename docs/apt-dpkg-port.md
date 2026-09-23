# Userspace apt + dpkg in `~/.local`

A userspace port of **Termux's apt and dpkg** to a regular (rootless) Debian
box. It installs Debian `.deb` packages into `~/.local` **without root**, with a
real dependency resolver and a real dpkg database.

Status: **working.** `apt-get update`, `apt-cache`, `apt-get download` and
`apt-get install` (unpack + configure) all function; installed binaries run.

```
$ ~/.local/bin/apt-get install -y hello
...
Unpacking hello (2.12.3-1) ...
Setting up hello (2.12.3-1) ...
$ ~/.local/usr/bin/hello
Hello, world!
```

## What "Termux's apt/dpkg" actually is

Neither is a fork. Both are the **upstream Debian projects plus a patch set**
maintained in [`termux/termux-packages`](https://github.com/termux/termux-packages):

| Tool | Base | Patches |
|---|---|---|
| apt  | Debian apt 2.8.1 | `packages/apt/*.patch` (14) |
| dpkg | Debian dpkg 1.22.6 | `packages/dpkg/*.patch` (9) + `configure.diff` |

Termux builds these against `$PREFIX=/data/data/com.termux/files/usr` with the
Android NDK (`__ANDROID__` defined). sudo-less carries a fork of those
patches, cut down to what a prefix on Debian needs and built without
`__ANDROID__`: [`../patches/UPSTREAM.md`](../patches/UPSTREAM.md) maps every
Termux patch to kept, adapted or dropped.

## Layout produced under `$PREFIX` (`~/.local`)

```
bin/      apt apt-get apt-cache apt-config dpkg dpkg-deb dpkg-query update-alternatives
sbin/     start-stop-daemon
lib/      libapt-pkg.so.6.0, apt/methods/*, dpkg/...
etc/apt/  sources.list, apt.conf.d/00local-prefix
var/lib/apt/       apt lists/state
var/lib/dpkg/      dpkg database (status, info, ...)
var/cache/apt/     downloaded .debs
```

## How the port works (the non-obvious bits)

1. **`@TERMUX_PREFIX@` is a self-contained rootfs.** Termux's prefix contains
   its own `bin/sh`, `bin/gzip`, etc. `~/.local` does not. So the substitution
   is split:
   - `@TERMUX_PREFIX@/bin/` → `/usr/bin/` (helper programs apt shells out to)
   - `@TERMUX_PREFIX@/tmp`  → `/tmp`
   - remaining `@TERMUX_PREFIX@` (apt's own `etc/apt`, apt-key keyrings) → `$PREFIX`
   - `DPkg::Path` → `$PREFIX/bin` + the system PATH
2. **Isolated database.** `CMAKE_INSTALL_FULL_LOCALSTATEDIR=$PREFIX/var` makes
   apt derive `Dir::State::status = $PREFIX/var/lib/dpkg/status`. It never reads
   the system `/var/lib/dpkg/status`.
3. **RPATH.** apt is installed with `RPATH=$PREFIX/lib` so it loads our
   `libapt-pkg.so.6.0`, not the system `libapt-pkg.so.7.0`.
4. **GCC 16 fixes** (`patches/apt/0008-gcc16-fixes.patch`): `<cstdint>`
   for `uint8_t`, and a `RAMFS_MAGIC` fallback.
5. **dpkg without root checks.** `patches/dpkg/0001-no-superuser-check.patch`
   removes the superuser check in `lib/dpkg/dbmodify.c` (otherwise dpkg dies
   with "requested operation requires superuser privilege"), `0002-no-chown`
   the `chown` calls, `0003-no-ldconfig-check` the start-up check for
   `ldconfig` on `PATH`. Termux guards the same changes with
   `#ifndef __ANDROID__`; the fork makes them plain patches.
6. **Traditional alternate-root install.** dpkg is run with
   `--instdir=$PREFIX`, so a package's `./usr/bin/foo` lands in
   `~/.local/usr/bin/foo` (a real rootfs layout). `--force-script-chrootless`
   is required because dpkg would otherwise `chroot()` into the instdir (needs
   root). `--force-not-root` covers remaining permission errors.
7. **Dependency seeding.** Because our dpkg db starts empty, apt would try to
   install the whole `libc6` chain into the prefix. We seed
   `$PREFIX/var/lib/dpkg/status` from the system's, so apt sees system libraries
   as already installed and only installs leaf packages.

## Beyond Termux's patches: our own changes

Termux patched apt and dpkg for its goal: Android, one prefix, no root at all.
Ours differs: packages from the *host's own* Debian into `~/.local`, next to a
system that stays in charge. The rule for our apt and dpkg:

> **Patch only as far as native needs: apt and dpkg working without root in
> a prefix, from a relocatable build. Everything else stays upstream.**

What happens around a package (scope, shims, overlay wrappers, launchers) is
the pipeline's job, through apt's hooks ([`design.md`](design.md)); how an
installed program finds its files at run time is the mechanisms' job
([`mechanisms.md`](mechanisms.md)). Neither is a reason to patch.

### The fork

Our patch set becomes a fork of Termux's, cut down to that rule, and it
**follows upstream**: at each apt or dpkg release in Debian, the patches are
rebased onto it, instead of pinning old versions (today apt 2.8.1 and dpkg
1.22.6). Keeping the patches few is what keeps the rebase cheap. The
compatibility baseline in [`release.md`](release.md) still holds: each
rebased version must build on it.

```
patches/
├── UPSTREAM.md     the termux-packages commit it started from; per Termux
│                   patch: kept, adapted or dropped, and why
├── apt/series      ordered list, one reason per line
├── dpkg/series
└── */NNNN-*.patch  each with a header: origin, change, GPL-2.0-or-later
```

Step 1 is done: [`../patches/UPSTREAM.md`](../patches/UPSTREAM.md) has the
full table. Both builds, old and forked, were made as a non-root user and
run through the same checks (`dpkg -i`, `apt install ./x.deb`, removal,
`dpkg --audit`, an apt pattern) with the same results. The only difference:
the old dpkg warned that `mandoc` is missing (Termux's `mandoc_hook`). Both
still write their log to `/var/log/dpkg.log` and point alternatives at
`/etc/alternatives`; that is step 3.

- **Kept or adapted:** what native needs: prefix paths and no root checks
  in apt (Termux `0004`, `0007`, `0010`), no superuser check, no `chown` and
  no `ldconfig` check in dpkg; small build and HTTP fixes (`0000`, `0001`,
  `0005`, `0008`).
- **Dropped:** the NDK fix `0012`, the apt patches that act only under
  `__ANDROID__` (`0002`, `0003`, `0006`, `0009`), `0011` (Debian's default of
  not keeping downloaded `.deb` files is better for the user's disk), `0013`
  (renames apt's search patterns away from Debian's), and in dpkg
  `configure.diff`, the hard-link and `EROFS` workarounds, `mandoc_hook` and
  `scanpackages`.
- **No `-D__ANDROID__` for dpkg.** It used to switch on *every* Android
  branch of Termux's dpkg patches. Each kept change is now a plain patch, so
  the `series` file says exactly how our dpkg differs from Debian's.
- **Ours, numbered from `0100`**, all at the native level:

| patch | fixes | status |
|---|---|---|
| **A. dpkg: locate itself at run time** | the prebuilt dpkg's datadir, sysconfdir and log path are the build machine's (`/root/.local/share/dpkg`, so `dpkg-maintscript-helper` fails; `/var/log/dpkg.log`). `dpkg.cfg` is read from that same compiled-in sysconfdir, so no config can move it; deriving the paths from `/proc/self/exe` makes the prebuilt relocatable | planned |
| **B. a two-layer package database** | apt and dpkg read the host's `/var/lib/dpkg/status` directly as a read-only lower layer ("installed, never touch"); the prefix database holds only the user's packages. Replaces seeding, `lock-seeded.sh` and the sync stage; a stale seed is what makes apt report "held broken packages". Touches apt's resolver and dpkg's configure-time dependency check, so it is the largest | proposed; measure first how many packages a stale seed blocks |
| **C. prefix hygiene at unpack** | drop setuid/setgid bits and file capabilities, and ignore the host's `statoverride`: meaningless in a prefix, and a setuid-to-user file in `~/.local` is a risk | planned |
| **D. record a failing maintainer script** | mark the package and report it, instead of leaving it half-configured and wedging every later install | deferred; only if stage 2 and the shims still leave many failures |

To check before patching, since dpkg may already do it: `update-alternatives`
honours `DPKG_ROOT` in current dpkg, which may put the links in the prefix
with no patch (it is the most common RISKY signal); triggers of seeded system
packages (`man-db`, `fontconfig`, `shared-mime-info`) have no handler in the
prefix, and prefix-aware versions belong in stage 4, not in dpkg.

Signature verification needs no patch: current Debian ships `sqv` instead
of `gpgv`, which apt 2.8.1 cannot use, so a new account cannot `apt-get
update` today; following upstream brings apt 3.x, which verifies with `sqv`.

The fork is made in steps: first the same behaviour as today (done), then
the rebase onto current upstream, then our patches.

### Not patched, on purpose

| problem | where it is solved instead |
|---|---|
| maintainer scripts writing to `/etc` (`add-shell` → `/etc/shells`) | dpkg already exports `DPKG_ROOT` to scripts in a chrootless install, and Debian is making scripts honour it; `add-shell` already writes to `$PREFIX/etc/shells`. Seeding the few `/etc` files scripts expect is enough |
| maintainer scripts calling root-only helpers (`py3compile`, `update-rc.d`, `systemctl`) | shims on `DPkg::Path` |
| a failing script wedging the prefix | stage 2 of the pipeline stops unsafe scripts before dpkg runs; a recovery command for what slips through |
| paths compiled into binaries | the overlay, applied automatically by wrappers |
| language search paths (`@INC`, `JAVA_HOME`, …) | ecosystem environment hooks |

## Build

With root, on the host (without root, see `porting.md`):

```sh
./scripts/env/build-on-host.sh
```

Then install the runtime config (done automatically by the script):

```sh
./scripts/setup/install-config.sh [--reseed]
```

## Usage

`install-config.sh` (run by every build path) adds the prefix dirs to your
shell PATH automatically via `install-shell-path.sh`, so a new shell can run
installed packages directly. To do it by hand:

```sh
export PATH="$HOME/.local/sbin:$HOME/.local/bin:$HOME/.local/usr/bin:$PATH"
apt-get update
apt-get install -y <package>     # installs into ~/.local/usr, ~/.local/lib, ...
dpkg -l                          # our database, not the system's
```

apt calls dpkg with `--instdir=$HOME/.local` and `--force-script-chrootless`
via `$PREFIX/etc/apt/apt.conf.d/00local-prefix`.

## Caveats

- **The seeded db is locked by default.** `install-config.sh` runs
  `scripts/setup/lock-seeded.sh lock`, marking seeded (system) packages as dpkg
  `hold` so apt cannot accidentally upgrade/remove them into/from `~/.local`;
  packages you install yourself stay upgradable. `lock-seeded.sh unlock`
  releases them (only if you know why).
- **Maintainer scripts that need root** (`debconf`, `adduser`, `systemctl`,
  `ldconfig`) still fail, and a failing one can wedge the prefix. Good for
  leaf tools; not for system-level packages (do **not** install `libc6` this
  way). See [our own changes](#beyond-termuxs-patches-our-own-changes).
- **PATH shadowing:** with `~/.local/bin` early in `PATH`, the bare `apt`/`dpkg`
  for user `master` become these userspace builds. Use full paths if unsure.
- `apt-key` verification needs a real `gpgv` binary on PATH. Current Debian
  ships `sqv` instead, so a new account's `apt-get update` fails until `gpgv`
  is provided; following upstream (apt 3.x) fixes it, see
  [our own changes](#beyond-termuxs-patches-our-own-changes).
- Architecture is auto-detected at build time (`scripts/common.sh`) and the
  prefix is generated from `$PREFIX`, so both are portable; override with
  `DEB_ARCH` / `DEB_CPU` / `PREFIX` if needed.
