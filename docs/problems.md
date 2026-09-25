# The problem map

Everything that stands between a `.deb` and a user without root, sorted on
three axes:

- **when** it bites: while **installing** the package (apt and dpkg,
  maintainer scripts), or while **running** its programs and services;
- **what** it needs: **files** (paths the package expects), an **identity**
  (a user, a group, file ownership), a **service** (something started and
  kept running), the **network**, a **device**, a **privilege** (setuid, a
  capability), or the **kernel** itself;
- **who** can fix it:
  - **non-root, done:** sudo-less does it by itself, for every package, with
    no root at any point;
  - **non-root, partly:** it could be done without root but sudo-less has
    not done it yet, or it runs with less than on Debian (another port, a
    userspace mode, no sandbox);
  - **root, once:** the admin does one step, once for every user and every
    package (enable user namespaces, a sysctl, linger); after that it is
    non-root. The steps are planned in
    [`admin-features.md`](admin-features.md);
  - **never:** the package needs root each time it installs or runs,
    because it changes the system itself (a system user, a kernel module, a
    setuid program). It never runs from the prefix: the admin installs it
    system-wide instead.

Each package's verdict is the worst cell it falls in, in the order above.
The user sees only that verdict ([`standard.md`](standard.md)); this page
is the inside view, for people working on sudo-less. The numbers are from
[`survey.md`](survey.md) and [`services.md`](services.md#how-many-packages-this-reaches).

## The grid

| when | what | non-root, done | non-root, partly | root, once | never |
|---|---|---|---|---|---|
| install | files | dpkg and its database in the prefix; the host's packages counted as installed; maintainer scripts in the install view; refusing what cannot work before dpkg runs | a postinst calling `ucf` | version skew (upgrade the host) | |
| install | identity | | | `chown` to a system group (subid) | a system user or group |
| install | kernel | | | unprivileged user namespaces and overlayfs | kernel modules, `/boot` |
| run | files | `PATH`; the run view for programs that look for their files at `/usr`, `/etc`, `/opt`; host mounts in the view; desktop launchers | | | a path in `/run` owned by root |
| run | identity | | | | a system group |
| run | service | a unit translated into a user unit, started, restarted and removed with its package | its sandbox dropped; drop-ins not read; a failed unit not restarted on upgrade | running without a login (linger) | a service run as a system user, or from an init script alone |
| run | network | ports from 1024; sockets in `$XDG_RUNTIME_DIR` | a userspace mode instead of a TUN device (tailscale); the kernel's default socket buffers | ports below 1024; larger socket buffers | a TUN device, firewall rules, raw sockets |
| run | device | | | a device group (`dialout`, `kvm`) | |
| run | privilege | | | | setuid and setgid programs, file capabilities |
| run | kernel | | | unprivileged user namespaces (the same step as for installing) | |

An empty cell means nothing has been found there yet.

## Install

### Files

| problem | cell | what solves it | where |
|---|---|---|---|
| dpkg writes to `/var/lib/dpkg` and `/`, which need root | done | dpkg and its database live in the prefix; dpkg runs in the install view, where the prefix is `/usr`, `/etc`, `/var`, `/opt` | [`apt-dpkg-port.md`](apt-dpkg-port.md), [`view.md`](view.md) |
| apt would install again everything the host already has | done | the prefix's database is seeded with the host's packages, held | `apt-dpkg/lock-seeded.sh` |
| maintainer scripts write `/etc` and `/var`, run `update-alternatives`, `py3compile`, `ldconfig`, triggers, the package's own programs | done | the install view: the script sees a normal system and every write lands in the prefix | [`view.md`](view.md#how-dpkg-gets-there) |
| maintainer scripts call the host's services (`systemctl daemon-reload`, `deb-systemd-invoke`, `pkexec`), which asks polkit, and the admin's password dialog pops up on the desktop | done | the install view has an empty `/run`: no system bus, no systemd; debhelper's guards skip the service steps | [`view.md`](view.md#how-dpkg-gets-there) |
| dpkg reopens each unpacked file to `fsync` it, which fails for a read-only one (tailscale's 0444 `/etc/default/tailscaled`) | done | `force-unsafe-io` in the prefix's `dpkg.cfg` | `apt-dpkg/config/dpkg/dpkg.cfg.in` |
| a package that cannot install fails half way and leaves the prefix wedged: every later apt run tries to configure it again | done | `prefix-check` reads each `.deb` before dpkg runs and refuses the run, naming the package and the reason, if one falls in a **never** cell | `tools/prefix-check.sh`, `apt-dpkg/config/apt.conf.d/03check.in` |
| a postinst calls `ucf`, which refuses a non-root user ("Need to be run as root"; webfs) | partly | not yet: `ucf` checks only the uid, so the install view could satisfy it as it does `update-alternatives` | |
| **version skew:** on a rolling host a newer package needs a newer system library than the host has, and the host's copy is held | root, once | upgrade the host (`apt upgrade`); the prefix follows at its next reseed | |

### Identity

| problem | cell | why |
|---|---|---|
| a maintainer script changes ownership to a system group (`chown root:adm`, `install -g`) | root, once | subid: a view that maps more ids ([`admin-features.md`](admin-features.md)) |
| a maintainer script creates a system user or group (`adduser --system`, `useradd`, `groupadd`, a `sysusers.d` file) | never | the account would exist only in the prefix's `/etc/passwd`; the kernel and every other program use the host's |

### Kernel

| problem | cell | why |
|---|---|---|
| the distribution disables unprivileged user namespaces (or overlayfs in one), so no view can be built | root, once | `admin/enable-userspace.sh` |
| kernel modules, `/boot`, initramfs | never | loaded or booted by the system, as root |

## Run

### Files

| problem | cell | what solves it | where |
|---|---|---|---|
| the prefix's programs are not on `PATH` | done | `$PREFIX/bin` and `$PREFIX/usr/bin` on `PATH`, for shells and the desktop session | `scripts/setup/install-shell-path.sh`, `install-session-env.sh` |
| a program looks for its files at `/usr/...`, `/etc/...`, `/opt/...` (compiled-in paths, an interpreter's module path, a library only in the prefix, an alternatives link, a shebang naming an interpreter only in the prefix) | done | `prefix-wrap` gives it a script in `$PREFIX/bin` that runs it in the shared run view; every other program runs directly | [`view.md`](view.md#how-programs-get-there) |
| a disk mounted after the run view started is not in it | done | the run view receives the host's mounts (`--propagation slave`) | [`view.md`](view.md#host-mounts) |
| a desktop app has no launcher or icon | done | `XDG_DATA_DIRS` for the session, and the desktop database refreshed after each dpkg run | `install-session-env.sh`, `apt-dpkg/config/apt.conf.d/01update-desktop-database.in` |
| a program that is not a service needs a path in `/run` owned by root | never | owned by root on the host; a service's `/run` paths are moved to `$XDG_RUNTIME_DIR` instead | |

### Identity

| problem | cell | why |
|---|---|---|
| a program needs to be in a system group (`adm` to read logs, `shadow`) | never | group membership on the host is the admin's; the groups for devices are the **device** row |

### Service

| problem | cell | what solves it | where |
|---|---|---|---|
| a package's service (a systemd unit, system or user) is never started | done | `prefix-units` translates it into a user unit run by the user's own systemd, in a service view with the prefix's `/var`, starts it if the package enabled it, restarts it on upgrade and removes it with the package | [`services.md`](services.md), `apt-dpkg/config/apt.conf.d/04units.in` |
| the unit's own sandbox (`ProtectSystem=`, `PrivateTmp=`, ...) is dropped, so the service runs less isolated than on Debian | partly | not yet: the user manager can build it around the service view ([`services.md`](services.md#what-is-left)) | |
| drop-ins (`*.service.d`) are not read; a failed unit is not restarted on upgrade | partly | not yet | `tools/prefix-units.sh` |
| a service must run without the user logged in | root, once | linger for the user (`loginctl enable-linger`) | |
| a service that runs as a system user its package creates, or has only an init script | never | the user cannot be created without root (`prefix-check` refuses the package); an init script is started by the system's init | |

### Network

| problem | cell | what solves it |
|---|---|---|
| a service listens on a port from 1024, or on a socket in `/run` | done | any user can bind the port; the socket path is moved to `$XDG_RUNTIME_DIR` |
| a daemon wants a TUN device and has a userspace mode (tailscale's `--tun=userspace-networking`) | partly | set the mode in the package's config; other programs reach the network through its proxy, not an interface |
| a daemon asks for larger socket buffers | partly, or root, once | it runs with the kernel's defaults, slower; `net.core.rmem_max` and `wmem_max` raise them for all |
| a service listens on a port below 1024 | root, once | `net.ipv4.ip_unprivileged_port_start`; until then, another port in its config (mini-httpd on 8080) |
| a TUN device with no userspace mode, firewall rules, raw sockets | never | CAP_NET_ADMIN or CAP_NET_RAW on the host |

### Device

| problem | cell | what the admin does |
|---|---|---|
| a program needs a device (`/dev/ttyUSB*`, `/dev/kvm`) | root, once | add the user to its group (`dialout`, `kvm`) |

### Privilege

| problem | cell | why |
|---|---|---|
| a setuid or setgid program, or one with file capabilities | never | the files in the prefix belong to the user, and a user namespace grants no privilege on the host |

### Kernel

| problem | cell | what the admin does |
|---|---|---|
| no user namespaces: the run view cannot be built | root, once | `admin/enable-userspace.sh` (the same step as for installing) |

## Survey

The survey installs and runs every package in a sample and records the
first cell each one hits ([`survey.md`](survey.md)).
