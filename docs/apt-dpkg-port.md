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
Android NDK (`__ANDROID__` defined). This repo retargets the same patches to
`$PREFIX=$HOME/.local` on glibc.

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
4. **GCC 16 fixes** (`patches/apt/local/0001-gcc16-fixes.patch`): `<cstdint>`
   for `uint8_t`, and a `RAMFS_MAGIC` fallback.
5. **dpkg needs `__ANDROID__`.** Upstream dpkg has zero `__ANDROID__`
   references; Termux's patches wrap the root-only bits (the superuser check in
   `lib/dpkg/dbmodify.c`, `chown` in `src/main/archives.c`) in
   `#ifndef __ANDROID__`. Compiling with `-D__ANDROID__` activates them —
   otherwise dpkg dies with "requested operation requires superuser privilege".
6. **Traditional alternate-root install.** dpkg is run with
   `--instdir=$PREFIX`, so a package's `./usr/bin/foo` lands in
   `~/.local/usr/bin/foo` (a real rootfs layout). `--force-script-chrootless`
   is required because dpkg would otherwise `chroot()` into the instdir (needs
   root). `--force-not-root` covers remaining permission errors.
7. **Dependency seeding.** Because our dpkg db starts empty, apt would try to
   install the whole `libc6` chain into the prefix. We seed
   `$PREFIX/var/lib/dpkg/status` from the system's, so apt sees system libraries
   as already installed and only installs leaf packages.

## Build

Two equivalent routes (see `../methodology.md`):

```sh
# podman container as the build rootfs
./scripts/env/build-in-container.sh

# podman-free: real rootfs via mmdebstrap, entered with bwrap
./scripts/env/make-buildroot.sh
./scripts/env/build-in-rootfs.sh
```

Then install the runtime config (done automatically by the two scripts above):

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
  `ldconfig`) still fail. Good for leaf tools; not for system-level packages
  (do **not** install `libc6` this way).
- **PATH shadowing:** with `~/.local/bin` early in `PATH`, the bare `apt`/`dpkg`
  for user `master` become these userspace builds. Use full paths if unsure.
- `apt-key` verification needs a real `gpgv` binary on PATH (Debian ships it in
  its own `gpgv` package; this host had only `gpg`).
- Architecture is auto-detected at build time (`scripts/common.sh`) and the
  prefix is generated from `$PREFIX`, so both are portable; override with
  `DEB_ARCH` / `DEB_CPU` / `PREFIX` if needed.
