# Admin features: giving userspace more, safely

A plan for extending what a user can do without root, by adding admin steps
that each unlock one thing. Nothing here is built yet except user
namespaces (`admin/enable-userspace.sh`). It is the reference for that work.

On the [problem map](problems.md) these are the **root, once** column: each
feature moves some packages out of **never** or **root** and into
**non-root**.

## The rule

An admin step gives userspace something once. After that, no root code runs
when the user uses it, except code the distribution maintains and designed
for unprivileged callers.

1. **Root runs only at setup.** A step writes a file under an `/etc/*.d/`
   directory, sets a sysctl, or adds the user to a group. Then it is done.
2. **Root code that runs later is the distribution's**, built for untrusted
   callers: the kernel, `newuidmap` and `newgidmap`, `fusermount3`, systemd's
   per-user manager, polkit and udisks. It is never a sudo-less script and
   never a file from the prefix.
3. **Each grant is narrow and can be undone:** one file per feature, with a
   marker line, and an `--undo` that removes exactly that file.
4. **Nothing that amounts to root.** The user can write every file in the
   prefix, so anything that trusts a prefix file as root is root for the
   user. Never:
   - a setuid bit or file capability on a file in the prefix;
   - a sudoers entry, not even `NOPASSWD` for one command;
   - the `docker`, `lxd`, `libvirt`, `disk`, `shadow` or `sudo` groups;
   - a root daemon or helper written by sudo-less.

The same rule holds inside sudo-less: the install view must not let a
maintainer script reach the host's root services. It hides the host's
`/run` for that reason ([`view.md`](view.md#how-dpkg-gets-there)).

## Candidates

| feature | the admin runs | the kernel or distro enforces it | what it unlocks | risk |
|---|---|---|---|---|
| **userns** (done) | a sysctl in `/etc/sysctl.d` | kernel | the install and run views | low: Debian's default |
| **linger** | `loginctl enable-linger USER` | systemd's per-user manager, running as the user | the user manager, and with it every service from the prefix ([`services.md`](services.md)), started at boot and kept after logout instead of only while the user is logged in | low: the services run as the user |
| **subid** | ranges in `/etc/subuid` and `/etc/subgid`, and the `uidmap` package | `newuidmap` and `newgidmap` (setuid, from shadow) | a view that maps more ids, so `chown` and `install -g adm` in maintainer scripts work; rootless podman as a whole-system fallback for packages that stay **never** | low to medium: files may end up owned by subordinate ids, which the user manages only from inside a namespace |
| **devices** | the user added to a group from a fixed list: `dialout`, `plugdev`, `video`, `render`, `kvm`; or a udev rule tagging one device `uaccess` | kernel file permissions and ACLs | serial and USB devices, the GPU, KVM | low, if the list stays fixed |
| **cgroups** | `Delegate=` in a drop-in for `user@.service` | systemd, and the kernel's cgroup v2 delegation | limits on the user's own processes beyond systemd's default `pids memory cpu`, such as `cpuset` and `io` (rootless podman's `--cpuset-cpus`) | low: the user limits only their own processes |
| **ports** | `net.ipv4.ip_unprivileged_port_start` in `/etc/sysctl.d` | kernel | servers on ports below 1024 | medium: it applies to every user on the host |
| **mounts** | a polkit rule allowing one action (such as `org.freedesktop.udisks2.filesystem-mount`) for one user | udisks, a distro daemon built for this | mounting removable disks without a password, from outside the seat (over SSH, from a service); udisks already allows it for the active local session, and a fresh install has neither udisks nor polkitd | medium: keep it to one action and one user |
| **enablers** | host packages: `bubblewrap`, `uidmap`, `fuse3` | the distribution, with security support | makes the other rows possible; none of them is in a fresh install ([measured](#debians-privilege-surface-measured)) | low |

Stays **never** whatever the admin enables: system users on the host,
kernel modules, `/boot`, and setuid programs.

## Layout

- **One script per feature** under `admin/features/`: `userns.sh`,
  `linger.sh`, `subid.sh`, `devices.sh`, `ports.sh`, ... Each is idempotent,
  prints what it will change before calling `sudo`, and takes `--undo`.
  `admin/enable-userspace.sh` becomes `userns.sh` plus `PATH`.
- **Detection, not configuration.** sudo-less never asks the admin at run
  time. It reads the host (sysctls, `/etc/subuid`, `loginctl show-user`,
  `id -Gn`), and `sudo-less doctor` reports which features are on.
- **Verdicts follow the features.** `prefix-check` and `prefix-wrap` ask the
  same detection:
  - with linger, the prefix's services start at boot instead of at login;
  - with subid, the install view maps the extra ids.
- **Documented as rows** of the root, once column in
  [`problems.md`](problems.md), each naming the cells it unlocks.

## Order

1. **linger**: it keeps the prefix's services running without a login,
   runs nothing as root, and is easy to test. The services themselves no
   longer need it: `prefix-units` runs them while the user is logged in
   ([`services.md`](services.md)).
2. **subid**: the proper fix for ownership changes in maintainer scripts,
   if the survey shows they are common. The podman fallback is a separate,
   larger design.
3. **devices**: a short fixed list, added when a package needs it.
4. **ports** and **mounts**: only on request; they reach beyond one user.

## Debian's privilege surface, measured

What a fresh install already gives an unprivileged user, so that a feature
above is never an admin step for something Debian grants anyway.
[`dev/privilege-surface.sh`](../dev/privilege-surface.sh) measures it from
the archive: the fresh install is every package of priority required,
important or standard, which is what debian-installer's "standard system
utilities" task installs ([tasksel](https://wiki.debian.org/tasksel)), plus
their dependencies and Recommends. For forky on amd64, 2026-09-25, that is
315 packages.

| channel | in a fresh install | from |
|---|---|---|
| setuid, setgid | `passwd`, `chsh`, `chfn`, `gpasswd`, `chage`, `expiry`, `su`, `newgrp`, `mount`, `umount`, `unix_chkpwd`, `ssh-keysign`, `exim4`, `dotlockfile`; `ssh-agent` (a tmpfiles.d `z` line); `dbus-daemon-launch-helper` (dpkg-statoverride in postinst) | passwd, util-linux, mount, PAM, openssh-client, exim4, liblockfile, dbus |
| file capabilities | none | |
| polkit | action files from systemd and dpkg, but **no `polkitd`**, so no polkit grant reaches a user | |
| root D-Bus services | logind, hostnamed, localed, networkd, timesyncd | systemd |
| devices | groups (`audio`, `video`, `render`, `kvm`, `dialout`, ...) and the `uaccess` tag for the seat's user | udev, systemd |
| sysctls | `ping_group_range = 0 2147483647` (unprivileged ping for everyone), `protected_*` | linux-sysctl-defaults |
| not installed | `uidmap`, `fuse3`, `bubblewrap`, `polkitd`, `sudo` | all priority optional |

So a fresh install grants almost nothing beyond the classic Unix set, all
from the core packages. The rest comes with a desktop: installing one adds
polkitd and the daemons that ship their own polkit policy (udisks2,
NetworkManager, fwupd, flatpak, ...), and a large share of their actions
are allowed without a password to the **active local session**. On the
test host, with Phosh, that is 87 of 276 actions from 24 packages, such as
udisks2's `filesystem-mount`. sudo-less does not rely on them: they depend
on a desktop being installed, and they do not apply over SSH.

## What packages ask for

The other side: how many packages in the archive ship each kind of file
that needs a privilege, counted by the same script from the Contents index
(forky `main`, amd64 and `all`, 70397 packages, 2026-09-25). A file is what
a package carries, not proof that it needs it to run: many packages with a
user unit also run fine started by hand.

| a package ships | packages | share | here |
|---|---|---|---|
| a system service (a unit in `/usr/lib/systemd/system` or an init script) | 1485 | 2.1 % | non-root, translated into a user unit ([`services.md`](services.md)), unless it runs as a system user or has only an init script |
| a tmpfiles.d entry (`/run`, `/var/log`, modes at boot) | 354 | 0.5 % | mostly with a service |
| a udev rule | 296 | 0.4 % | **devices** |
| a system user (`sysusers.d`) | 255 | 0.4 % | **never** |
| a user service (a unit in `/usr/lib/systemd/user`) | 239 | 0.3 % | **linger** |
| a polkit action, a D-Bus system policy | 166, 148 | 0.2 % each | **never**: a root daemon's |
| a PAM configuration | 88 | 0.1 % | **never** |
| a cron.d job | 81 | 0.1 % | **never** |
| a kernel module, dkms source, modprobe.d, sysctl.d | 15, 41, 8, 8 | < 0.1 % | **never** |
| any of these, user units and tmpfiles.d aside | 2069 | 2.9 % | |
| for scale: a program in `/usr/bin` | 13906 | 19.8 % | |
| for scale: a desktop entry | 2742 | 3.9 % | |

Maintainer scripts are not in the Contents index. The
[survey](survey-2026-09.md) measured them instead: 13 % of installs were
blocked by one, mostly writes to `/etc` or `/var/log` and calls to the
package's own programs, which the install view and shims handle without
any grant; a few create a service or a system user (**never**), and a
`chown` to a system group is what **subid** is for.

So what packages ask for is overwhelmingly one thing, a system service.
Most of those need no grant at all: `prefix-units` translates them into
user units ([`services.md`](services.md)); what stays **never** is a
service that runs as a system user (at least 196 packages ship a
`sysusers.d` file, more create one in postinst) or from an init script
alone (25). The grants reach a small, countable part: **linger** to run
services without a login, udev rules for **devices**, and ownership
changes for **subid**.

## Prior art

Each grant above already exists somewhere. What sudo-less adds is the set
of them under one rule, each undoable and detected rather than configured.

| project | the split | what we take | what we leave |
|---|---|---|---|
| [rootless Podman](https://github.com/containers/podman/blob/main/docs/tutorials/rootless_tutorial.md) | its tutorial has an "Administrator Actions" part and a "User Actions" part; after the admin part, "the user can just start using any Podman command" | the closest match. The admin part is our list: `/etc/subuid` and `/etc/subgid`, `newuidmap`, and, in its [troubleshooting guide](https://github.com/containers/podman/blob/main/troubleshooting.md), `loginctl enable-linger`, `ip_unprivileged_port_start` and a `Delegate=` drop-in for `user@.service` (our **cgroups** row). "Rootless Podman is not, and will never be, root; it's not a `setuid` binary" is our rule 4 | nothing; it is the model |
| [Homebrew on Linux](https://docs.brew.sh/Homebrew-on-Linux) | the admin creates `/home/linuxbrew/.linuxbrew` once "so that you don't need sudo after Homebrew's initial installation" | admin once, then the user installs alone | a fixed prefix outside `$HOME`, shared by whoever owns it |
| [Nix, multi-user](https://nix.dev/manual/nix/latest/installation/multi-user) | unprivileged users install packages, but builds are forwarded to a daemon running as root, which runs them under `nixbld` build users | the goal: installing without root | the root daemon. It is well built, and still what rule 4 forbids: root code sudo-less would own |
| [Flatpak](https://github.com/flatpak/flatpak) | `--user` installs need nothing; system-wide installs go through `flatpak-system-helper`, a root service gated by polkit actions such as `org.freedesktop.Flatpak.app-install` | per-user installs as the default | the root helper for shared installs |
| sudoers, `doas` | the admin allows named commands as root | nothing | a command run as root with user-chosen arguments is root for the user, so rule 4 forbids even one `NOPASSWD` line |

The grants themselves are Debian's own tools for desktop users: groups like
`plugdev` and `dialout`, logind's `uaccess` tag, and polkit rules for
udisks.

## The test host

The test host is a Mobian image, not a fresh install: 56 of the 315
fresh-install packages are missing, among them `linux-sysctl-defaults`
(so unprivileged ping is off), `cron`, `ifupdown` and `util-linux-extra`.
Results measured on it can differ from a fresh Debian.

State on 2026-09-24:

| feature | state |
|---|---|
| userns | on |
| linger | off |
| subid | ranges set for both accounts; `newuidmap` installed |
| devices | `plugdev` |
| cgroups | `pids memory cpu` delegated (systemd's default in `user@.service`); no drop-in |
| ports | 1024 (the default) |
| enablers | `bwrap`, `newuidmap`, `fusermount3` and `podman` installed |
