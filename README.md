# apt-home — unprivileged apt + dpkg in `~/.local`

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

Requires a Debian sid environment with the build deps listed in the two build
scripts. On this host that is a rootless `podman` container (distrobox's
first-enter integration is flaky here):

```sh
podman run -d --name aptbuild -v "$HOME:$HOME:rw" debian:sid sleep infinity
podman exec -it aptbuild apt-get update
podman exec -it aptbuild apt-get install -y build-essential cmake xsltproc \
  docbook-xsl gettext po4a libtool autoconf automake autopoint pkg-config \
  libgcrypt20-dev libgnutls28-dev libgpg-error-dev libcurl4-openssl-dev \
  liblz4-dev liblzma-dev libbz2-dev zlib1g-dev libzstd-dev libxxhash-dev \
  libdb-dev libseccomp-dev libmd-dev libudev-dev libperl-dev libncurses-dev
podman exec -it aptbuild bash /home/master/apt-home/scripts/build-apt.sh
podman exec -it aptbuild bash /home/master/apt-home/scripts/build-dpkg.sh
```

Then install the runtime config (on the host):

```sh
./scripts/install-config.sh
```

## Usage

```sh
export PATH="$HOME/.local/sbin:$HOME/.local/bin:$HOME/.local/usr/bin:$PATH"
apt-get update
apt-get install -y <package>     # installs into ~/.local/usr, ~/.local/lib, ...
dpkg -l                          # our database, not the system's
```

apt calls dpkg with `--instdir=$HOME/.local` and `--force-script-chrootless`
via `$PREFIX/etc/apt/apt.conf.d/00local-prefix`.

## Caveats

- **Seeded db is a footgun.** `apt upgrade` / `apt remove` will try to
  "upgrade"/"remove" *system* packages into/from `~/.local`. Pin seeded packages
  before relying on apt for anything other than new installs.
- **Maintainer scripts that need root** (`debconf`, `adduser`, `systemctl`,
  `ldconfig`) still fail. Good for leaf tools; not for system-level packages
  (do **not** install `libc6` this way).
- **PATH shadowing:** with `~/.local/bin` early in `PATH`, the bare `apt`/`dpkg`
  for user `master` become these userspace builds. Use full paths if unsure.
- `apt-key` verification needs a real `gpgv` binary on PATH (Debian ships it in
  its own `gpgv` package; the host had only `gpg`).
- Hardcoded `amd64`/`x86_64` arch and prefix `/home/master/.local` in the
  generated config; adjust `common.sh` / build args for another machine.

## File map

```
scripts/common.sh        shared vars, fetch/apply_patches helpers
scripts/build-apt.sh     fetch apt 2.8.1, patch, retarget, cmake, install
scripts/build-dpkg.sh    fetch dpkg 1.22.6, patch, autogen, configure, install
scripts/install-config.sh  runtime config + dpkg status seeding
patches/apt/termux/      Termux's 14 apt patches (verbatim)
patches/apt/local/       our GCC-16 fixes
patches/dpkg/termux/     Termux's 9 dpkg patches + configure.diff (verbatim)
config/                  sources.list, apt.conf.d/00local-prefix
```
