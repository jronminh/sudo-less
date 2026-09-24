# Reproducing this on your own system

Goal: end up with a working `apt`/`dpkg` that installs `.deb`s into a prefix
you own (`~/.local` by default), with a real dependency resolver and database.

## Pick your path by what you have

| you have | path | extra tooling needed |
|---|---|---|
| **root / sudo** (Debian-family) | `scripts/env/build-on-host.sh` | **none** beyond the build packages |

The **root path is by far the lightest**: no user namespace, no subuid, no
`podman`. If you have sudo, use it.

### Root path (fresh Debian + sudo)

```sh
git clone <this repo> ~/sudo-less && cd ~/sudo-less
./scripts/env/build-on-host.sh
```

That installs the build packages with `apt`, fetches the sources, builds apt
and dpkg, installs them into `~/.local`, and writes the runtime config.

### Advanced: building without root

Most users never build: `bootstrap.sh` installs the prebuilt release. The
repo scripts only the root path above, and CI runs that same script inside a
`debian:trixie` container. Without root, any Debian environment in which
you can install `scripts/build-deps.list` and run `build-on-host.sh` will do,
for example:

- **a rootless container**: `podman run --rm -v "$PWD:$PWD" -w "$PWD"
  debian:trixie ./scripts/env/build-on-host.sh` (you are root inside; the
  admin must have installed `podman` and `uidmap` and given you subuid/subgid);
- **a rootfs** made with `mmdebstrap --mode=unshare` and entered with `bwrap`
  or `unshare -Urm` + `chroot`. `--mode=unshare` maps the subuid range to
  root, so write the rootfs as a tarball to stdout and unpack it yourself,
  since the mapped root cannot write into your `0700` home;
- **sudo-less itself**, in principle: install the build packages into
  `~/.local` with the userspace apt, point `PKG_CONFIG_PATH` and the compiler
  at the prefix, and build on the host. Untested.

## Prerequisites in detail

- **Host OS**: Debian or Ubuntu recommended. The build itself only needs a
  normal shell + `curl` (sources are fetched on the host — the sandbox never
  needs a downloader). The *result* only makes sense on dpkg-based systems,
  because `install-config.sh` seeds the local dpkg database from the host's
  `/var/lib/dpkg/status`.
- **Disk/RAM**: ~1.5 GB for the build tree; ~2 GB RAM to build.
- **`sqv`**: apt verifies signatures with the host's `sqv` (Debian's
  default verifier, in its own `sqv` package).

## Build dependencies

`scripts/build-deps.list` is the single source of truth, derived from apt's and
dpkg's `debian/control` Build-Depends. Docs and tests are disabled
(`-DWITH_DOC=OFF -DWITH_DOC_MANPAGES=OFF` for apt; dpkg man pages are still
generated, which is why `po4a` is present), so the doc/test-only tools are the
only things you could trim.

On a fresh Debian you can shortcut the explicit list with
`sudo apt-get build-dep -y apt dpkg` (needs `deb-src` entries) — it pulls a
superset for the *current* suite, which is fine.

## What is host-specific (override or edit)

| setting | default | override |
|---|---|---|
| install prefix | `$HOME/.local` | `PREFIX=/somewhere` |
| apt / dpkg version | `3.3.3` / `1.23.11` (apt also needs `APT_SHA1`) | `APT_VER`, `DPKG_VER` |
| source cache dir | `<repo>/src` | `SRC=/path` |
| architecture | auto-detected (`dpkg --print-architecture`, else `uname -m`) | `DEB_ARCH=`, `DEB_CPU=` |
| dpkg tuple data | `/usr/share/dpkg` | `-DDPKG_DATADIR` in `build-apt.sh` |
| apt suite/mirror | `sid`, `deb.debian.org` | `apt-dpkg/config/sources.list` |

The prefix config is generated from `apt-dpkg/config/apt.conf.d/00local-prefix.in` by
`install-config.sh`, substituting `@PREFIX@`, so the prefix is not hardcoded.
The architecture is auto-detected at build time and can be overridden with
`DEB_ARCH` / `DEB_CPU`.

## After building

```sh
export PATH="$HOME/.local/sbin:$HOME/.local/bin:$HOME/.local/usr/bin:$PATH"
apt-get update
apt-get install -y <package>
```

See `apt-dpkg-port.md` for how the Termux patches are retargeted and the
runtime caveats (seeded db, root-only maintainer scripts, PATH shadowing).
