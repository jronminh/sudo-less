# Security

What sudo-less protects, from whom, and what it does not. The code was
written with AI assistants and has not had an independent security review;
the findings of the reviews so far are GitHub issues (#29, #38). Everything
marked *measured* was tested on a live host (Debian forky, kernel 7.1,
util-linux 2.42, systemd 261), on 2026-09-25 unless dated otherwise.

## What you trust

| what | why you can |
|---|---|
| the packages | apt verifies the archive's signatures (with the host's `sqv`) and installs only from the sources you configured, as on Debian |
| the prebuilt `apt` and `dpkg` | their inputs are pinned and public, and the build is reproducible: [`release.md`](release.md#trust-model-pinned-inputs-verifiable-output) |
| this repository's scripts | plain bash, no binaries of their own; read them |
| the admin's one-time step | `admin/` only enables what the kernel and the distribution already guard; it never runs your software as root ([`admin-features.md`](admin-features.md#the-rule)) |

## What a package can reach

On Debian, installing a package trusts it with root: its maintainer scripts
run as root. sudo-less never has root, so a package can at most do what you
can. Within that, each stage gives it less than you have:

| stage | runs as | sees and can write | cannot reach |
|---|---|---|---|
| **installing**: dpkg and the maintainer scripts, in the [install view](view.md) | you, as "root" of a user namespace | the prefix's `/usr`, `/etc`, `/var`, `/opt`; the host's system files, read-only (they are root's) | your home (hidden but for the prefix), `/tmp` (private), `/media`, `/mnt`, `/run` (empty: no system bus, no systemd, no polkit) |
| **a service** from a system unit, in the [service view](view.md#the-service-view) | you | its state directories, the services' `/run`; the rest read-only (default sandbox) | your home, `/run/user` (the session bus, the user manager's private socket, Wayland, the agents), setuid programs (`NoNewPrivileges=`) |
| **a service** from a user unit | you | its own `~/.local/state/NAME`, `~/.cache/NAME` and runtime directory; the rest read-only (default sandbox) | the rest of your home, your session's sockets, setuid programs; what else it needs you open ([`services.md`](services.md#the-default-sandbox)) |
| **a program you run**, directly or in the [run view](view.md#the-run-view) | you | what you can | nothing: running a program is trusting it, as on any system |

So the sandboxes protect you from a package while it **installs**, and from
its **services**, system or user, whether the package or a compromised
daemon is what misbehaves. Once you run what a
package installed, it runs as you.

## Installing: the install view

dpkg runs in a private mount namespace (the install view) that shows the
prefix where Debian has `/usr`, `/etc`, `/var` and `/opt`, with a sandbox
on top (`tools/prefix-view.sh`, `tools/prefix-sandbox.sh`):

- **An empty `/run`.** Without it a maintainer script reached the host's
  own services through the system bus: `php-common`'s postinst runs
  `systemctl --system daemon-reload`, and polkit popped up a dialog asking
  for the admin's password on the desktop. With an empty `/run`,
  `systemctl` finds no systemd, `deb-systemd-invoke` and `pkexec` find no
  bus, and debhelper's `[ -d /run/systemd/system ]` guards skip the service
  steps.
- **Your home hidden** (`ProtectHome=yes`), but for the prefix's `/usr`,
  `/etc`, `/var`, `/opt` (writable) and sudo-less's own tools
  (`$PREFIX/bin`, `sbin`, `lib/sudo-less`, read-only). A `.deb` from outside
  the prefix (`dpkg -i ~/Downloads/foo.deb`) is bound in, read-only; the
  dpkg wrapper makes relative paths absolute, since the view starts in `/`.
- **A private `/tmp`**, and `/media` and `/mnt` out of reach.

`dev/hostile-debs.sh` builds hostile packages, installs them with the
prefix's dpkg and purges them. Measured:

| a hostile package | without the sandbox | with it |
|---|---|---|
| a postinst writes `$HOME` | written | refused |
| a postinst reads a file in `$HOME` | read | refused |
| a postinst lists `$HOME` | everything | `.local` only |
| package A ships a symlink into `$HOME`, package B a file through it | written into `$HOME` | refused |
| a `data.tar` member named `../../..../file` | written into `$HOME` | refused |
| a setuid bit | dropped | dropped |

The fourth and fifth rows are dpkg's own behaviour (it follows directory
symlinks, as `/lib → usr/lib` needs); on Debian they would write as root.

## Services: the sandbox

On Debian a system service runs as a system user, and that is what keeps
it from your files. Here it runs as you, so a compromised daemon could
rewrite `~/.bashrc`, or a program in `~/.local/bin` you run later. So a
system unit keeps the sandbox it declares (`ProtectSystem=`,
`SystemCallFilter=`, `RestrictNamespaces=`, ...), gets
`ProtectSystem=strict`, `ProtectHome=yes` and `PrivateTmp=yes` where it
sets none, and never goes below a floor: `ProtectHome=yes`,
`ProtectSystem=` `full` or `strict`, `PrivateTmp=yes`,
`NoNewPrivileges=yes`, the package database read-only
([`services.md`](services.md#the-default-sandbox)).

How it holds ([`view.md`](view.md#the-sandbox) has the mechanics):

- **The mounts cannot be undone.** `prefix-sandbox` makes them as root of
  the view's user namespace, then gives the command your uid in a new user
  namespace below it. The command is not root of the namespace that owns
  the mounts, so it cannot unmount or remount them; in a user namespace of
  its own they are locked (the kernel's `MNT_LOCKED`), so it cannot
  uncover what they hide.
- **Other processes' views are closed to it.** From the service's user
  namespace, `/proc/PID/root`, `/cwd` and `/environ` of your other
  processes are refused (measured, with `yama.ptrace_scope` not involved:
  the same reads from a process outside the namespace succeed).
- **Syscall filters load last.** After the mounts and the uid, just before
  `exec`: a seccomp program built in bash and loaded by `setpriv
  --no-new-privs --seccomp-filter`. `RestrictNamespaces=` is what stops a
  service from making a user namespace of its own, where it would have
  every capability; `CapabilityBoundingSet=` cannot, so it is not taken.
- **The sandbox is data, not a command line.** `prefix-units` writes the
  unit's directives into the generated user unit as `# sudo-less sandbox:`
  lines, which `prefix-sandbox` reads; the `ExecStart=` line carries none
  of the package's values, so none can close a quote and add options
  (#38). A package's own lines with that marker are dropped.
- **The package does not decide its sandbox.** It declares one, and a
  security stage in `prefix-units` checks the result last: the floor
  above cannot be lowered (`ProtectHome=no` is raised to `yes`), write
  access and binds stay inside a service's state, paths with `..` are
  dropped, and so is a command outside `[Service]`, which would run
  without the sandbox (a socket's `ExecStartPre=`). The environment the
  unit sets is not read. Only you loosen a sandbox, in
  `~/.config/sudo-less/sandbox/UNIT`, where a package cannot write.
  Measured with a unit that tried all of these at once: `ProtectHome=no`,
  `ProtectSystem=no`, `PrivateTmp=no`, `NoNewPrivileges=no`,
  `Environment=SUDO_LESS_SANDBOX=off`, `ReadWritePaths=` into `$HOME`, its
  runtime directory and the package database, `BindPaths=$HOME:...`,
  `BindReadOnlyPaths=/:...` and `/run:...`, `StateDirectory=../../home/...`,
  and a socket's `ExecStartPre=` writing `$HOME`; nothing reached `$HOME`.

## Known limits

- **The programs you run are not sandboxed.** Running a program is
  trusting it, as on any system.
- **A user unit's sandbox is by name and by list.** A user unit writes
  its directories where its user manager has them, so that it works with
  what else you run, and the package picks their names:
  - it may read and write `~/.local/state/NAME` and `~/.cache/NAME` for
    its unit's name and any `StateDirectory=`/`CacheDirectory=` it
    declares, so a unit named after another program reaches that
    program's state or cache (a `syncthing` unit, the config of a
    syncthing you run yourself; a `pip` one, pip's cache of wheels);
  - its `RuntimeDirectory=` in `$XDG_RUNTIME_DIR` is refused only for the
    names of the session's sockets known today (`systemd`, `bus`,
    `gnupg`, `pipewire-0`, `wayland-0`, ...); another program's socket
    directory (a password manager's, say) is not on the list, and
    systemd removes a runtime directory when the unit stops.

  Isolating these directories in sudo-less's own area was tried and
  rolled back: a service's files and sockets would no longer be where
  other programs look for them. `~/.config` and `~/.local/share`, where
  shells and desktops find code to run, stay closed either way.
- **The network is shared.** Maintainer scripts and services can reach the
  network, and with it abstract unix sockets, which belong to the network
  namespace, not to a path. The one found on the test host is Xwayland's
  (`@/tmp/.X11-unix/X1`); it wants its cookie, which is under the hidden
  `/run/user` (measured: `xdpyinfo` cannot open the display from the
  install view).
- **Same uid.** A service can send signals to your other processes
  (measured: `kill -0` succeeds), and without a PID namespace it sees the
  list of processes and their command lines.
- **Syscall filters** exist only on x86_64 and aarch64, and refuse the
  other ABIs (i386, x32); a `setpriv` older than util-linux 2.40 has no
  `--seccomp-filter`, and a service that asks for a filter then does not
  start.
- **The admin's step** enables unprivileged user namespaces, which widens
  the kernel's attack surface for every user on the host. Debian enables
  them by default; the step matters where a distribution does not
  (#37).

## Reporting

Open an issue on GitHub. For something that should not be public first,
say so in a short issue without the details, and the maintainer will get
in touch.
