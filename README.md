# sudo-less

How this box runs, builds and installs software **as an unprivileged user** —
no `sudo`, no root, nothing setuid beyond what the distro already ships.

Two personas share the machine:

| user | uid | role |
|---|---|---|
| `mobian` | 1000 | admin / root delegate — sole `sudo` member; installs packages, systemd units, udev rules, polkit rules, hardening |
| `master` | 1001 | unprivileged daily user — desktop session, all the no-root work in this repo |

`master` never escalates. Instead it uses polkit grants, groups, udev `uaccess`,
file capabilities, user namespaces, and userspace package extraction. The
root-side counterpart (run once by `mobian`) is `admin/admin-prep.sh`.

## Why: an experiment to make Mobian safer *but still usable*

The usual way to make a box "safer" is to take capabilities away — but then it
stops being usable: you can't install a tool, build something, or change a
setting without a password and a full root shell. This repo is the opposite
experiment: **remove standing root from the daily user, yet keep the machine
fully usable.**

The key insight is that **root inside a sandbox is not root on the host.**

- `master` has no `sudo` and no passwordless escalation, so there is nothing to
  phish, and a compromised session owns only its own files.
- When real privileges are needed, they are obtained *scoped and disposable*:
  - a **user namespace** (`unshare -Ur`) makes you uid 0 only inside a
    namespace mapped to your subuid;
  - a **rootfs** (mmdebstrap) or a **rootless container** (podman) is a full,
    normal Debian where you are root *inside it* — `apt-get install` build
    deps, autotools, maintainer scripts all just work — while the host's
    `/usr`, `/etc`, `/var` stay untouched;
  - a few narrowly-scoped **polkit** actions cover the genuinely privileged
    runtime needs (power, network, storage, a small service allowlist).
- The heavy lifting (like retargeting and building apt/dpkg, see
  `docs/apt-dpkg-port.md`) happens in that scoped root, and only the finished
  artifacts land in `~/.local`. The build environment is thrown away and
  rebuilt from scripts.

So the transformation is *easy* (you get a real root to work with) and the host
stays *safe* (that root never reaches it). That trade — scoped, ephemeral root
instead of standing root — is the whole idea.

## Contents

```
README.md                     this file
docs/
  methodology.md              the no-root toolbox: how to install/build without root
  porting.md                  reproduce on your own system (root vs no-root paths)
  apt-dpkg-port.md            the apt 2.8.1 + dpkg 1.22.6 userspace port (Termux patches)
  roles.md                    mobian vs master, and what master may do
  polkit.md                   polkit grants + doas default-deny note
  hardening.md                host hardening record
  waydroid.md, waydroid-mesa-debug.md
tools/
  deb2home.sh                 install Debian packages into $HOME without root
build/
  (see scripts/ + patches/ below)
scripts/
  common.sh                   shared vars (PREFIX=~/.local, versions, fetch helpers)
  build-deps.list             one package list, shared by all build paths
  fetch-sources.sh            download sources on the host (sandbox needs no curl)
  build-on-host.sh            root/sudo path: no sandbox, minimal deps
  install-build-deps.sh       install the toolchain (run inside build env)
  build-apt.sh                fetch/patch/configure/build/install apt
  build-dpkg.sh               fetch/patch/autogen/configure/build/install dpkg
  make-buildroot.sh           create a real rootfs with mmdebstrap (no root, no podman)
  build-in-rootfs.sh          build inside that rootfs via proot
  build-in-container.sh       same, but inside a rootless podman container
  install-config.sh           runtime config + dpkg status seeding
  install-shell-path.sh       add the prefix dirs to ~/.bashrc / ~/.profile
patches/
  apt/termux/, apt/local/     Termux's apt patches + our GCC-16 fixes
  dpkg/termux/                Termux's dpkg patches + configure.diff
admin/
  admin-prep.sh               root-side prep (run as mobian) that enables the no-sudo env
  verify-privs.sh             verify master's polkit/groups/userns/container setup
  smart-install.sh, unlock.sh, desktop-fix.sh, waydroid-install.sh
config/                       apt.conf.d/00local-prefix.in, sources.list
```

## The no-root toolbox (short version)

Full detail in `docs/methodology.md`. Four ways to get software without root,
roughly in order of weight:

1. **`deb2home`** — resolve deps with `apt-cache`, `apt-get download`, `dpkg -x`
   into `~/.local/opt/<pkg>`, link binaries. Fast, no maintainer scripts.
2. **user namespace** — `unshare -Ur` gives you root *inside a namespace*;
   enough to `chown`/`mknod`/`chroot` for a rootfs, nothing on the host.
3. **mmdebstrap + proot** — build a real Debian rootfs unprivileged, then run
   inside it with `proot` (ptrace, no privileges). This is how we build apt/dpkg
   with the full toolchain. No podman required.
4. **rootless podman / distrobox** — a container when you want a persistent
   environment; same user-namespace machinery, more moving parts.

## Build & use the userspace apt/dpkg

```sh
# have root/sudo on Debian? lightest path — no sandbox at all
./scripts/build-on-host.sh

# no root: real rootfs via mmdebstrap, entered with bwrap
./scripts/make-buildroot.sh
./scripts/build-in-rootfs.sh

# no root: rootless podman container as the build rootfs
./scripts/build-in-container.sh

export PATH="$HOME/.local/sbin:$HOME/.local/bin:$HOME/.local/usr/bin:$PATH"
apt-get update
apt-get install -y <package>
```

Porting to another machine (dependencies, prerequisites, overrides):
`docs/porting.md`.

## Scope & status

A **personal experiment** recorded as a reusable toolkit. The user names
`mobian` (admin) and `master` (unprivileged) are **example personas** for a
two-user split; substitute your own. Host-specific details (network ranges, SSH
key names, absolute home paths) are genericised, and the prefix config is
generated from `$PREFIX` rather than hardcoded.

Nothing here is guaranteed; it targets Debian-family systems and is meant to be
read alongside `docs/methodology.md`. Contributions/issues welcome.

## License

GPL-2.0-or-later (see `LICENSE`). The patches under `patches/apt/termux/` and
`patches/dpkg/termux/` are taken verbatim from
[`termux/termux-packages`](https://github.com/termux/termux-packages) and remain
under their original GPL-2.0 terms; the apt and dpkg sources they apply to are
GPL-2.0 as well.

See `docs/apt-dpkg-port.md` for how the Termux patches are retargeted and the
caveats (seeded db, root-only maintainer scripts, PATH shadowing).
