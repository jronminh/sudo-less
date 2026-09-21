# Building and installing without root

`master` has no `sudo` and no root. Everything below runs as `master` (uid
1001) and stays inside the home directory. The privileged pieces are done once
by `mobian` via `admin/admin-prep.sh` (subuid/subgid, user namespaces, uidmap,
fuse-overlayfs, `~/.local/bin` on PATH).

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

## 3. A real rootfs — `mmdebstrap` + `proot`

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

Workaround: have mmdebstrap stream a tarball to **stdout** — a file descriptor
we already opened, which bypasses path permissions — and extract it ourselves:

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

### Entering the rootfs — `proot`

```sh
proot -0 -r ~/buildroot \
  -b /proc -b /dev -b /sys -b /tmp \
  -b "$HOME:$HOME" -w "$HOME" \
  /usr/bin/env HOME="$HOME" bash ~/sudo-less/scripts/build-apt.sh
```

`proot` uses `ptrace` (no privileges) to present `~/buildroot` as `/`, `-0`
fakes uid 0, and `-b` bind-mounts the host's `$HOME` back in so the source tree
and `$PREFIX` stay on the host filesystem.

On recent kernels proot's seccomp accelerator fails with
`can't chmod '/tmp/proot-*'`; disable it:

```sh
export PROOT_NO_SECCOMP=1
```

`unshare -Ur -m chroot ~/buildroot` is the alternative (faster, no ptrace
overhead) but needs you to mount `/proc`, `/dev`, `/sys` yourself.

---

## 4. Rootless containers — podman / distrobox

Same user-namespace machinery, packaged:

```sh
podman run -d --name build -v "$HOME:$HOME:rw" debian:sid sleep infinity
podman exec -e DEBIAN_FRONTEND=noninteractive build apt-get update
podman exec build bash ~/sudo-less/scripts/install-build-deps.sh
podman exec build bash ~/sudo-less/scripts/build-apt.sh
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

## Worked example: userspace apt + dpkg

Goal: run `apt-get install` as `master`, installing `.deb`s into `~/.local`.

1. Build env: `scripts/make-buildroot.sh` (or `build-in-container.sh`).
2. apt 2.8.1 + dpkg 1.22.6 built with Termux's patches → `~/.local`.
   Details and the exact retargeting in `docs/apt-dpkg-port.md`.
3. Runtime config: `scripts/install-config.sh` (sources.list, `apt.conf.d`,
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
