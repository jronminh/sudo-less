# A middle identity: our own "shell" uid

Status: **design, not implemented.** Nothing here is installed; the
mechanisms named are verified to exist on this host (systemd 261, util-linux,
coreutils), and the design has not been run yet.

## Why

Android has three layers: the app (Termux), `shell` (uid 2000, what `adb
shell` gets), and root. `shell` has **no effective capabilities**; its power is
a fixed list (groups such as `readproc`/`uhid`, verbs such as `settings`,
`pm`), and the system checks that list, not `shell` itself
(`docs/system-resources.md` §1.4). Termux uses it once, to switch off the
phantom-process killer, and then runs as the app again.

This repo has two layers, `master` and root (via the admin account). What is
out of reach for `master` today lands in tier `never` (`docs/standard.md`).
A middle identity, enabled once by the admin and usable by `master` directly,
would turn part of `never` into **`limited`**: the package works, and the
host integration it needs is done by a reviewed, narrow verb.

## The trap

A middle uid that runs *arbitrary* commands for `master` is just `master`
with more groups: every process `master` runs gets those rights. (`dsh` on the
phone is exactly that: any process in Termux can call it.) So the design is
bound by three rules:

1. **Verbs, not commands.** The middle identity executes a fixed table of
   verbs with validated arguments. There is no "run this".
2. **Never feed root.** A verb never writes anything that root later reads as
   code or policy: `/etc/tmpfiles.d`, systemd units, `/etc/sudoers*`, polkit
   rules, cron, udev rules, PAM, `ld.so.preload`, anything setuid. Writing
   those *is* root.
3. **No path up.** The middle uid has no sudo rights, no membership in
   root-equivalent groups (`sudo`, `disk`, `docker`, `lxd`, `shadow`, …), and
   owns nothing that root executes.

With those, it respects the repo's rule that admin steps enable userspace and
never run `master`'s software: the middle identity runs *verbs*, not
`master`'s programs.

## Native building blocks (no polkit)

Every piece below is in the kernel or the base system (priority
`required`/`important` on Debian). polkit and `run0` (which asks polkit) are
not used.

| need | native mechanism | enforced by |
|---|---|---|
| the identity | a system user `slsh` + group, created once (`useradd --system`, shadow) | kernel uid/gid |
| who may call it | a unix socket owned `root:master`, mode `0660` | kernel DAC on `connect()` |
| running a verb | systemd socket activation, `Accept=yes`, service `User=slsh` | systemd, one process per call |
| the allowlist of paths | `ProtectSystem=strict` + `ReadWritePaths=` (exact list) | mount namespace set up by systemd |
| the allowlist of powers | `CapabilityBoundingSet=` (empty, or one named cap), `NoNewPrivileges=yes` | kernel capabilities |
| further confinement | `SystemCallFilter=@system-service`, `PrivateDevices=`, `RestrictAddressFamilies=` | seccomp |
| delegating a path | group ownership + setgid directory (`chgrp slsh`, `chmod 2775`), not ACLs | kernel DAC |
| delegating a device | group on the node via a udev rule installed once by the admin | udev + DAC |

This mirrors Android closely: the socket is `adbd`, `User=slsh` is uid 2000,
and systemd's sandbox options take the place of the SELinux `shell` domain
(what the identity may touch is declared by someone else, not by the code
running as it). ACLs (`setfacl`) would also work but the `acl` package is
`optional` on Debian, so plain groups come first.

Rejected:

- **setuid-to-`slsh` helper.** Native (the kernel supports setuid to any uid,
  and `AT_SECURE` strips `LD_PRELOAD`), but the helper inherits `master`'s
  environment, fds, rlimits and cwd, and needs compiling (scripts cannot be
  setuid). A socket-activated service starts from a clean slate instead.
- **polkit actions / `run0`.** They work (`docs/polkit.md`), but decide per
  action in a JavaScript rules engine outside the base system, and `run0`
  runs as root.
- **Just granting `master` the group.** Right when the power is harmless as a
  standing right (a device node, a data directory). Wrong when the verb must
  validate its input: a group grant cannot say "only this file name".

## Shape

```
master ──connect──▶ /run/slsh.sock (root:master 0660)
                         │ systemd, Accept=yes
                         ▼
               slsh@.service  User=slsh  NoNewPrivileges=yes
               ProtectSystem=strict  ReadWritePaths=<delegated paths>
               CapabilityBoundingSet=  SystemCallFilter=@system-service
                         │ reads one line: VERB ARG...
                         ▼
               /usr/local/libexec/slsh/<verb>   (root-owned, admin-installed)
```

Verbs are root-owned files installed by the admin, so neither `master` nor
`slsh` can change what a verb does. The dispatcher refuses unknown verbs and
arguments that fail the verb's own validation. Each verb's delegated paths
appear in the unit's `ReadWritePaths=`, so a buggy verb still cannot write
elsewhere.

The recipe side: a recipe in tier `limited` lists the verbs it needs;
`recipes.sh` checks that the socket answers and the verbs exist, and the
verdict names the missing verb if not.

## Against today's `never` list

| `never` reason (`docs/standard.md`) | with `slsh` |
|---|---|
| root-only postinst writing **data** (`javascript-common`: `mkdir /etc/lighttpd/conf-enabled`) | **limited**: a verb creates the directory in a delegated tree |
| root-only postinst creating runtime dirs (`screen`: `/run/screen`, group `utmp`, `0775`) | **limited**: a verb creates it, with a fixed owner and mode |
| postinst writing **root-executed config** (`screen`: `/etc/tmpfiles.d`, a unit link, `update-rc.d`) | **never** by rule 2; the admin can ship a reviewed static equivalent once instead |
| services: ports < 1024 | not needed: `net.ipv4.ip_unprivileged_port_start` is an admin-once sysctl |
| services: system D-Bus names, system units | **limited** at best, via a verb that starts a pre-reviewed unit; never installing units |
| container-in-container | partly: a larger subuid range is admin-once, not a verb |
| PAM / setuid | **never**: minting setuid-root or PAM modules is root by definition |
| 32-bit-only, proprietary self-updating | unchanged; not a privilege problem |

So `never` shrinks to "needs root by definition" plus the non-privilege
reasons, and gains a precise meaning.

## Open questions before a prototype

- Verb language: POSIX `sh` with `case` dispatch keeps it base-only; each verb
  then needs careful argument validation (no `..`, fixed patterns).
- Audit: systemd's journal records every instance (`slsh@<n>.service`) with
  the peer; is that enough, or should verbs log explicitly?
- Consent: Android also asks for pairing before `shell` is reachable. Here the
  socket mode is the only gate; a verb-level "ask the user" would need a
  desktop prompt, which brings polkit back.
- Where the admin side lives: `admin/native/` (user, socket, service,
  dispatcher, base verbs), with per-package verbs reviewed individually.

A prototype needs the admin account (system user, units under
`/etc/systemd/system`), so it waits for explicit approval.
