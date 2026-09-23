# Building and installing without root

`master` has no `sudo` and no root. Everything below runs as `master` (uid
1001) and stays inside the home directory. The privileged pieces are done once
by `mobian`: `admin/enable-userspace.sh` (user namespaces, subuid/subgid,
`~/.local/bin` on PATH; base tools only) and `third-party/install-tools.sh`
(setuid `uidmap` and `fuse3` only). Unprivileged tools such as bwrap
`master` installs with the userspace apt.

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

## 3. A real rootfs

A directory shaped like `/`, built unprivileged with `mmdebstrap
--mode=unshare` and entered with `bwrap` or `unshare` + `chroot`, is one more
way to get a build environment without root. The repo does not script or
use it; `docs/porting.md` sketches it.

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

## Worked example: userspace apt + dpkg

Goal: run `apt-get install` as `master`, installing `.deb`s into `~/.local`.

1. Build env: `scripts/env/build-on-host.sh` (with root) or `scripts/env/build-in-container.sh`.
2. apt 2.8.1 + dpkg 1.22.6 built with Termux's patches → `~/.local`.
   Details and the exact retargeting in `docs/apt-dpkg-port.md`.
3. Runtime config: `scripts/setup/install-config.sh` (sources.list, `apt.conf.d`,
   seeded dpkg status, PATH).

---

## Runtime privileges without root

sudo-less installs software; it does not grant privileges. What a package
needs beyond an unprivileged user at *run* time (a device group, a
capability such as `CAP_NET_RAW`, a port below 1024) is the admin's call,
made once: polkit or udev `uaccess` for the desktop session, or a bounded
identity through [dsb](https://github.com/jronminh/dsb) (see `dev/dsb/` for
the policy used to develop sudo-less).

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

## Prior art

Termux and proot-distro solve the same no-root problem from the other end;
what they do and what this repo took from them: `docs/prior-art.md`.
