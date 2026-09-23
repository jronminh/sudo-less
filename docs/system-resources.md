# What userspace runtimes ask of the system

A field study of two runtimes that live next to this repo's goal, run live on
2026-09-23:

- **Termux** — a Linux userland inside an Android app, with no root at all
  (phone `fe2`: Android 16 / SDK 36, kernel 5.10, aarch64, Termux 0.119.0-beta.3
  F-Droid build), plus Android's `shell` uid through `dsh` (a wireless-ADB
  bridge, [termux-adb-bridge](https://github.com/jronminh/termux-adb-bridge))
  and a live proot-distro 5.9.0 install.
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

### 1.1 What the sandbox gives (and does not)

| resource | observed on `fe2` |
|---|---|
| identity | one app uid (`u0_a663` = 10663), no capabilities (`CapEff`/`CapBnd` = 0) |
| SELinux | domain `untrusted_app_27`, because the app targets SDK **28** (`TERMUX_APP__TARGET_SDK=28`) |
| seccomp | filter mode (`Seccomp: 2`), set by Android's zygote |
| user namespaces | none: `unshare -Ur` → `Invalid argument`; the kernel is built without `CONFIG_USER_NS` (`/proc/config.gz`, read at shell uid) |
| ptrace | no Yama file; ptrace between one's own processes works (proot's basis) |
| filesystem root | `/` unreadable; no `/usr`; `/bin` → `/system/bin`, `/etc` → `/system/etc` |
| hardlinks | `ln a b` → `Permission denied` (SELinux on `app_data_file`) |
| `/proc` | mounted `hidepid=invisible,gid=3009` (`readproc`): own processes only (13 vs 910 at shell uid); `/proc/stat`, `/proc/version`, `/proc/net/tcp` denied by SELinux, not by mode bits |
| devices | `/dev/fuse`, `/dev/dri/*` denied; `/dev/kvm` absent; `/dev/ashmem`, binder reachable |
| network | ports < 1024 denied (`sshd` listens on 8022); outbound fine |
| setuid | none in the prefix; there is no second uid to switch to |

### 1.2 How Termux lives with that

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
5. **Root is only ever faked**, by proot (§1.3).

### 1.3 proot-distro, live

proot-distro 5.9.0 with proot 5.1.107.94, Alpine 3.24.2 minirootfs installed from
a local tarball (`proot-distro install --name alpine FILE`, 2 s). Layout:
`$PREFIX/var/lib/proot-distro/containers/alpine/{rootfs,shm,sysdata}`.

The `proot` command line it builds (read from `/proc/<pid>/cmdline`, `$T` =
`/data/data/com.termux/files`):

```
proot --kill-on-exit --link2symlink --sysvipc -L --change-id=0:0
      --kernel-release=...6.17.0-PRoot-Distro...  --rootfs=.  --cwd=/root
      --bind=/dev --bind=/proc --bind=/sys --bind=/dev/urandom:/dev/random
      --bind=<c>/sysdata/sys_empty:/sys/fs/selinux
      --bind=<c>/sysdata/{loadavg,stat,uptime,version,vmstat}:/proc/...
      --bind=<c>/sysdata/sysctl_*:/proc/sys/{kernel/cap_last_cap,fs/inotify/max_user_watches,kernel/overflow[ug]id}
      --bind=<c>/shm:/dev/shm
      --bind=/data/app --bind=/data/dalvik-cache --bind=/storage/self/primary:/sdcard ...
      --bind=$T/home --bind=/apex --bind=/system --bind=/vendor ... --bind=$T/usr
```

`--rootfs=.` is deliberate: proot-distro `chdir`s into the rootfs through a
directory descriptor it has already checked, so a symlink swapped in later
cannot redirect it.

What the guest sees:

| probe | result | how |
|---|---|---|
| `id` | `uid=0(root)`, but `/proc/self/status` `Uid: 10663`, `CapEff: 0`, `TracerPid` = proot | `--change-id=0:0`, all in the tracer |
| `uname -r`, `/proc/version` | `6.17.0-PRoot-Distro` | `--kernel-release` + a bound file |
| `/proc/stat`, `/proc/loadavg`, `/proc/uptime` | plausible static values | files under `sysdata/` bound over the denied host ones |
| `/proc/mounts` | the **host's** (Android `erofs` `/`) | not faked |
| other `/proc` entries (`cmdline`, `modules`, …) | `Permission denied` | not faked |
| `ln a b` | works, link count 2, same inode shown | `--link2symlink`: backing file under `/.l2s`, both names become symlinks |
| `chown 123:456 f` | exit 0, owner stays `0:0` | faked success, nothing stored |
| `mknod n c 1 3` | exit 0, no node created | faked success |
| `/dev/shm` | writable, private per container | `<c>/shm` bind (Android has no shm) |

Cost (same phone, wall clock): `login -- true` ≈ 0.85 s startup; 300
`exec`s ≈ 6.1 s inside vs ≈ 6.9 s for bionic `true` outside (exec is slow on
this phone either way); `find -ls` over the rootfs ×5 ≈ 0.16 s inside after
startup vs 0.20 s outside. The ptrace tax shows up per syscall-heavy process
start, not in steady I/O.

Two lessons carry over to the Debian host even though proot itself does not
run there (`ptrace_scope=2`):

- the **fake `/proc` file list** is the list of things software actually reads
  and a sandbox tends to deny. Our namespaced runners bind the real `/proc`,
  so none of it is needed today, but it is the checklist if a tier ever
  hides `/proc`;
- **"success without effect"** (`chown`, `mknod`) is how proot keeps dpkg
  happy. Our userspace dpkg gets the same result by skipping `chown` at
  build time (`__ANDROID__`, `docs/apt-dpkg-port.md`); inside a user
  namespace `chown` is real but limited to mapped ids.

### 1.4 Android's middle tier: the `shell` uid (`dsh`)

Between the app sandbox and root, Android has `shell` (uid 2000, what `adb
shell` gets). On `fe2` it is reachable from Termux via `dsh`, which runs a
command through a wireless-ADB bridge. Compared with the app:

| | Termux app (10663) | `shell` (2000) |
|---|---|---|
| SELinux domain | `untrusted_app_27` | `shell` |
| seccomp | filter | none |
| capabilities | none | none effective (bounding: `setuid`, `setgid`, `sys_nice`) |
| user namespaces | no | no (kernel) |
| `/proc` | own processes, `stat`/`version` denied | all processes (`readproc`), `stat`/`version`/`config.gz` readable |
| groups | app, storage, `inet` | + `log`, `adb`, `uhid`, `readproc`, `net_bw_stats`, … |
| system settings | read-only, few | `settings`, `device_config`, `dumpsys`, `pm`, `am` |

It is used as a one-time enabler, exactly our `admin/` shape: here
`settings_enable_monitor_phantom_procs` is `false` (the Android 12+ phantom
process killer is off, so Termux's background daemons such as `sshd` survive).
Termux never runs its software as `shell`; it asks `shell` to change a
setting once and then runs as the app. It is not root either: no
namespaces, no mounts, no module loading.

(Aside, from the same session: DNS failed on the phone for every uid, `shell`
included, while IP traffic worked; the network had Private DNS `hostname`
plus the Tailscale VPN active. The packages and rootfs above were fetched on
the Debian host and copied over. That is a network fault, not a sandbox
limit.)

### Termux in buckets

| need | Termux answer | bucket |
|---|---|---|
| install packages | apt/dpkg relocated to the prefix | **F** (relocation) |
| FHS paths (`/usr`, `/bin/sh`) | rebuild + `termux-exec` exec shim | **F** |
| exec from writable dir | old target SDK (policy loophole) | **A** (granted by the platform, by app manifest) |
| root, hardlinks, `/proc` files | proot + proot-distro fake them (§1.3) | **F** (ptrace) |
| chown, device nodes | reported as success, not performed (§1.3) | **N** |
| background processes surviving | phantom-process killer disabled once at shell uid (§1.4) | **A** |
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
   Android has the same three layers (app → `shell` → root, §1.4) and uses the
   middle one the same way: change a setting once, run as the app afterwards.
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
