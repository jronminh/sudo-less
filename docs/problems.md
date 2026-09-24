# The problem map

Everything that stands between a `.deb` and a user without root, sorted on
two axes:

- **when** it bites: while **installing** the package (apt and dpkg,
  maintainer scripts), or while **running** its programs;
- **who** can fix it:
  - **non-root:** sudo-less does it by itself, for every package, with no
    root at any point;
  - **root, once:** the admin does one step, once for every user and every
    package (enable user namespaces, upgrade the host); after that it is
    non-root;
  - **never:** the package needs root each time it installs or runs, because
    it changes the system itself (a system user, a service, a kernel module,
    a setuid program). It never runs from the prefix: the admin installs it
    system-wide instead.

Each package's verdict is the worst cell it falls in. The user sees only
that verdict ([`standard.md`](standard.md)); this page is the inside view,
for people working on sudo-less. The numbers are from
[`survey-2026-09b.md`](survey-2026-09b.md).

## The grid

| | non-root | root, once | never |
|---|---|---|---|
| **install** | dpkg and its database in the prefix; the host's packages counted as installed; maintainer scripts in the install view; refusing what cannot work before dpkg runs | unprivileged user namespaces and overlayfs; version skew (upgrade the host) | system users and groups; kernel modules and `/boot` |
| **run** | `PATH`; the run view for programs that look for their files at `/usr`, `/etc`, `/opt`; desktop launchers | unprivileged user namespaces (the same step); device groups | services and daemons; setuid and file capabilities; `/run`, privileged ports |

More admin steps, each unlocking some cells, are planned in
[`admin-features.md`](admin-features.md).

## Install

### Non-root

| problem | what solves it | where |
|---|---|---|
| dpkg writes to `/var/lib/dpkg` and `/`, which need root | dpkg and its database live in the prefix; dpkg runs in the install view, where the prefix is `/usr`, `/etc`, `/var`, `/opt` | [`apt-dpkg-port.md`](apt-dpkg-port.md), [`view.md`](view.md) |
| apt would install again everything the host already has | the prefix's database is seeded with the host's packages, held | `apt-dpkg/lock-seeded.sh` |
| maintainer scripts write `/etc` and `/var`, run `update-alternatives`, `py3compile`, `ldconfig`, triggers, the package's own programs | the install view: the script sees a normal system and every write lands in the prefix | [`view.md`](view.md#how-dpkg-gets-there) |
| maintainer scripts call the host's services (`systemctl daemon-reload`, `deb-systemd-invoke`, `pkexec`), which asks polkit, and the admin's password dialog pops up on the desktop | the install view has an empty `/run`: no system bus, no systemd; debhelper's guards skip the service steps | [`view.md`](view.md#how-dpkg-gets-there) |
| a package that cannot install fails half way and leaves the prefix wedged: every later apt run tries to configure it again | `prefix-check` reads each `.deb` before dpkg runs and refuses the run, naming the package and the reason, if one falls in the **never** column | `tools/prefix-check.sh`, `apt-dpkg/config/apt.conf.d/03check.in` |

### Root, once

| problem | what the admin does |
|---|---|
| the distribution disables unprivileged user namespaces (or overlayfs in one), so no view can be built | `admin/enable-userspace.sh` |
| **version skew:** on a rolling host a newer package needs a newer system library than the host has, and the host's copy is held | upgrade the host (`apt upgrade`); the prefix follows at its next reseed |

### Never

| problem | why it cannot be done from the prefix |
|---|---|
| a maintainer script creates a system user or group (`adduser --system`, `useradd`, `groupadd`) | the account would exist only in the prefix's `/etc/passwd`; the kernel and every other program use the host's |
| kernel modules, `/boot`, initramfs | loaded or booted by the system, as root |

## Run

### Non-root

| problem | what solves it | where |
|---|---|---|
| the prefix's programs are not on `PATH` | `$PREFIX/bin` and `$PREFIX/usr/bin` on `PATH`, for shells and the desktop session | `scripts/setup/install-shell-path.sh`, `install-session-env.sh` |
| a program looks for its files at `/usr/...`, `/etc/...`, `/opt/...` (compiled-in paths, an interpreter's module path, a library only in the prefix, an alternatives link, a shebang naming an interpreter only in the prefix) | `prefix-wrap` gives it a script in `$PREFIX/bin` that runs it in the shared run view; every other program runs directly | [`view.md`](view.md#how-programs-get-there) |
| a disk mounted after the run view started is not in it | the run view receives the host's mounts (`--propagation slave`) | [`view.md`](view.md#host-mounts) |
| a desktop app has no launcher or icon | `XDG_DATA_DIRS` for the session, and the desktop database refreshed after each dpkg run | `install-session-env.sh`, `apt-dpkg/config/apt.conf.d/01update-desktop-database.in` |

### Root, once

| problem | what the admin does |
|---|---|
| no user namespaces: the run view cannot be built | `admin/enable-userspace.sh` (the same step as for installing) |
| a program needs a device (`/dev/ttyUSB*`, `/dev/kvm`) | add the user to its group (`dialout`, `kvm`) |

### Never

| problem | why |
|---|---|
| a service or daemon (a system unit, an init script, a system user to run as) | started by the system's init, as root |
| a setuid or setgid program, or one with file capabilities | the files in the prefix belong to the user, and a user namespace grants no privilege on the host |
| a program that needs `/run/...`, a privileged port, or a system group | owned by root on the host |

## Survey

The survey installs and runs every package in a sample and records the
first cell each one hits ([`survey-2026-09b.md`](survey-2026-09b.md)).
