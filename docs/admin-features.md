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
| **linger** | `loginctl enable-linger USER` | systemd's per-user manager, running as the user | services from packages that ship **user** units (`/usr/lib/systemd/user`), started at boot and kept after logout | low: the services run as the user |
| **subid** | ranges in `/etc/subuid` and `/etc/subgid`, and the `uidmap` package | `newuidmap` and `newgidmap` (setuid, from shadow) | a view that maps more ids, so `chown` and `install -g adm` in maintainer scripts work; rootless podman as a whole-system fallback for packages that stay **never** | low to medium: files may end up owned by subordinate ids, which the user manages only from inside a namespace |
| **devices** | the user added to a group from a fixed list: `dialout`, `plugdev`, `video`, `render`, `kvm`; or a udev rule tagging one device `uaccess` | kernel file permissions and ACLs | serial and USB devices, the GPU, KVM | low, if the list stays fixed |
| **ports** | `net.ipv4.ip_unprivileged_port_start` in `/etc/sysctl.d` | kernel | servers on ports below 1024 | medium: it applies to every user on the host |
| **mounts** | a polkit rule allowing one action (such as `org.freedesktop.udisks2.filesystem-mount`) for one user | udisks, a distro daemon built for this | mounting removable disks without a password | medium: keep it to one action and one user |
| **enablers** | host packages: `bubblewrap`, `uidmap`, `fuse3` | the distribution, with security support | makes the other rows possible on a minimal install | low |

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
  - with linger, a package whose services are all user units is allowed
    instead of refused;
  - with subid, the install view maps the extra ids.
- **Documented as rows** of the root, once column in
  [`problems.md`](problems.md), each naming the cells it unlocks.

## Order

1. **linger**: it moves real packages out of **never**, runs nothing as
   root, and is easy to test. Measure first: in the survey, how many
   packages ship only user units, and how many ship system units.
2. **subid**: the proper fix for ownership changes in maintainer scripts,
   if the survey shows they are common. The podman fallback is a separate,
   larger design.
3. **devices**: a short fixed list, added when a package needs it.
4. **ports** and **mounts**: only on request; they reach beyond one user.

## The test host

State on 2026-09-24:

| feature | state |
|---|---|
| userns | on |
| linger | off |
| subid | ranges set for both accounts; `newuidmap` installed |
| devices | `plugdev` |
| ports | 1024 (the default) |
| enablers | `bwrap`, `newuidmap`, `fusermount3` and `podman` installed |
