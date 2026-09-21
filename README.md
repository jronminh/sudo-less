# sudo-less

> Run, build, and install software on Debian **as an unprivileged user** — no
> `sudo`, no root — including a **userspace `apt` + `dpkg`** that installs
> `.deb` packages into `~/.local`.

![license: GPL-3.0-or-later](https://img.shields.io/badge/license-GPL--3.0--or--later-blue)
![platform: Debian](https://img.shields.io/badge/platform-Debian-A81D33)
![root: not required](https://img.shields.io/badge/root-not%20required-brightgreen)

`sudo-less` is both a small toolkit and a recorded experiment: take a normal
Debian box, remove standing root from the daily user, and **still keep it fully
usable** — you can build from source, install packages, and manage them, without
ever escalating.

## Highlights

- **Userspace apt/dpkg.** Debian **apt 2.8.1** + **dpkg 1.22.6**, built from
  [Termux's patches](https://github.com/termux/termux-packages) retargeted to
  `~/.local`, with real dependency resolution and a real dpkg database
  (`apt install`, `remove`, `upgrade`, `dpkg -l`, …).
- **No standing privileges.** Builds run in a *scoped, disposable* root — a
  user namespace, a real rootfs, or a rootless container — never on the host.
- **Reproducible.** One command per path: with root, without root, or in a
  container.
- **Predict before you install.** `check-package.sh` scores any package as
  `OK` / `RISKY` / `UNLIKELY` from its cached `.deb` — no install.
- **It just runs.** After setup, `apt-get install foo` works and `foo` is on
  your PATH in a new shell.

## Quick start

```sh
git clone https://github.com/jronminh/sudo-less && cd sudo-less

# 1. Have root/sudo on Debian? lightest path (no sandbox at all):
./scripts/build-on-host.sh

# 2. No root, but user namespaces + subuid: real rootfs, entered with bwrap
./scripts/make-buildroot.sh && ./scripts/build-in-rootfs.sh

# 3. No root, rootless podman available:
./scripts/build-in-container.sh
```

Then, in a new shell:

```sh
apt-get update
apt-get install -y ripgrep htop jq        # into ~/.local
dpkg -l                                    # your own database
```

See [`docs/porting.md`](docs/porting.md) for prerequisites and overrides, and
[`docs/working-packages.md`](docs/working-packages.md) for what installs well.

## Why this exists

The usual way to harden a box is to take capabilities away — and then it stops
being usable. This is the opposite experiment: **remove standing root from the
daily user, keep the machine fully usable.**

The key idea is that **root inside a sandbox is not root on the host**:

- The daily user has no `sudo`, so there is nothing to phish and a compromised
  session owns only its own files.
- When real privileges are needed, they are obtained *scoped and disposable*:
  a user namespace (`unshare -Ur`), a real rootfs (`mmdebstrap`), or a rootless
  container (`podman`) is a full, normal Debian where you are root *inside it* —
  while the host's `/usr`, `/etc`, `/var` are untouched.
- A few narrowly-scoped **polkit** actions cover genuinely privileged runtime
  needs (power, network, storage, a small service allowlist).
- The heavy lifting (retargeting and building apt/dpkg) happens in that scoped
  root; only the finished artifacts land in `~/.local`, and the build
  environment is thrown away and rebuilt from scripts.

The result: the transformation is *easy* (a real root to work with) and the
host stays *safe* (that root never reaches it).

## How it works

- **apt** is upstream Debian apt + Termux's 14 patches; **dpkg** is upstream
  dpkg + Termux's 9 patches. Neither is a fork.
- `@TERMUX_PREFIX@` (a self-contained Termux rootfs) is remapped: helper
  binaries → `/usr/bin`, `tmp` → `/tmp`, apt's own `etc/apt` → `$PREFIX`.
- **dpkg is compiled with `-D__ANDROID__`** so Termux's patches activate and
  skip the root-only steps (superuser check, `chown`) — i.e. it behaves like
  Termux's dpkg.
- Packages install with `--instdir=$PREFIX` (a real rootfs layout:
  `$PREFIX/usr/bin`, …) plus `--force-script-chrootless`.
- The local dpkg database is **seeded from the system's**, so apt treats
  already-installed libraries as satisfied and only installs leaf packages.

Full write-up: [`docs/apt-dpkg-port.md`](docs/apt-dpkg-port.md). Methodology
behind the no-root build paths: [`docs/methodology.md`](docs/methodology.md).

## What works

Great for **user-space tooling and dev libraries**: CLI tools, interpreters and
toolchains, `-dev` packages, fonts, single-binary apps.

Not a system package manager: packages that need root in their maintainer
scripts (services, `systemd`, `adduser`, `debconf`), Python *applications*
(absolute `dist-packages` paths), or setuid/PAM/kernel bits will not work.
Details and the `check-package.sh` predictor:
[`docs/working-packages.md`](docs/working-packages.md).

## Repository layout

```
docs/        methodology, porting, apt-dpkg-port, working-packages, polkit, roles, hardening
scripts/     build-apt, build-dpkg, build-on-host, make-buildroot, build-in-rootfs,
             build-in-container, install-config, install-shell-path, check-package, test-packages
patches/     apt/{termux,local}, dpkg/termux   (verbatim upstream patches + our fixes)
config/      apt.conf.d template, sources.list
tools/       deb2home.sh   (extract a .deb into $HOME without root)
admin/       root-side scripts run by the admin account (example setup)
```

## Scope & status

A **personal experiment** recorded as a reusable toolkit. The user names
`mobian` (admin) and `master` (unprivileged) are **example personas** for a
two-user split; substitute your own. Host-specific details (network ranges, SSH
key names, absolute home paths) are genericised, and the prefix config is
generated from `$PREFIX` rather than hardcoded.

Targets Debian-family systems. Nothing here is guaranteed — read it alongside
`docs/methodology.md`. Issues and PRs welcome.

## License

[GPL-3.0-or-later](LICENSE). The patches under `patches/apt/termux/` and
`patches/dpkg/termux/` are taken verbatim from
[`termux/termux-packages`](https://github.com/termux/termux-packages) and remain
under their original GPL-2.0-or-later terms; the apt and dpkg sources they apply
to are likewise GPL-2.0-or-later, which is compatible with GPL-3.0.
