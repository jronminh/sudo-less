# `updo`: userspace do

`updo` ("userspace do") is `sudo` for a bounded middle identity instead of
the super user: same usage, never root.

Status: **prototype.** Client and daemon exist (`tools/updo/`, C, no
libraries) and pass their tests as `master` against runtime user units
(`tools/updo/dev-backend.sh`, same uid on both ends, see "Prototype"). The
admin side (system users, system units) is not installed.

## The core idea, taken from Android

On the phone, `dsh CMD` runs `CMD` as Android's `shell` uid. `shell` is not
root: it has no effective capabilities, and what it can reach (groups, a few
settings, all of `/proc`) is decided by the system, not by `dsh`
(`docs/system-resources.md` §1.4). So `dsh` can run *any* command and still be
safe, because the identity it runs as is bounded.

Only that part is copied:

> **A command that runs anything, as an identity whose power is fixed by the
> admin in advance and enforced by the kernel.**

`updo CMD` does what `sudo CMD` would do for the things `master` legitimately
needs beyond userspace, as a system user `updo` that can never become root.
Nothing else from Android (SELinux, adbd, pairing, `settings`) is copied.

## The pieces, side by side

| Android (`fe2`) | role | `updo` | lives in |
|---|---|---|---|
| `dsh` | the command the user types | `updo` client | `tools/updo/`, userspace |
| wireless debugging + pairing | who may reach the daemon | unix socket `root:master 0660`, caller uid re-checked with `SO_PEERCRED` | admin, once |
| `adbd` / relaysh daemon | accepts a call, runs it, returns the status | `updo-<id>.socket` (`Accept=yes`) + `updod`, one instance per call, already running as the identity | admin, once |
| uid 2000 `shell` | the bounded identity | `updo-<id>` system users (persistent), or a `DynamicUser` (per call) | admin, once per identity |
| `shell`'s groups (`readproc`, `uhid`, `log`, …) | what the identity can reach | `SupplementaryGroups=`, group-owned setgid dirs | admin, per grant |
| SELinux `shell` domain | a limit the identity cannot lift | systemd sandbox: `ProtectSystem=strict`, `ProtectHome`, `ReadWritePaths=`, `NoNewPrivileges`, no caps | admin, per identity |
| platform services checking uid 2000 | the system decides, not the caller | the kernel (DAC, mount namespace, `no_new_privs`) | kernel |
| `dsh status` | show the state | `updo -l` | client |

So making `updo` real means building four things: the client and daemon (`tools/updo/`, done as a prototype),
the enablement (`admin/native/enable-updo.sh`), a grant tool that creates one
identity with its drop-in and refuses forbidden paths, and the recipe side
(tier `limited`).

## Usage: `sudo` with a different target

`updo` takes `sudo`'s options wherever they make sense, so muscle memory and
scripts carry over (`sudo mkdir -p /etc/x` → `updo mkdir -p /etc/x`), plus
`dsh`'s `-c`/`-f`/`-p`.

```sh
updo                     # interactive shell, prompt "updo> "   (adb shell)
updo CMD [ARG...]        # run CMD as updo                       (sudo CMD, dsh CMD)
updo -s [CMD]            # shell as updo, or CMD through it      (sudo -s)
updo -i [CMD]            # login shell as updo                   (sudo -i)
updo -e FILE...          # edit FILEs as updo                    (sudo -e / sudoedit)
updo -l [CMD]            # what updo may do; with CMD: would it  (sudo -l)
updo -D DIR CMD          # run in DIR                            (sudo -D)
updo --preserve-env=VAR,... CMD   # pass extra variables         (sudo --preserve-env=)
updo -u IDENT CMD        # another middle identity, if several exist (sudo -u)
updo -c 'CMD LINE'       # run a shell command line              (dsh -c)
updo -f FILE             # run the command read from FILE        (dsh -f)
updo -p FILE CMD         # stream FILE to CMD's stdin            (dsh -p)
updo -v | -k | -K        # accepted, do nothing: there is no password to cache
```

Behaviour a `sudo` user expects, kept:

- stdin, stdout, stderr and the exit status pass through. The command gets
  the caller's own file descriptors, so a pipe stays a byte-exact pipe and a
  terminal stays the same terminal (window size, raw mode, full-screen
  programs); Ctrl-C and the other terminal signals are relayed;
- the current directory is kept (sudo's default) when updo can enter it,
  else updo's home, with a warning;
- the environment is reset to an allowlist (`PATH`, `TERM`, `LANG`, `LC_*`),
  as sudo's `env_reset` does; `--preserve-env` adds to it;
- `-e` works like `sudoedit`: the file is copied out, edited by `$EDITOR`
  running as **master**, and written back as updo, so the editor itself never
  runs with updo's rights;
- arguments are quoted by the client, so `updo touch 'a b'` makes one file.

One command for both uses, as `adb shell` is: with a command it is the
scripting interface, without one it is a terminal.

- **bare `updo` opens a shell** (as `adb shell` does); `-s`/`-i` stay for sudo
  habits;
- **the prompt names the identity**, `updo> ` or `lighttpd> `, set after every
  profile so nothing can hide it;
- **shells need a persistent identity**: a per-call (`DynamicUser`) identity
  refuses them, because what a shell creates would be left owned by a uid that
  no longer exists (see "Identities");
- no job control inside the shell: the command has no controlling terminal
  (the terminal belongs to `master`'s session), so Ctrl-Z is ignored and
  `jobs`/`fg` do nothing.

Differences from sudo, on purpose:

- no password and no credential cache: the gate is the socket (only `master`
  can connect), so `-v`/`-k`/`-K` are no-ops kept for script compatibility;
- the target is never root: `-u root` is refused, and `-u` takes only the
  middle identities the admin created;
- `updo` is not installed as `sudo`: a script that calls `sudo` should fail
  loudly, not get updo's rights by surprise.

## What bounds `updo`

Three locks, all set by the admin once, all enforced by the kernel. None
depends on what command `master` sends.

| lock | mechanism | effect |
|---|---|---|
| **identity** | system user `updo`, its own group, plus only the groups that were deliberately granted | ordinary DAC: updo reaches what those groups reach, nothing more |
| **filesystem** | the session runs in a systemd service with `ProtectSystem=strict`, `ProtectHome=read-only`, `PrivateTmp=yes`, and a `ReadWritePaths=` list | everything is read-only except the listed paths, **even if** DAC would allow a write |
| **no way up** | `NoNewPrivileges=yes`, `RestrictSUIDSGID=yes`, empty `CapabilityBoundingSet=` (or one named capability via `AmbientCapabilities=`) | `sudo`, `su`, `pkexec` and every setuid binary lose their power inside; no capability can be regained |

The filesystem lock is what keeps rule "never feed root" honest: paths that
root later executes (`/etc/sudoers*`, `/etc/systemd`, `/etc/tmpfiles.d`,
`/etc/udev`, `/etc/pam.d`, `/etc/polkit-1`, `/etc/ld.so.preload`, cron) must
never appear in `ReadWritePaths=`. The admin script refuses them.

The accepted trade-off, as with `dsh`: any process `master` runs can call
`updo`. That is fine because updo's power is small, written down in one
unit file, and reviewed.

## How it is wired (native pieces only, no polkit, no ssh)

```
updo CMD  (client, as master)
   │  connect(); one sendmsg: the request + its own fds 0, 1, 2 (SCM_RIGHTS)
   ▼
/run/updo/IDENT.sock   root:master 0660   ── only master can connect (kernel DAC)
   │  updo-IDENT.socket, Accept=yes: one service instance per call
   ▼
updo-IDENT@.service   User=updo-IDENT (or DynamicUser) + the three locks
   ExecStart=/usr/local/libexec/updod --allow-uid 1001 --name IDENT
   │  SO_PEERCRED: caller uid must be 1001, checked before reading anything
   │  fork: setsid, dup2 the caller's fds onto 0/1/2, chdir, clean env, exec
   ▼
CMD, as the identity, on master's own stdin/stdout/stderr
   │  exit status back over the socket; signal bytes forward the other way
   ▼
updod exits → systemd kills whatever is left in the instance's cgroup
```

The protocol (`tools/updo/updo-proto.h`) is one request and one reply byte;
the kernel does the rest:

- **who may call**: the socket's mode (only `master` can `connect`), then
  `SO_PEERCRED`, the kernel's record of the caller's uid. No keys, no crypto:
  relaysh needs both only because Android forces TCP loopback, where anyone
  can connect.
- **the data path is not a path**: `SCM_RIGHTS` passes the caller's file
  descriptors themselves. Nothing is relayed or re-encoded, so there is
  nothing to get wrong about binary data, buffering, stderr or window size,
  and no pty to allocate.
- **what the command is**: an argv, executed with `execvpe`, no shell in
  between unless asked for (`-c`, `-s`, `-i`).
- **cleanup**: the per-call service's cgroup, so a killed client leaves no
  orphan.

Also needed, checked by the admin script: `dev.tty.legacy_tiocsti = 0` (the
default since Linux 6.2, and so here). The command holds `master`'s terminal;
with legacy `TIOCSTI` it could type into `master`'s shell after it exits.

Rejected:

- `ssh` (`sshd -i` behind the socket, the first prototype): a large program
  whose behaviour we would depend on in detail (pty allocation, environment
  handling, login records, config defaults), which changes between OpenSSH
  releases. It also failed here: a non-root `sshd` cannot `chown` the pty or
  write login records, so interactive sessions were cut off.
- a setuid-to-identity helper: inherits `master`'s environment, fds and
  rlimits into a process with other rights.
- polkit / `run0`: a rules engine outside the base system; `run0` targets root.

## Prototype (as master, no admin)

`tools/updo/build.sh` builds `out/updo` and `out/updod`;
`tools/updo/dev-backend.sh start` runs `updod` from runtime user units
(`$XDG_RUNTIME_DIR`, gone at logout) with the same sandbox the real units
will have, and prints the `UPDO_RUNDIR` to use. A user manager cannot switch
users, so both ends are `master`: this tests the protocol, the client and the
sandbox, not the separate uid. Results, 2026-09-23:

| check | result |
|---|---|
| `updo sh -c 'exit 7'` / killed by `SIGTERM` / missing command | 7 / 143 / 127 |
| quoting | `updo touch 'a b' "it's" '$HOME'` makes exactly those three files |
| stdin, stderr | pass through, separately |
| 30 MB through a pipe | byte-exact, 0.12 s (the fd is passed, nothing copied) |
| latency | ≈ 55 ms per call (the ssh prototype: ≈ 100 ms) |
| environment | `FOO=leak` not passed; `LC_*` passed; `--preserve-env=FOO` passes it; `HOME`, `PATH`, `USER` are always the identity's |
| cwd | kept when the identity can enter it, else its home with a warning; `-D` fails hard |
| `-c`, `-f`, `-p`, `-s CMD`, `-i CMD`, `-l`, `-l CMD` | as documented |
| bare `updo` on a terminal | shell with prompt `updo> `; `tty`, `stty size` show the caller's terminal; `exit 3` → status 3 |
| Ctrl-C | at the prompt: line cancelled, shell alive; during `updo sleep 30`: status 130 |
| full-screen (`less`) | works |
| client `kill -9` during a call | no orphan (cgroup) |
| per-call identity (`--ephemeral`) | commands run; bare `updo` and piped shells refused |
| `-e` | editor runs as the caller; write-back keeps inode and mode; unchanged file not written; a failed write keeps the edit and says where |
| sandbox | `/etc`, `$HOME` read-only; the `ReadWritePaths=` dir writable; `NoNewPrivs: 1`, `CapEff: 0` |
| `-u root` | refused |

Earlier findings that still hold: `ProtectSystem=strict` alone left `/home`
writable, `ProtectHome=read-only` is also required; a plain
`systemd-socket-activate` (no cgroup) leaves orphans, a socket unit does not.

Not yet verified: a different uid on the far end (needs the system user),
`DynamicUser=` with `updod`, `AmbientCapabilities=`.

## Identities: persistent per grant, or one per call

`-u IDENT` picks an identity. Two kinds, tested through the admin account with
transient units on 2026-09-23:

**Per call: `DynamicUser=yes`.** systemd allocates a fresh uid for each
instance and releases it afterwards, with no `useradd`; the name resolves
through `nss-systemd` (`passwd: files systemd` here). Two runs got uid 65395
and 62315. It also turns on `ProtectSystem=strict`, `ProtectHome=read-only`,
`PrivateTmp`, `NoNewPrivileges` and `RestrictSUIDSGID` by itself. But a file
it writes outside systemd-managed directories keeps a dead owner:

| step | result |
|---|---|
| run 1 (uid 62932) `touch /run/dyntest/f` | `f` owned by 62932 |
| after run 1 | uid 62932 no longer exists |
| run 2 (uid 62416) appends to `f` | **denied** |

Nobody but root can fix that file later, and systemd may hand the same uid
to another service, which would then own it. `StateDirectory=` and
`RuntimeDirectory=` avoid this (systemd re-chowns them on each start) but live
only under `/var/lib` and `/run`. So per-call identities fit calls that
**leave nothing behind**: reads, checks, one-off jobs, and they refuse shells.
The default identity, `updo` with no `-u`, must open a shell, so it is a
**static** user with no write grants beyond its own home; per-call
identities are opt-in (`updod --ephemeral`).

**Per grant: a static user `updo-<name>`.** Created once with `useradd
--system`, with its own socket (`/run/updo/<name>.sock`), unit pair and
sandbox. Files it writes keep a stable owner, a later call can change them,
and a grant for one package is not a grant for another. This is what tier
`limited` uses: `javascript-common` gets `updo-lighttpd`, allowed to write
`/etc/lighttpd` and nothing else.


## Admin side (enable once)

`admin/native/enable-updo.sh` would install:

- `updod` to `/usr/local/libexec/updod` (built by `master` with
  `tools/updo/build.sh`, reviewed, copied root-owned; it only ever runs as an
  identity, never as root);
- `/run/updo/` owned by root (`tmpfiles.d`), which the client insists on;
- the default identity `updo`: `useradd --system`, `updo.socket` +
  `updo@.service` with the three locks and nothing writable beyond its home;
- a check that `dev.tty.legacy_tiocsti` is 0;
- the grant tool, `admin/native/updo-grant.sh NAME [--rw PATH]... [--group G]...
  [--cap CAP] [--ephemeral]`: creates `updo-NAME` (`useradd --system`, or
  `DynamicUser=yes` with `--ephemeral`), its socket `/run/updo/NAME.sock`
  (`root:master 0660`) and a `updo-NAME@.service` with the three locks and
  exactly those grants. It refuses the forbidden paths and root-equivalent
  groups, and each grant is reviewed on its own.

It never adds an updo identity to `sudo`, `disk`, `docker`, `lxd`, `shadow` or
any other root-equivalent group.

## Tier `limited`

A package whose only obstacle is a privileged step becomes `limited`. The
recipe names the delegation it needs, and the step runs through `updo`, not
root:

| today `never` | with updo |
|---|---|
| `javascript-common`: postinst `mkdir -p /etc/lighttpd/conf-enabled` | **limited**: delegation `ReadWritePaths=/etc/lighttpd`; the recipe runs `updo -u lighttpd mkdir -p /etc/lighttpd/conf-enabled`, then `dpkg --configure` |
| `screen`: `/run/screen`, group `utmp`, mode `0775` | **limited**: delegation `SupplementaryGroups=utmp` + a `/run/screen` path |
| `screen`: `/etc/tmpfiles.d`, unit link, `update-rc.d` | **never**: root-executed config; the admin may ship a reviewed static file once instead |
| services on ports < 1024 | no updo needed: `net.ipv4.ip_unprivileged_port_start` is an admin-once sysctl |
| PAM, setuid | **never**: blocked by `NoNewPrivileges` and the forbidden list, by design |
| 32-bit-only, proprietary self-updating | unchanged: not about privilege |

`recipes.sh` would check that `updo -l` lists the delegation a `limited`
recipe needs and name it when missing.

## Open questions

- Audit: every call is a journal entry of its `updo-IDENT@<n>.service` (caller
  pid and uid, cwd, argv, exit status). Enough?
- Ship `updod` as a `.deb` built from this repo, so the admin installs a
  package rather than a copied binary?
