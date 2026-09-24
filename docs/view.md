# The prefix view

A **view** is a private mount namespace where the prefix is overlaid on the
host's system directories (`tools/prefix-view.sh`, installed as
`$PREFIX/lib/sudo-less/prefix-view`). In a view:

- the host's files show through, and every write lands in the prefix
  (`$PREFIX/usr`, `$PREFIX/etc`, ...), never on the host;
- `$PREFIX/usr` and `/usr` (and so on) are the same tree, so both spellings of
  a path agree;
- the command runs with the user's own uid.

There are two kinds, and most programs use neither:

| | overlays | built | used by |
|---|---|---|---|
| **install view** | `/usr`, `/etc`, `/var`, `/opt`; `/var/lib/dpkg` is the prefix's own database | fresh for each call (~0.2 s) | dpkg |
| **run view** | `/usr`, `/etc`, `/opt`; `/var` stays the host's | once, kept running in the background; joining it takes ~0.02 s | installed programs that look for their files at `/usr/...`, `/etc/...`, `/opt/...` |
| none | — | — | every other installed program: it runs directly from `$PREFIX/usr/bin` |

In the install view dpkg runs exactly as on Debian: root `/`, admin dir
`/var/lib/dpkg`, config `/etc/dpkg`, log `/var/log/dpkg.log`. It is built
with those paths (`scripts/bootstrap/build-dpkg.sh`), so it needs no
relocation patch, no `--instdir`, no `--force-script-chrootless`. Maintainer
scripts, triggers and `update-alternatives` see a normal system too: a script
that writes `/etc/foo` or runs `/usr/bin/foo` works, and alternatives are the
standard absolute links (`/usr/bin/java` → `/etc/alternatives/java` → ...).

## How dpkg gets there

`$PREFIX/bin/dpkg` (and `dpkg-query`, `dpkg-divert`, `dpkg-statoverride`,
`dpkg-trigger`, `update-alternatives`) is a wrapper
(`apt-dpkg/dpkg-wrapper.sh`) that runs the real program from
`$PREFIX/lib/sudo-less/dpkg` inside the install view. Inside the install
view (`SUDO_LESS_VIEW=install`) it runs it directly. Queries that only read
the database (`dpkg -l`, `-L`, `-S`, `-s`, `--print-foreign-architectures`,
`dpkg-query`) skip the view and get `--admindir=$PREFIX/var/lib/dpkg`, which
works anywhere, the run view included: apt asks dpkg for the foreign
architectures on every run. Anything else from inside the run view
(`SUDO_LESS_VIEW=run`) is refused: an install view cannot be built there.

apt stays outside the view: its `Dir::*` settings already point into the
prefix. It calls the wrapper and passes `--admindir $PREFIX/var/lib/dpkg`,
which inside the view is the same directory as `/var/lib/dpkg`.

## How programs get there

After every dpkg run apt calls `prefix-wrap` (`tools/prefix-wrap.sh`, hook
`config/apt.conf.d/02view-wrappers.in`). For each package installed or
changed since its last run, and each alternative, it looks at the programs
the package puts on `PATH` and decides whether each one needs the view. A
program needs it when (first match):

| reason | example |
|---|---|
| it is a symlink that leaves the prefix | `/usr/bin/java` → `/etc/alternatives/java`, which the host may not have |
| its script interpreter is not on the host | `#!/usr/bin/ruby` when only the prefix has Ruby |
| its interpreter searches only compiled-in module paths: Python, Perl, Ruby, Node, PHP, Lua, Tcl, R, Guile | `ranger` (`#!/usr/bin/python3`), `cowsay` (Perl) |
| `ldd` cannot find one of its libraries: it is in `$PREFIX/usr/lib` | `w3m` (`libgc.so.1`), `fortune` (`librecode.so.3`) |
| it names a file, or a directory of its own, under `/usr`, `/etc` or `/opt` that the prefix has | `figlet` (`/usr/share/figlet`), `gawk` (`/usr/lib/x86_64-linux-gnu/gawk`) |

Directories many packages share (`/usr/bin`, `/usr/share/locale`, the
library directory, ...) do not count. `prefix-wrap --check PROG...` prints
the decision and the evidence without changing anything.

Such a program gets a script of the same name in `$PREFIX/bin` (`$PREFIX/sbin`
for an `sbin` program), which comes before `$PREFIX/usr/bin` on `PATH`:

```sh
#!/bin/sh
# sudo-less view wrapper (prefix-wrap); regenerated, do not edit
exec $PREFIX/lib/sudo-less/prefix-view --run /usr/bin/ranger "$@"
```

The scripts each package got are recorded in
`$PREFIX/var/lib/sudo-less/wrappers/<package>` (`alternatives=<name>` for an
alternative), so they are removed with the package. A file in `$PREFIX/bin`
without that marker line (apt, the dpkg wrappers) is never touched.
`prefix-wrap --all` redoes every package.

Every other program runs directly from `$PREFIX/usr/bin`, with no view:
`less`, `sqlite3`, `shellcheck`, `sl` in the test prefix. That is the common
case: the survey predicted 73% of packages need nothing
([`survey-2026-09.md`](survey-2026-09.md)).

### The run view

`prefix-view --run CMD` joins the running run view with `nsenter` (its user
and mount namespaces), in the current directory, with the caller's
environment; if none is running it starts one first (~0.15 s). The view is
held open by a background process, `sudo-less-run-view infinity`, whose pid
is in `$PREFIX/.sudo-less/view/run.pid`. It is started once, under a lock,
at login by the user unit `sudo-less-run-view.service`
(`scripts/setup/install-session-env.sh`), or on first use.

It is stopped, and rebuilt by the next `--run`, when:

- `prefix-wrap` saw a package change in the prefix (so the view shows the new
  files, and no two overlays write the same upper directory for long);
- the host's `/var/lib/dpkg/status` is newer than it (the host's packages
  changed);
- `prefix-view --stop` is run.

Programs already running in an old view keep it until they exit. Inside the
run view `prefix-view --run` runs its command directly, so a wrapped program
that starts another wrapped program stays in the same view.

### Host mounts

A view's mounts are slaves of the host's (`unshare --propagation slave`): a
USB stick or network share mounted on the host after the view was built
shows up in it, and disappears from it when unmounted. The holder process
runs in `/`, so it never keeps a mount busy. (With the default, private
propagation, a long-lived run view would never see the stick, and would keep
a copy of any mount that existed when it was built.) Mounts made inside a
view never reach the host.

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

- **Batched setup.** Building a view walks the host's mount table and
  creates a skeleton directory for every entry of a directory with locked
  mounts under it. Those are made with one `mkdir -p` and one `cp` per
  directory, not one per entry: the install view went from ~0.4 s to
  ~0.2 s.

## Limits of the run view

- It sees the host's `/var`, not the prefix's. No program the survey
  checked needs its own `/var`; one that keeps state there writes it in the
  prefix's `/var` only when installed, not when run.
- dpkg (anything that builds an install view) cannot run inside it; run apt
  from a normal shell.
- A `.desktop` file with an absolute `Exec=/usr/bin/foo` starts the host's
  path, not the wrapper; a relative `Exec=foo` finds the wrapper through the
  session's `PATH`.
- While an install is running, the old run view and the install view
  overlay the same prefix directories; the run view is stopped right after
  (`prefix-wrap`), but a program started from it in between can see files
  half-installed.
- `tools/prefix-run.sh` (the older per-command overlay with tiers) is still
  there; the wrappers do not use it.

## State

`$PREFIX/.sudo-less/view/` holds the mirror stamp, the run view's pid, lock
and log, the `prefix-wrap` stamp, each running view's overlay work
directories (`work/<pid>`, removed by the next view once that process has
exited) and a mount point for the view's temporary skeletons.
`$PREFIX/var/lib/sudo-less/wrappers/` records the scripts each package got.
