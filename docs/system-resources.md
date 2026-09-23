# What userspace runtimes ask of the system

A field study of two runtimes that live next to this repo's goal, run live on
2026-09-23:

- **Termux** — a Linux userland inside an Android app, with no root at all
  (phone `fe2`: Android 16 / SDK 36, kernel 5.10, aarch64, Termux 0.119.0-beta.3
  F-Droid build).
- **Waydroid** — Android in an LXC container on this Debian host (read-only
  inspection through the admin account; the container was running).

For every system resource each one needs, the question is the same one this repo
asks of every package: **is it already unprivileged, can userspace fake it, or
does the admin have to prepare it once?** The answers are sorted into four
buckets:

| bucket | meaning | where it lives in this repo |
|---|---|---|
| **U** — unprivileged | the kernel already grants it to any user | nothing to do |
| **F** — fakeable | userspace can provide a stand-in (namespace, shim, relocation) | `tools/`, `scripts/`, tiers in `docs/paths.md` |
| **A** — admin, once | needs root to *enable*, never to *run* | `admin/native/`, `admin/third-party/` |
| **N** — not possible | no stand-in and no one-time enablement fits the rules | tier `never` |

---

## 1. Termux: no root, no namespaces, no FHS

### What the sandbox gives (and does not)

| resource | observed on `fe2` |
|---|---|
| identity | one app uid (`u0_a663` = 10663), no capabilities (`CapEff`/`CapBnd` = 0) |
| SELinux | domain `untrusted_app_27`, because the app targets SDK **28** (`TERMUX_APP__TARGET_SDK=28`) |
| seccomp | filter mode (`Seccomp: 2`), set by Android's zygote |
| user namespaces | none: `unshare -Ur` → `Invalid argument` |
| ptrace | no Yama file; ptrace between one's own processes works (proot's basis) |
| filesystem root | `/` unreadable; no `/usr`; `/bin` → `/system/bin`, `/etc` → `/system/etc` |
| hardlinks | `ln a b` → `Permission denied` (SELinux on `app_data_file`) |
| `/proc` | own processes only; `/proc/stat`, `/proc/version`, `/proc/net/tcp` denied |
| devices | `/dev/fuse`, `/dev/dri/*` denied; `/dev/kvm` absent; `/dev/ashmem`, binder reachable |
| network | ports < 1024 denied (`sshd` listens on 8022); outbound fine |
| setuid | none in the prefix; there is no second uid to switch to |

### How Termux lives with that

Termux changes **the software**, not the system:

1. **Relocation at build time.** Everything is compiled for
   `PREFIX=/data/data/com.termux/files/usr` with the NDK. Binaries use Android's
   `/system/bin/linker64` and carry `RUNPATH=$PREFIX/lib`; shebangs are
   rewritten to `$PREFIX/bin/...` (`pkg` starts with
   `#!/data/data/com.termux/files/usr/bin/bash`). `PATH` is `$PREFIX/bin` only.
2. **One runtime shim, on `exec` only.** `termux-exec` (2.3.0) is
   `LD_PRELOAD`ed and intercepts `execve`/`fexecve`: it maps `/bin/sh` and
   `/usr/bin/env` shebangs into the prefix, and for apps targeting SDK ≥ 29
   (W^X: no exec from app data) it can run binaries through the system linker
   (`TERMUX_EXEC__SYSTEM_LINKER_EXEC__MODE`). Nothing else is intercepted.
3. **apt/dpkg are the Debian ones plus patches.** apt's `Dir "/"` with
   `Dir::State`, `Dir::Etc` and `Dir::Cache` under the prefix; dpkg's admin dir is
   `$PREFIX/var/lib/dpkg` (252 packages here). Maintainer scripts are rewritten
   to prefix paths. dpkg is built with `__ANDROID__`, which skips the superuser
   check and `chown`, the same switch our port uses (`docs/apt-dpkg-port.md`).
4. **A second libc in the same prefix.** The `termux-glibc` repo installs a glibc
   world under `$PREFIX/glibc` (its own `ld-linux-aarch64.so.1`) next to the
   bionic one. Two ABIs coexist because each carries its own interpreter
   path.
5. **Root is only ever faked** (`proot -0`, via proot-distro; not installed
   on this phone). proot's `--link2symlink` and its fake `/proc/stat`,
   `/proc/version` entries exist *because* of the hardlink and `/proc`
   restrictions above (see "Prior art: proot-distro" in `docs/methodology.md`).

### Termux in buckets

| need | Termux answer | bucket |
|---|---|---|
| install packages | apt/dpkg relocated to the prefix | **F** (relocation) |
| FHS paths (`/usr`, `/bin/sh`) | rebuild + `termux-exec` exec shim | **F** |
| exec from writable dir | old target SDK (policy loophole) | **A** (granted by the platform, by app manifest) |
| root, chown, device nodes | proot fakes them, slowly | **F** (ptrace) |
| namespaces, FUSE, GPU nodes, low ports | none | **N** |

**Lesson for this repo.** Termux proves the "change the software, not the
system" end of the spectrum works at distribution scale, but it pays for it with
a whole rebuilt package archive. A Debian host gives us what Termux lacks: user
namespaces, an FHS `/usr` to fall back on, one glibc, FUSE and GPU nodes via
`uaccess`. So we relocate only where it is cheap (`--instdir` into `~/.local`)
and use namespaces (overlay/rootfs tiers) where Termux would have to rebuild.
Termux's exec-only shim is a good model if we ever need one: intercept the
narrowest syscall that fixes the problem, nothing more.

---

## 2. Waydroid: a privileged container behind a user session

### How it is split today

| side | runs as | does |
|---|---|---|
| `waydroid container start` (systemd `waydroid-container.service`) | **root** | `lxc-start` of a **privileged** container (no `lxc.idmap`), `waydroid-sensord`, dnsmasq (as `dnsmasq`) |
| `waydroid session start` | **master** | asks the container service over the system D-Bus (`id.waydro.Container`); binds the user's sockets and data dir in |
| `waydroid init` | admin | polkit `id.waydro.Initializer.Init` = `auth_admin` |

### What the container needs, and whether master could provide it

Tested as `master` (uid 1001, no root) unless stated.

| resource | how it is provided now | can master do it? | bucket |
|---|---|---|---|
| binder IPC | `binder_linux` loaded with `devices=anbox-binder,anbox-vndbinder,anbox-hwbinder`; misc nodes mode `0666` | opening the nodes: **yes**. Private binderfs: **no**, kernel has no `CONFIG_ANDROID_BINDERFS` (`mount -t binder` → unknown fs) | **A** (module load at boot) |
| system/vendor images | ext4 `system.img`/`vendor.img` loop-mounted ro by root | loop-mount in a userns: **no** (`Permission denied`; ext4 is not userns-mountable). Images are `0644`, so extracting them unprivileged is possible (not tried) | **A** today, **F** candidate |
| overlay on the images | overlayfs, `lowerdir=overlay:rootfs`, upper `overlay_rw` | **yes**, unprivileged overlayfs in a userns (#26) | **F** |
| uid space | none mapped (privileged): Android uids are host uids | Android uses 0 … 99999 (apps 10000+, isolated 99000+); master's subuid range is **65536**, too small | **A** (larger subuid range) |
| capabilities | `lxc.cap.keep` incl. `sys_admin`, `net_admin`, `mknod`, `sys_ptrace` | inside its own userns: **yes**, scoped to that namespace | **F** |
| AppArmor, seccomp | `lxc-waydroid` profile, `waydroid.seccomp`, `no_new_privs` | LXC applies these to unprivileged containers too; the AppArmor profile must be loaded by root | **A** (profile load) |
| cgroups | `cgroup:rw`, `suspend_action = freeze` | `user@1001.service` delegates `cpu memory pids`; `cgroup.freeze` is core in cgroup2 | **U** |
| network | bridge `waydroid0` 192.168.240.1/24, veth, dnsmasq, nft masquerade | veth in its own netns: **yes** (`ip link add dev a type veth …`); host bridge: no (`lxc-usernet` absent); `pasta`/`slirp4netns` present as a stand-in | **F** (pasta) |
| `/dev/dri/renderD128` | bind | **yes** (`uaccess` ACL) | **U** |
| `/dev/fuse`, `/dev/net/tun`, `/dev/dma_heap/system` | bind | **yes** (`0666`/`0777`) | **U** |
| `/dev/uhid` | bind | **no** (`0600 root`) | **A** (udev rule) or drop |
| `/dev/video*`, `/dev/fb0` | bind | via `video` group / `uaccess` if granted | **A** (group) or drop |
| `/sys/kernel/debug` | rbind | **no**, root only | drop |
| Wayland, PulseAudio | binds `/run/user/1001/wayland-0`, `pulse/native` | **yes**, they are master's own sockets | **U** |
| `/data` | binds `~/.local/share/waydroid/data` | directory is master's; contents are not (next point) | see below |

### Finding: identity overlap with the admin account

Because the container is privileged, Android's `AID_SYSTEM` (uid 1000) *is*
host uid 1000, which is `mobian`, the admin account. On the host:

- `~/.local/share/waydroid/data` is owned by `mobian:mobian`, inside
  `master`'s home;
- Android services (`vendor.waydroid.task@1.0-service`, `waydroid-sensord`)
  show up in `ps` as `mobian`;
- Android app uids (10000+) are live, unmapped host uids.

That breaks the `docs/roles.md` split: files and processes of an app sandbox
carry the admin's identity. An `lxc.idmap` that maps Android's uids into
master's subuid range would fix it and is the same prerequisite an
unprivileged container needs.

### Waydroid in buckets

The only things that need root *to run* today are the loop mounts, the
privileged `lxc-start` and the bridge. Everything else is either already
unprivileged or needs root only to be enabled once:

- **once, admin:** load `binder_linux` at boot; a subuid/subgid range of at least
  100000 for `master`; load the `lxc-waydroid` AppArmor profile; optional udev
  rules for `uhid`/video;
- **per run, userspace:** userns with that idmap, extracted (or FUSE-mounted)
  images, overlayfs, own netns with `pasta`, cgroup2 freeze under
  `user@1001.service`.

Whether Android actually boots that way is **untested**: that is the spike
proposed below.

---

## 3. What this means for the repo

1. **The four buckets are the repo's vocabulary.** A recipe or tier should say
   which resources it needs and which bucket each falls in. `docs/paths.md`
   tiers already encode F (overlay/rootfs) and N (`never`); A items should
   point at the admin script that enables them.
2. **Admin scripts stay "enable once".** Everything classed A above is a
   boot-time or config change (module, subuid size, AppArmor profile, udev),
   the same shape as `admin/native/enable-userspace.sh`. None of it runs
   master's software.
3. **Proposed work** (to become issues):
   - *Spike: unprivileged Waydroid.* Userns with an idmap into a ≥ 100000 subuid
     range, images extracted to a dir, overlay native, `pasta` networking, binder
     via the existing `0666` nodes. Outcome either moves Waydroid from `extras/`
     toward a supported tier or documents precisely which item is N.
   - *Hardening: Waydroid uid 1000 = admin.* Until the spike lands, note it in
     `docs/hardening.md`; consider a dedicated system uid gap so Android's
     `AID_SYSTEM` does not collide with the admin account.
   - *Resource manifest for recipes.* A `needs:` line per recipe
     (`userns`, `overlay`, `fuse`, `gpu`, `binder`, …) checked by
     `recipes.sh`, so `tier_ok` fails with the missing bucket-A item named.
   - *Termux as a porting reference.* Where a package breaks under
     `--instdir` relocation, check `termux-packages` first: its patch for the
     same hard-coded path usually exists.
