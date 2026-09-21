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

## Contents

```
README.md                     this file
docs/
  methodology.md              the no-root toolbox: how to install/build without root
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
  build-deps.list             one package list, shared by container + rootfs builds
  install-build-deps.sh       install the toolchain (run inside build env)
  build-apt.sh                fetch/patch/configure/build/install apt
  build-dpkg.sh               fetch/patch/autogen/configure/build/install dpkg
  make-buildroot.sh           create a real rootfs with mmdebstrap (no root, no podman)
  build-in-rootfs.sh          build inside that rootfs via proot
  build-in-container.sh       same, but inside a rootless podman container
  install-config.sh           runtime config + dpkg status seeding
patches/
  apt/termux/, apt/local/     Termux's apt patches + our GCC-16 fixes
  dpkg/termux/                Termux's dpkg patches + configure.diff
admin/
  admin-prep.sh               root-side prep (run as mobian) that enables the no-sudo env
  verify-privs.sh             verify master's polkit/groups/userns/container setup
  smart-install.sh, unlock.sh, desktop-fix.sh, waydroid-install.sh
config/                       apt.conf.d/00local-prefix, sources.list
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
# podman route (uses a rootless container as the build rootfs)
./scripts/build-in-container.sh

# podman-free route (real rootfs via mmdebstrap, entered with proot)
./scripts/make-buildroot.sh
./scripts/build-in-rootfs.sh

export PATH="$HOME/.local/sbin:$HOME/.local/bin:$HOME/.local/usr/bin:$PATH"
apt-get update
apt-get install -y <package>
```

See `docs/apt-dpkg-port.md` for how the Termux patches are retargeted and the
caveats (seeded db, root-only maintainer scripts, PATH shadowing).
