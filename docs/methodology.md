# Building and installing without root

`master` has no `sudo` and no root. Everything below runs as `master` (uid
1001) and stays inside the home directory. The privileged pieces are done once
by `mobian`: `admin/native/enable-userspace.sh` (user namespaces, subuid/subgid,
`~/.local/bin` on PATH; base tools only) and `admin/third-party/install-tools.sh`
(setuid `uidmap` and `fuse3` only). Unprivileged tools such as bwrap and
mmdebstrap `master` installs with the userspace apt.

There are four levels of "no-root", from lightest to heaviest. Pick the
lightest that does the job.

---

## 1. `deb2home` — extract a `.deb` into `$HOME`

`tools/deb2home.sh` (installed as `~/.local/bin/deb2home`):

```sh
deb2home PKG [PKG...]        # -d DIR prefix, -b DIR bin dir, -n no-deps, -N dry-run
```

It resolves `Depends`/`PreDepends` with `apt-cache`, downloads with
`apt-get download`, extracts with `dpkg -x` into `~/.local/opt/<pkg>`, and links
each binary into `~/.local/bin` (a wrapper setting `LD_LIBRARY_PATH` /
`XDG_DATA_DIRS` when the package ships its own libs).

Use when: the package is mostly self-contained binaries/data.
Limits: **no** maintainer scripts, conffiles, alternatives, or dpkg database;
apps with hardcoded `/usr` paths may fail.

---

## 2. User namespaces — `unshare`

```sh
unshare -Ur id          # uid=0(root) inside, uid=1001 outside
```

`-U` creates a user namespace, `-r` maps your uid to root **inside it**. In
there you may `chown`, `mknod`, and `chroot` — but only for ids in your map,
and nothing changes on the host. Backing store: `/etc/subuid`,
`/etc/subgid` (`master:165536:65536`), used by `newuidmap`/`newgidmap`.

This is the primitive that every "rootless container" is built on.

---

## 3. A real rootfs — `mmdebstrap` + `bwrap`

A **rootfs** is just a directory tree shaped like `/` (`usr/`, `etc/`, `var/`,
device nodes, ownership). A kernel can make it the `/` for a process tree.
`mmdebstrap` builds one by fetching `.deb`s and installing them *into* that
directory; normally that needs root. Unprivileged strategies:

| mode | how it fakes root | notes |
|---|---|---|
| `--mode=unshare` | user namespace (`unshare -Ur`) | can chown/mknod/chroot; maps to **subuid**, not your uid |
| `--mode=fakechroot` | `LD_PRELOAD` path shim + fakeroot | runs as you; needs the `fakechroot` package |
| `--mode=chrootless` | `dpkg --root --force-script-chrootless` | runs as you; skips some maintainer-script work |

### The subuid gotcha (why we pipe a tar)

`--mode=unshare` maps `/etc/subuid`'s range (`165536`) to root inside the
namespace, **not** your real uid. So inside, files owned by `1001` (your whole
home, mode `0700`) are *unmapped* → `Permission denied` when mmdebstrap tries to
write the rootfs into `~`.

Workaround: have mmdebstrap stream a tarball to **stdout** instead — a file
descriptor we already opened, which bypasses path permissions. Extract it
ourselves:

```sh
export TMPDIR=/tmp          # the mapped root must be able to write its tempdir
mmdebstrap --mode=unshare --variant=apt --format=tar \
  --components=main --include="$(paste -sd, scripts/build-deps.list)" \
  sid - http://deb.debian.org/debian > ~/buildroot.tar

rm -rf ~/buildroot && mkdir -p ~/buildroot
tar -xf ~/buildroot.tar -C ~/buildroot --no-same-owner --exclude='./dev/*'
```

`./dev` is skipped: device nodes can't be created unprivileged, and we bind the
host's `/dev` when entering anyway.

### Entering the rootfs — `bwrap`

```sh
bwrap --bind ~/buildroot / \
  --dev-bind /dev /dev --proc /proc --ro-bind /sys /sys --bind /tmp /tmp \
  --bind "$HOME" "$HOME" --chdir "$HOME" --setenv HOME "$HOME" \
  /usr/bin/env PREFIX="$HOME/.local" bash ~/sudo-less/scripts/bootstrap/build-apt.sh
```

`bwrap` uses unprivileged user namespaces (`clone`/`unshare`) to present
`~/buildroot` as `/` and bind-mounts the host's `$HOME` back in, so the source
tree and `$PREFIX` stay on the host filesystem. This is what
`scripts/env/build-in-rootfs.sh` does.

`proot` is the older alternative: it uses `ptrace` (no privileges) instead of
user namespaces, with `-0` faking uid 0. But on hosts that restrict ptrace
(`kernel.yama.ptrace_scope=2`), `ptrace(PTRACE_TRACEME)` fails with `EPERM`, and
on recent kernels its seccomp accelerator needs `PROOT_NO_SECCOMP=1`. Prefer
`bwrap`.

`unshare -Ur -m chroot ~/buildroot` is another alternative (faster, no ptrace
overhead) but needs you to mount `/proc`, `/dev`, `/sys` yourself.

---

## 4. Rootless containers — podman / distrobox

Same user-namespace machinery, packaged:

```sh
podman run -d --name build -v "$HOME:$HOME:rw" debian:sid sleep infinity
podman exec -e DEBIAN_FRONTEND=noninteractive build apt-get update
podman exec build bash ~/sudo-less/scripts/bootstrap/install-build-deps.sh
podman exec build bash ~/sudo-less/scripts/bootstrap/build-apt.sh
```

Notes:
- `podman exec` gives real root **in the container**; writes to the bind-mounted
  `$HOME` land as `master` on the host. This is the easiest path.
- `distrobox enter` on this host is flaky: its first-enter integration installs
  "basic packages" and can wedge on the dpkg lock. Prefer plain `podman`, or
  `distrobox create` once and use `podman exec`.
- A stray `apt-get` holding `/var/lib/dpkg/lock-frontend` means an integration
  run is still going; find it via `/proc/<pid>/cmdline` (there is no `ps` in the
  minimal image) and kill it, then restart the container.

---

## Overlaying a fix into a read-only image (Waydroid)

When the thing that needs fixing lives *inside* an image you can't rebuild,
don't rebuild it — **build the replacement unprivileged, then drop it into an
overlay the image already reads.**

Waydroid merges `/var/lib/waydroid/overlay` over the Android image
(`lowerdir=/var/lib/waydroid/overlay:/var/lib/waydroid/rootfs`), so a file at
`overlay/system/framework/services.jar` shadows the image's own copy — the
image stays untouched and `rm` of that one file reverts it. Same idea as
`deb2home`/`bwrap` in spirit: work in a place you control, don't escalate to
change the original.

The catch here is that the file is **compiled** (dex inside a jar), so the
"build" is disassemble → patch → reassemble rather than a text edit. That is
pure Java and needs **no root** — on this box it ran on the phone
(`ssh fe2`, Termux + openjdk) with the standalone `baksmali`/`smali` fat jars.
Only the final `install` into the root-owned overlay needs the admin account,
and that is a single `cp`. Worked example (a one-line divide-by-zero guard in
`services.jar`): `docs/waydroid-mesa-debug.md` §15, with
`extras/waydroid/patch-services-jar.sh` (unprivileged build) and
`extras/device/waydroid-install-framework-overlay.sh` (the one root drop).

---

## Worked example: userspace apt + dpkg

Goal: run `apt-get install` as `master`, installing `.deb`s into `~/.local`.

1. Build env: `scripts/env/make-buildroot.sh` (or `scripts/env/build-in-container.sh`).
2. apt 2.8.1 + dpkg 1.22.6 built with Termux's patches → `~/.local`.
   Details and the exact retargeting in `docs/apt-dpkg-port.md`.
3. Runtime config: `scripts/setup/install-config.sh` (sources.list, `apt.conf.d`,
   seeded dpkg status, PATH).

---

## Runtime privileges without root

For actions that genuinely need a privileged daemon (power, network, storage,
a few services), `master` is granted narrowly-scoped **polkit** actions instead
of sudo, and some devices via udev `uaccess` + file capabilities (e.g. SMART).
See `docs/polkit.md` and `docs/roles.md`. Verify the whole setup with
`admin/verify-privs.sh`.

---

## Pitfalls collected

- Home is `0700`: userns root (mapped to subuid) cannot read it → pipe tarballs,
  or use fakechroot/podman.
- `PROOT_NO_SECCOMP=1` on recent kernels.
- Minimal container images have no `ps`; use `/proc/*/cmdline`.
- `distrobox enter` integration vs. the dpkg lock (see above).
- Explicit `apt-get install` lists beat `build-dep` when the suite's package
  version differs from the one you are building.

---

## Prior art: proot-distro

[termux/proot-distro](https://github.com/termux/proot-distro) (GPL-3.0) runs
full Linux userlands from OCI images without root, via `proot`. We don't adopt
it: this repo targets a host that already *is* a full Debian, so a second,
docker-like userland adds nothing, and `proot` needs ptrace, which
`kernel.yama.ptrace_scope=2` forbids. Its *methods* solve the same no-root
problems we have, so we learn from them:

| method (proot-distro source) | applied here |
|---|---|
| host-side vs guest environment kept apart; `isolated`/`minimal` env modes (`execenv.py`, `commands/login/env.py`) | rootfs runners build the environment from an allowlist instead of inheriting the host's (a leaked host `PATH` made `dpkg` inside the rootfs resolve to the userspace one) — #28 |
| bind checklist for a guest `/`: `/dev`, `/proc`, `/sys`, `/dev/shm`, `/dev/fd`, `resolv.conf`, `hosts` (`commands/login/proot_cmd.py`) | `tools/prefix-run.sh --mode rootfs-native` — #28 |
| safe archive extraction: drop `..`, re-root every symlink hop inside the target, never write through a planted hardlink, skip device nodes (`helpers/tar_extract.py`) | audit of `deb2home` and the userspace dpkg unpack — #29 |
| atomic writes (temp file + `rename`) and a per-container lock (`atomic.py`, `locking.py`) | prefix state written by the setup scripts — #30 |

Not taken: OCI image pulls, container `ps`/`kill` bookkeeping (our runners
`exec` the command in place, so there is nothing to track), faked `/proc`
entries and `--link2symlink` (Android and proot specifics).
