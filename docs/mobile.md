# Mobile & tablets (Mobian)

Mobian devices — **ARM64 phones** and **x86_64 tablets** — are first-class
targets. Architecture is auto-detected (`DEB_ARCH`/`DEB_CPU`), so no edits are
needed for either.

## Option A — build on the device (simplest)

If you have `sudo` on the device:

```sh
git clone <repo> ~/sudo-less && cd ~/sudo-less
sudo bash scripts/bootstrap/install-build-deps.sh
./scripts/env/build-on-host.sh
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
./scripts/env/build-on-host.sh            # installs into ~/.local
ARCH="$(dpkg --print-architecture)"
tar -C ~/.local -czf "apt-home-$ARCH.tar.gz" bin sbin lib share
```

**On the phone:**

```sh
mkdir -p ~/.local
tar -xzf "apt-home-<arch>.tar.gz" -C ~/.local
# regenerate config for THIS prefix, seed the db from the phone's system,
# and add the prefix to the shell PATH
PREFIX="$HOME/.local" bash ~/sudo-less/scripts/setup/install-config.sh
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
- **Config** — `$PREFIX/etc/apt/apt.conf.d/00local-prefix` is generated
  with every `Dir::` path (state, cache, etc, methods, dpkg, apt-key,
  solvers, planners) and exported as `APT_CONFIG` by the shell setup, so
  apt follows the prefix regardless of what's baked in at compile time.
  The last three (`apt-key`, solvers, planners) were missing until a
  genuinely fresh test — a different user, a container with no
  bind-mounted `$HOME` — caught it: `apt-get update` failed with
  `Couldn't execute /home/<builder>/.local/bin/apt-key`, a
  `CMAKE_INSTALL_FULL_BINDIR`-derived compile-time default nothing had
  overridden, invisible as long as testing happened on the same user/path
  that built the prefix. See [*Testing a fresh
  install*](#testing-a-fresh-install) below.
- **dpkg** — is passed `--admindir` / `--instdir` explicitly (apt does not do
  this itself), so its database and install root follow the config too.

## Testing a fresh install

Testing relocatability on the *same* machine that built the prefix hides
bugs: paths baked in at build time (like the `apt-key` one above) happen to
still be correct there, since the builder's own username/path is still the
one in `$PREFIX`. A genuinely fresh test needs a different user, a different
path, or both — reusing Option B's tarball:

```sh
# on the builder
./scripts/env/build-on-host.sh
ARCH="$(dpkg --print-architecture)"
tar -C ~/.local -czf "apt-home-$ARCH.tar.gz" bin sbin lib share
```

The actual target scenario: an isolated container (no bind-mounted `$HOME`
— that would just retest the same paths) running as an unprivileged user
with no `sudo`.

```sh
podman run -d --name freshtest debian:sid sleep infinity
podman exec freshtest bash -c 'apt-get update -qq && apt-get install -y -qq git gpgv ca-certificates'
podman exec freshtest useradd -m -s /bin/bash tester
podman cp "apt-home-$ARCH.tar.gz" freshtest:/tmp/
podman exec freshtest chown tester:tester /tmp/apt-home-$ARCH.tar.gz

podman exec --user tester -w /home/tester freshtest bash -c '
  git clone --depth 1 https://github.com/<you>/sudo-less
  mkdir -p ~/.local && tar -xzf /tmp/apt-home-*.tar.gz -C ~/.local
  cd sudo-less && PREFIX=$HOME/.local bash scripts/setup/install-config.sh
  export PATH="$HOME/.local/sbin:$HOME/.local/bin:$HOME/.local/usr/bin:$PATH"
  export APT_CONFIG="$HOME/.local/etc/apt/apt.conf.d/00local-prefix"
  apt-get update && apt-get install -y jq && bash scripts/catalog/recipes.sh verify
'
```

`~/.local/share` on a real desktop often holds unrelated large data too
(rootless podman's own storage lives under `share/containers`; Flatpak under
`share/flatpak`) — `tar` the whole `share/` naively and you may tar
gigabytes of unrelated content. Exclude what you know isn't apt/dpkg's own
before copying it into the container.

If a package is seeded on the builder but not on the fresh target — most
commonly `python3` itself, when the target is more minimal — it actually
gets installed there instead of skipped, exposing failures the builder's
seeded db was hiding. This is expected, not a bug: see
`docs/working-packages.md`'s "seeded db" note.

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
