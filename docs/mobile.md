# Mobile & tablets (Mobian)

Mobian devices — **ARM64 phones** and **x86_64 tablets** — are first-class
targets. Architecture is auto-detected (`DEB_ARCH`/`DEB_CPU`), so no edits are
needed for either.

## Option A — build on the device (simplest)

If you have `sudo` on the device:

```sh
git clone <repo> ~/sudo-less && cd ~/sudo-less
sudo bash scripts/install-build-deps.sh
./scripts/build-on-host.sh
```

This is lighter than bootstrapping a rootfs. On an x86 tablet it is fast
(native); on an ARM phone it works but is slow and wants ~2 GB RAM.

If you have **no root**, use the rootfs path instead (`make-buildroot.sh` +
`build-in-rootfs.sh`); unprivileged user namespaces must be enabled, and `bwrap`
is used because `proot` needs `ptrace` (often blocked by
`kernel.yama.ptrace_scope`).

## Option B — build once, copy to the phone

The build is **relocatable**: apt is linked with `$ORIGIN`-relative RPATH, and
its configuration is generated from the prefix and also used as `APT_CONFIG`.
So a prefix built on one machine runs from any path on another (same arch).

**On the builder** (e.g., a fast x86 tablet — build for the target's arch):

```sh
./scripts/build-on-host.sh            # installs into ~/.local
ARCH="$(dpkg --print-architecture)"
tar -C ~/.local -czf "apt-home-$ARCH.tar.gz" bin sbin lib share
```

**On the phone:**

```sh
mkdir -p ~/.local
tar -xzf "apt-home-<arch>.tar.gz" -C ~/.local
# regenerate config for THIS prefix, seed the db from the phone's system,
# and add the prefix to the shell PATH
PREFIX="$HOME/.local" bash ~/sudo-less/scripts/install-config.sh
```

Open a new shell, then:

```sh
apt-get update
apt-get install -y ripgrep
```

## Why it is relocatable

- **RPATH** — apt binaries and methods are linked with
  `$ORIGIN/../lib;$ORIGIN/../..`, so `libapt-pkg.so.6.0` is found relative to
  wherever the prefix lives.
- **Config** — `$PREFIX/etc/apt/apt.conf.d/00local-prefix` is generated with
  every `Dir::` path (state, cache, etc, methods, dpkg) and is exported as
  `APT_CONFIG` by the shell setup, so apt follows the prefix regardless of the
  paths baked in at compile time.
- **dpkg** — is passed `--admindir` / `--instdir` explicitly (apt does not do
  this itself), so its database and install root follow the config too.

## GUI apps in the launcher (Phosh)

Phosh/GNOME discovers launchers by scanning `$XDG_DATA_DIRS/*/applications`,
and that comes from the **session** environment — a shell rc is not enough.
`install-config.sh` runs `install-session-env.sh`, which writes:

```
~/.config/environment.d/50-sudo-less.conf
```

with `PATH` and `XDG_DATA_DIRS` pointing at the prefix, so packages installed
into `~/.local/usr/share/applications` appear in the launcher (and their icons
resolve). **Re-login** for the session to pick it up.

Caveats:
- `.desktop` files that use a bare `Exec=foo` resolve via the session `PATH` ✅;
  those using an absolute `Exec=/usr/bin/foo` point at the system path ❌.
- GSettings schemas, D-Bus services and MIME entries under `XDG_DATA_DIRS` can
  work; **systemd user units do not** register.

## Caveats

- **Same architecture required** — an `arm64` tarball only runs on `arm64`.
- The build machine and the phone should both be **Debian-family** (the db is
  seeded from `/var/lib/dpkg/status`).
- `gpgv` must be available on the phone for apt signature checks.
- `APT_CONFIG` matters: run apt through a shell that sourced the prefix setup
  (`install-config.sh` writes it to `~/.bashrc` / `~/.profile`), or set it
  manually to `$PREFIX/etc/apt/apt.conf.d/00local-prefix`.
