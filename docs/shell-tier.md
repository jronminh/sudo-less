# `slsh`: a middle identity, used like `sudo` / `dsh`

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

`slsh CMD` does what `sudo CMD` would do for the things `master` legitimately
needs beyond userspace, as a system user `slsh` that can never become root.
Nothing else from Android (SELinux, adbd, pairing, `settings`) is copied.

## Usage: `sudo` with a different target

`slsh` takes `sudo`'s options wherever they make sense, so muscle memory and
scripts carry over (`sudo mkdir -p /etc/x` → `slsh mkdir -p /etc/x`), plus
`dsh`'s `-c`/`-f`/`-p`.

```sh
slsh CMD [ARG...]        # run CMD as slsh                       (sudo CMD, dsh CMD)
slsh -s [CMD]            # shell as slsh, or CMD through it      (sudo -s)
slsh -i [CMD]            # login shell as slsh                   (sudo -i)
slsh -e FILE...          # edit FILEs as slsh                    (sudo -e / sudoedit)
slsh -l [CMD]            # what slsh may do; with CMD: would it  (sudo -l)
slsh -D DIR CMD          # run in DIR                            (sudo -D)
slsh --preserve-env=VAR,... CMD   # pass extra variables         (sudo --preserve-env=)
slsh -u IDENT CMD        # another middle identity, if several exist (sudo -u)
slsh -c 'CMD LINE'       # run a shell command line              (dsh -c)
slsh -f FILE             # run the command read from FILE        (dsh -f)
slsh -p FILE CMD         # stream FILE to CMD's stdin            (dsh -p)
slsh -v | -k | -K        # accepted, do nothing: there is no password to cache
```

Behaviour a `sudo` user expects, kept:

- stdin, stdout, stderr and the exit status pass through; a pty is allocated
  when stdin and stdout are terminals, so Ctrl-C and full-screen programs work,
  and pipes stay binary-clean otherwise;
- the current directory is kept (sudo's default) when slsh can enter it,
  else slsh's home, with a warning;
- the environment is reset to an allowlist (`PATH`, `TERM`, `LANG`, `LC_*`),
  as sudo's `env_reset` does; `--preserve-env` adds to it;
- `-e` works like `sudoedit`: the file is copied out, edited by `$EDITOR`
  running as **master**, and written back as slsh, so the editor itself never
  runs with slsh's rights;
- arguments are quoted by the client, so `slsh touch 'a b'` makes one file.

Differences, on purpose:

- no password and no credential cache: the gate is the socket (only `master`
  can connect), so `-v`/`-k`/`-K` are no-ops kept for script compatibility;
- the target is never root: `-u root` is refused, and `-u` takes only the
  middle identities the admin created;
- `slsh` is not installed as `sudo`: a script that calls `sudo` should fail
  loudly, not get slsh's rights by surprise.

## What bounds `slsh`

Three locks, all set by the admin once, all enforced by the kernel. None
depends on what command `master` sends.

| lock | mechanism | effect |
|---|---|---|
| **identity** | system user `slsh`, its own group, plus only the groups that were deliberately granted | ordinary DAC: slsh reaches what those groups reach, nothing more |
| **filesystem** | the session runs in a systemd service with `ProtectSystem=strict`, `ProtectHome=read-only`, `PrivateTmp=yes`, and a `ReadWritePaths=` list | everything is read-only except the listed paths, **even if** DAC would allow a write |
| **no way up** | `NoNewPrivileges=yes`, `RestrictSUIDSGID=yes`, empty `CapabilityBoundingSet=` (or one named capability via `AmbientCapabilities=`) | `sudo`, `su`, `pkexec` and every setuid binary lose their power inside; no capability can be regained |

The filesystem lock is what keeps rule "never feed root" honest: paths that
root later executes (`/etc/sudoers*`, `/etc/systemd`, `/etc/tmpfiles.d`,
`/etc/udev`, `/etc/pam.d`, `/etc/polkit-1`, `/etc/ld.so.preload`, cron) must
never appear in `ReadWritePaths=`. The admin script refuses them.

The accepted trade-off, as with `dsh`: any process `master` runs can call
`slsh`. That is fine because slsh's power is small, written down in one
unit file, and reviewed.

## How it is wired (native pieces only, no polkit)

```
slsh CMD  (client, master)
   │  ssh over a unix socket: systemd-ssh-proxy, ProxyUseFdpass
   ▼
/run/slsh.sock   root:master 0660   ── only master can connect (kernel DAC)
   │  slsh.socket, Accept=yes: one service instance per call
   ▼
slsh@.service   User=slsh + the three locks above
   ExecStart=-/usr/sbin/sshd -i -f /etc/slsh/sshd_config
   │  sshd running as slsh, not root: it can only log in as slsh
   ▼
CMD, as slsh; when the connection closes, systemd kills the instance's cgroup
```

Why these parts:

- **systemd socket activation** gives a fresh, sandboxed process per call and
  cleans up by cgroup: a client killed without a pty leaves no orphan.
- **`sshd -i` as a non-root user** does the hard parts that a hand-written
  protocol would get wrong: stdin/stdout/stderr, exit status, pty, window
  size, signals. Running as `slsh` it cannot switch users, so it is not a root
  daemon. OpenSSH and `systemd-ssh-proxy` (systemd ≥ 256, the `unix/PATH` host
  syntax) are already installed here.
- **The socket mode** is the real gate. The ssh key (`master`'s, listed in a
  root-owned `/etc/slsh/authorized_keys`) is a second one.

Rejected: a setuid-to-`slsh` helper (inherits `master`'s environment, fds and
rlimits; needs compiling), polkit / `run0` (a rules engine outside the base
system; `run0` targets root), a custom protocol over `socat` (no pty, stderr
or exit status without reinventing ssh).

## Prototype (as master, no admin)

Runtime user units in `/run/user/1001/systemd/user` (non-persistent), sshd
with a throwaway host key, same uid on both ends:

| check | result |
|---|---|
| `ssh slsh 'id; exit 7'` | runs, exit status 7 returned |
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

## Admin side (enable once)

`admin/native/enable-slsh.sh` would install:

- `useradd --system --home-dir /var/lib/slsh --shell /bin/sh slsh`;
- `/etc/slsh/sshd_config` (no passwords, no forwarding, `AcceptEnv` for the
  allowlist), a host key owned by slsh, and a root-owned `authorized_keys`
  holding the public key that `master` generated;
- `slsh.socket` and `slsh@.service` with the three locks;
- one drop-in per delegation, `/etc/systemd/system/slsh@.service.d/<name>.conf`
  (`ReadWritePaths=`, `SupplementaryGroups=`, or one `AmbientCapabilities=`),
  each reviewed on its own and checked against the forbidden-path list.

It never adds slsh to `sudo`, `disk`, `docker`, `lxd`, `shadow` or any other
root-equivalent group.

## Tier `limited`

A package whose only obstacle is a privileged step becomes `limited`. The
recipe names the delegation it needs, and the step runs through `slsh`, not
root:

| today `never` | with slsh |
|---|---|
| `javascript-common`: postinst `mkdir -p /etc/lighttpd/conf-enabled` | **limited**: delegation `ReadWritePaths=/etc/lighttpd`; the recipe runs `slsh mkdir -p /etc/lighttpd/conf-enabled`, then `dpkg --configure` |
| `screen`: `/run/screen`, group `utmp`, mode `0775` | **limited**: delegation `SupplementaryGroups=utmp` + a `/run/screen` path |
| `screen`: `/etc/tmpfiles.d`, unit link, `update-rc.d` | **never**: root-executed config; the admin may ship a reviewed static file once instead |
| services on ports < 1024 | no slsh needed: `net.ipv4.ip_unprivileged_port_start` is an admin-once sysctl |
| PAM, setuid | **never**: blocked by `NoNewPrivileges` and the forbidden list, by design |
| 32-bit-only, proprietary self-updating | unchanged: not about privilege |

`recipes.sh` would check that `slsh -l` lists the delegation a `limited`
recipe needs and name it when missing.

## Open questions

- Name: `slsh` (sudo-less shell) vs something shorter.
- `-e` needs the client to copy files both ways; confirm it keeps owner and mode on write-back.
- One `slsh` for everything, or one identity per delegation (`slsh-lighttpd`,
  …) so that a grant for one package is not a grant for all?
- Audit: every call is a journal entry (`slsh@<n>.service`, peer pid/uid). Enough?
