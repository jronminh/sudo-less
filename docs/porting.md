# Reproducing this on your own system

Goal: end up with a working `apt`/`dpkg` that installs `.deb`s into a prefix
you own (`~/.local` by default), with a real dependency resolver and database.

## Pick your path by what you have

| you have | path | extra tooling needed |
|---|---|---|
| **root / sudo** (Debian-family) | `scripts/env/build-on-host.sh` | **none** beyond the build packages |
| no root, but user namespaces + subuid | `scripts/env/make-buildroot.sh` + `scripts/env/build-in-rootfs.sh` | `mmdebstrap`, `bwrap` |
| no root, but rootless containers | `scripts/env/build-in-container.sh` | rootless `podman` |

The **root path is by far the lightest**: no user namespace, no subuid, no
`podman`, no `mmdebstrap`, no `bwrap`. If you have sudo, use it.

### Root path (fresh Debian + sudo)

```sh
git clone <this repo> ~/sudo-less && cd ~/sudo-less
./scripts/env/build-on-host.sh
```

That installs the build packages with `apt`, fetches the sources, builds apt
and dpkg, installs them into `~/.local`, and writes the runtime config.

### No-root path (userns + rootfs)

Requires your admin to enable user namespaces and give you subuid/subgid
(see `../admin/third-party/admin-prep.sh` for what that entails). Then:

```sh
./scripts/env/make-buildroot.sh        # builds a real Debian rootfs, no root
./scripts/env/build-in-rootfs.sh       # builds inside it via bwrap
```

### No-root path (rootless podman)

```sh
./scripts/env/build-in-container.sh
```

## Prerequisites in detail

- **Host OS**: Debian or Ubuntu recommended. The build itself only needs a
  normal shell + `curl` (sources are fetched on the host — the sandbox never
  needs a downloader). The *result* only makes sense on dpkg-based systems,
  because `install-config.sh` seeds the local dpkg database from the host's
  `/var/lib/dpkg/status`.
- **No-root paths only**: unprivileged user namespaces (`sysctl
  kernel.unprivileged_userns_clone=1`), `/etc/subuid` + `/etc/subgid` for your
  user, and (for podman) `newuidmap`/`newgidmap`, `fuse-overlayfs`,
  `slirp4netns`. `kernel.yama.ptrace_scope` does **not** matter — we use
  `bwrap`, not `proot`.
- **Disk/RAM**: ~1.5 GB for a rootfs + build tree; ~2 GB RAM to build.
- **`gpgv`**: apt's signature verification needs a real `gpgv` binary at
  runtime (Debian ships it in its own `gpgv` package).

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
| apt / dpkg version | `2.8.1` / `1.22.6` | `APT_VER`, `DPKG_VER` |
| source cache dir | `<repo>/src` | `SRC=/path` |
| architecture | auto-detected (`dpkg --print-architecture`, else `uname -m`) | `DEB_ARCH=`, `DEB_CPU=` |
| dpkg tuple data | `/usr/share/dpkg` | `-DDPKG_DATADIR` in `build-apt.sh` |
| apt suite/mirror | `sid`, `deb.debian.org` | `config/sources.list` |

The prefix config is generated from `config/apt.conf.d/00local-prefix.in` by
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
