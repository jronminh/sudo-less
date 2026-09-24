# The prefix view

dpkg in sudo-less runs inside a **view**: a private mount namespace where the
prefix is overlaid on the host's `/usr`, `/etc`, `/var` and `/opt`
(`tools/prefix-view.sh`, installed as `$PREFIX/lib/sudo-less/prefix-view`).
In the view:

- the host's files show through, and every write lands in the prefix
  (`$PREFIX/usr`, `$PREFIX/etc`, ...), never on the host;
- `/var/lib/dpkg` is the prefix's own database (`$PREFIX/var/lib/dpkg`), not
  merged with the host's;
- `$PREFIX/usr` and `/usr` (and so on) are the same tree, so both spellings of
  a path agree;
- the command runs with the user's own uid.

So dpkg runs exactly as on Debian: root `/`, admin dir `/var/lib/dpkg`, config
`/etc/dpkg`, log `/var/log/dpkg.log`. It is built with those paths
(`scripts/bootstrap/build-dpkg.sh`), so it needs no relocation patch, no
`--instdir`, no `--force-script-chrootless`. Maintainer scripts, triggers and
`update-alternatives` see a normal system too: a script that writes
`/etc/foo` or runs `/usr/bin/foo` works, and alternatives are the standard
absolute links (`/usr/bin/java` → `/etc/alternatives/java` → ...).

## How dpkg gets there

`$PREFIX/bin/dpkg` (and `dpkg-query`, `dpkg-divert`, `dpkg-statoverride`,
`dpkg-trigger`, `update-alternatives`) is a wrapper
(`apt-dpkg/dpkg-wrapper.sh`) that runs the real program from
`$PREFIX/lib/sudo-less/dpkg` inside the view. Inside a view
(`SUDO_LESS_VIEW` set) it runs it directly. Queries that only read the
database (`dpkg -l`, `-L`, `-S`, `-s`, `--print-foreign-architectures`,
`dpkg-query`) skip the view and get `--admindir=$PREFIX/var/lib/dpkg`:
entering the view costs about 0.3 s, and apt asks dpkg for the foreign
architectures on every run.

apt stays outside the view: its `Dir::*` settings already point into the
prefix. It calls the wrapper and passes `--admindir $PREFIX/var/lib/dpkg`,
which inside the view is the same directory as `/var/lib/dpkg`.

## What it needs

- unprivileged user namespaces (on by default on Debian; Ubuntu 24.04 and
  later restrict them with AppArmor, see `admin/enable-userspace.sh`);
- overlayfs in a user namespace (kernel 5.11 or later);
- util-linux `unshare` 2.38 or later (`--map-user`).

## Limits of an unprivileged overlay, and how the view works around them

- **Locked mounts.** overlayfs refuses a lower layer with mounts under it
  (in a user namespace they are locked). `/var`, for example, holds lxcfs
  or Waydroid mounts. Such a directory gets a skeleton of its entries as its
  lower layer; plain subdirectories get an overlay of their own, and mount
  points are bound from the host.
- **No copy-up of root's directories.** Creating a file in a directory the
  prefix has no copy of would need overlayfs to copy the directory up, owned
  by root, which a user namespace cannot map. So before entering, the prefix
  gets its own empty copy of each host directory likely to be written to:
  - the directories the `.deb` files being installed put files in (the
    wrapper passes them in `PREFIX_VIEW_DEBS`; apt's `--recursive` directory
    is scanned);
  - every directory of `/etc`, `/var` and `/opt`, `/usr`'s first two levels
    and `/usr/share/mime`, where maintainer scripts and triggers keep state,
    configuration and caches: about 1500, redone when the host's package set
    changes (`$PREFIX/.sudo-less/view/mirror.stamp`).

  A script that writes into some other host directory its package does not
  ship fails with "Permission denied"; `PREFIX_VIEW_MIRROR=full` copies every
  host directory (about 10000) instead.
- **No in-place writes to root's files.** A host file can be replaced
  (write a new file, rename it over) but not appended to. dpkg appends to
  `/var/log/dpkg.log`, so `apt-dpkg/install.sh` gives the prefix its own.
- **No hard links to root's files.** dpkg hard-links a file it is about to
  replace as a backup; for a host file it copies it instead
  (`patches/dpkg/0103-link-or-copy.patch`).

## State

`$PREFIX/.sudo-less/view/` holds the mirror stamp, each running view's
overlay work directories (`work/<pid>`, removed by the next view once that
process has exited) and a mount point for the view's temporary skeletons.
