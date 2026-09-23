# Prior art: Termux and proot-distro

Two projects solve the same problem as sudo-less, a full userland with no
root, from the other end. Both were studied live on 2026-09-23 on a phone
(Android 16 / SDK 36, kernel 5.10, aarch64, Termux 0.119.0-beta.3 F-Droid
build, proot-distro 5.9.0). This page records what they do and what
sudo-less took from them. sudo-less's apt/dpkg port uses Termux's own patches
(`patches/*/termux/`, `docs/apt-dpkg-port.md`).

For every resource, the question is the one sudo-less asks of every package:

| bucket | meaning | in sudo-less |
|---|---|---|
| **U**: unprivileged | the kernel already grants it to any user | nothing to do |
| **F**: fakeable | userspace can provide a stand-in (namespace, shim, relocation) | `tools/`, `ecosystems/`, mechanisms in `docs/mechanisms.md` |
| **A**: admin, once | needs root to *enable*, never to *run* | `admin/` |
| **N**: not possible | no stand-in and no one-time enablement fits the rules | tier `never` |

## Termux: no root, no namespaces, no FHS

### What the sandbox gives (and does not)

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
5. **Root is only ever faked**, by proot ([below](#proot-distro-measured-live)).

### Termux in buckets

| need | Termux answer | bucket |
|---|---|---|
| install packages | apt/dpkg relocated to the prefix | **F** (relocation) |
| FHS paths (`/usr`, `/bin/sh`) | rebuild + `termux-exec` exec shim | **F** |
| exec from writable dir | old target SDK (policy loophole) | **A** (granted by the platform, by app manifest) |
| root, hardlinks, `/proc` files | proot + proot-distro fake them ([proot-distro](#proot-distro-measured-live)) | **F** (ptrace) |
| chown, device nodes | reported as success, not performed ([proot-distro](#proot-distro-measured-live)) | **N** |
| background processes surviving | phantom-process killer disabled once through Android's `shell` uid | **A** |
| namespaces, FUSE, GPU nodes, low ports | none | **N** |

**Lesson for this repo.** Termux proves the "change the software, not the
system" end of the spectrum works at distribution scale, but it pays for it with
a whole rebuilt package archive. A Debian host gives us what Termux lacks: user
namespaces, an FHS `/usr` to fall back on, one glibc, FUSE and GPU nodes via
`uaccess`. So we relocate only where it is cheap (`--instdir` into `~/.local`)
and use a namespace (the overlay) where Termux would have to rebuild.
Termux's exec-only shim is a good model if we ever need one: intercept the
narrowest syscall that fixes the problem, nothing more.

## proot-distro, measured live

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

## proot-distro: methods we adopted

[termux/proot-distro](https://github.com/termux/proot-distro) (GPL-3.0) runs
full Linux userlands from OCI images without root, via `proot`. We don't adopt
it: this repo targets a host that already *is* a full Debian, so a second,
docker-like userland adds nothing, and `proot` needs ptrace, which
`kernel.yama.ptrace_scope=2` forbids. Its *methods* solve the same no-root
problems we have, so we learn from them:

| method (proot-distro source) | applied here |
|---|---|
| host-side vs guest environment kept apart; `isolated`/`minimal` env modes (`execenv.py`, `commands/login/env.py`) | the rootfs runners (since removed) built the environment from an allowlist instead of inheriting the host's — #28 |
| bind checklist for a guest `/`: `/dev`, `/proc`, `/sys`, `/dev/shm`, `/dev/fd`, `resolv.conf`, `hosts` (`commands/login/proot_cmd.py`) | the `rootfs-native` runner (since removed) — #28 |
| safe archive extraction: drop `..`, re-root every symlink hop inside the target, never write through a planted hardlink, skip device nodes (`helpers/tar_extract.py`) | audit of `deb2home` and the userspace dpkg unpack — #29 |
| atomic writes (temp file + `rename`) and a per-container lock (`atomic.py`, `locking.py`) | prefix state written by the setup scripts — #30 |

Not taken: OCI image pulls, container `ps`/`kill` bookkeeping (our runners
`exec` the command in place, so there is nothing to track), faked `/proc`
entries and `--link2symlink` (Android and proot specifics).
