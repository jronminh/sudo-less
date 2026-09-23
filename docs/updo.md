# `updo`: userspace do

`updo` ("userspace do") is `sudo` for a bounded middle identity instead of
the super user: same usage, never root.

Status: **design.** The transport was prototyped as `master` on 2026-09-23 (a
runtime user unit, same uid on both ends, see "Prototype"). The admin side
(a system user, system units) is not installed.

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
| `dsh` | the command the user types | `updo` client (wraps `ssh`) | `tools/updo`, userspace |
| wireless debugging + pairing | who may reach the daemon | unix socket `root:master 0660` + `master`'s ssh key | admin, once |
| `adbd` | accepts a call, starts the session | `updo-<id>.socket` (`Accept=yes`) + `sshd -i` running as the identity | admin, once |
| uid 2000 `shell` | the bounded identity | `updo-<id>` system users (persistent), or a `DynamicUser` (per call) | admin, once per identity |
| `shell`'s groups (`readproc`, `uhid`, `log`, …) | what the identity can reach | `SupplementaryGroups=`, group-owned setgid dirs | admin, per grant |
| SELinux `shell` domain | a limit the identity cannot lift | systemd sandbox: `ProtectSystem=strict`, `ProtectHome`, `ReadWritePaths=`, `NoNewPrivileges`, no caps | admin, per identity |
| platform services checking uid 2000 | the system decides, not the caller | the kernel (DAC, mount namespace, `no_new_privs`) | kernel |
| `dsh status` | show the state | `updo -l` | client |

So making `updo` real means building four things: the client (`tools/updo`),
the enablement (`admin/native/enable-updo.sh`), a grant tool that creates one
identity with its drop-in and refuses forbidden paths, and the recipe side
(tier `limited`).

## Usage: `sudo` with a different target

`updo` takes `sudo`'s options wherever they make sense, so muscle memory and
scripts carry over (`sudo mkdir -p /etc/x` → `updo mkdir -p /etc/x`), plus
`dsh`'s `-c`/`-f`/`-p`.

```sh
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

- stdin, stdout, stderr and the exit status pass through; a pty is allocated
  when stdin and stdout are terminals, so Ctrl-C and full-screen programs work,
  and pipes stay binary-clean otherwise;
- the current directory is kept (sudo's default) when updo can enter it,
  else updo's home, with a warning;
- the environment is reset to an allowlist (`PATH`, `TERM`, `LANG`, `LC_*`),
  as sudo's `env_reset` does; `--preserve-env` adds to it;
- `-e` works like `sudoedit`: the file is copied out, edited by `$EDITOR`
  running as **master**, and written back as updo, so the editor itself never
  runs with updo's rights;
- arguments are quoted by the client, so `updo touch 'a b'` makes one file.

Differences, on purpose:

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

## How it is wired (native pieces only, no polkit)

```
updo CMD  (client, master)
   │  ssh over a unix socket: systemd-ssh-proxy, ProxyUseFdpass
   ▼
/run/updo.sock   root:master 0660   ── only master can connect (kernel DAC)
   │  updo.socket, Accept=yes: one service instance per call
   ▼
updo@.service   User=updo + the three locks above
   ExecStart=-/usr/sbin/sshd -i -f /etc/updo/sshd_config
   │  sshd running as updo, not root: it can only log in as updo
   ▼
CMD, as updo; when the connection closes, systemd kills the instance's cgroup
```

Why these parts:

- **systemd socket activation** gives a fresh, sandboxed process per call and
  cleans up by cgroup: a client killed without a pty leaves no orphan.
- **`sshd -i` as a non-root user** does the hard parts that a hand-written
  protocol would get wrong: stdin/stdout/stderr, exit status, pty, window
  size, signals. Running as `updo` it cannot switch users, so it is not a root
  daemon. OpenSSH and `systemd-ssh-proxy` (systemd ≥ 256, the `unix/PATH` host
  syntax) are already installed here.
- **The socket mode** is the real gate. The ssh key (`master`'s, listed in a
  root-owned `/etc/updo/authorized_keys`) is a second one.

Rejected: a setuid-to-`updo` helper (inherits `master`'s environment, fds and
rlimits; needs compiling), polkit / `run0` (a rules engine outside the base
system; `run0` targets root), a custom protocol over `socat` (no pty, stderr
or exit status without reinventing ssh).

## Prototype (as master, no admin)

Runtime user units in `/run/user/1001/systemd/user` (non-persistent), sshd
with a throwaway host key, same uid on both ends. The `updo` client does not
exist yet, so the checks call the underlying `ssh` directly; `updo CMD` will
wrap exactly that call:

| check | result |
|---|---|
| `ssh updo 'id; exit 7'` | runs, exit status 7 returned |
| stdin / stderr | `echo hi \| … cat` → `hi`; stderr arrives separately |
| pty (`-tt`) | `/dev/pts/N`, `TERM` passed |
| environment | client's `FOO=leak` not seen; `PATH` is sshd's default |
| 3 MB through stdin | byte-exact (`wc -c`) |
| latency per call | ≈ 100 ms |
| client killed, no pty | under `systemd-socket-activate`: remote `sleep` **orphaned**; under a socket unit: **no orphan** (cgroup) |
| sandbox | `/` read-only, `ReadWritePaths=` dir writable, `NoNewPrivs: 1` |
| gotcha | `ProtectSystem=strict` alone left `/home` writable in this setup; `ProtectHome=read-only` closed it. Both are required. |

Not yet verified: a different uid on the far end (needs the system user),
`AmbientCapabilities=`, and the client wrapper's quoting and cwd handling.

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
**leave nothing behind**: reads, checks, one-off jobs. That is the default
identity, `updo` with no `-u`.

**Per grant: a static user `updo-<name>`.** Created once with `useradd
--system`, with its own socket (`/run/updo/<name>.sock`), unit pair and
sandbox. Files it writes keep a stable owner, a later call can change them,
and a grant for one package is not a grant for another. This is what tier
`limited` uses: `javascript-common` gets `updo-lighttpd`, allowed to write
`/etc/lighttpd` and nothing else.

Not yet verified: `sshd -i` under a `DynamicUser` (the user resolves, so it
should work).

## Admin side (enable once)

`admin/native/enable-updo.sh` would install:

- the default identity: `updo.socket` + `updo@.service` with
  `DynamicUser=yes`, nothing writable beyond its runtime directory;
- `/etc/updo/sshd_config` (no passwords, no forwarding, `AcceptEnv` for the
  allowlist), a host key readable by group `updo` (every identity's primary or
  supplementary group), and a root-owned `authorized_keys`
  holding the public key that `master` generated;
- the grant tool, `admin/native/updo-grant.sh NAME [--rw PATH]... [--group G]...
  [--cap CAP]`: creates `updo-NAME` (`useradd --system`), its socket
  `/run/updo/NAME.sock` (`root:master 0660`) and a `updo-NAME@.service` with the
  three locks and exactly those grants. It refuses the forbidden paths and
  root-equivalent groups, and each grant is reviewed on its own.

It never adds an updo identity to `sudo`, `disk`, `docker`, `lxd`, `shadow` or any other
root-equivalent group.

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

- `-e` needs the client to copy files both ways; confirm it keeps owner and mode on write-back.
- Audit: every call is a journal entry (`updo@<n>.service`, peer pid/uid). Enough?
