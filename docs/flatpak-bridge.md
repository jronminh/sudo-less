# Bridging Flatpak apps to userspace daemons

`recipes/` and `tools/prefix-run.sh` answer "how do I run this **binary**
without root." This answers a different question that comes up once you
start running real background daemons in `~/.local` instead of at the
system level: **how does a sandboxed Flatpak app reach one.**

## The problem

Some Flatpak apps are pure clients of a system daemon: they don't do
anything privileged themselves, they just talk over a Unix socket to a
daemon that's supposed to be running at the system level — printing,
Bluetooth, a VPN mesh client, anything with a `system.slice` daemon and a
thin GUI. The client's Flatpak manifest grants it read (or read-write)
access to exactly one fixed host path, e.g.:

```
$ flatpak info --show-permissions dev.deedles.Trayscale
[Context]
filesystems=/run/tailscale:ro;
```

Two things make this a **different** class of problem than everything in
[`standard.md`](standard.md):

1. **The daemon isn't part of the Flatpak.** It can't be — a daemon that
   needs `CAP_NET_ADMIN`, a TUN device, or general host privilege is exactly
   what Flatpak's sandbox is designed to deny. So the daemon is expected to
   already be running on the *host*, outside any sandbox, normally started
   by `systemd` as root. That's the piece `sudo-less` deliberately doesn't
   have.
2. **The fixed path usually has no override.** Flatpak's `--filesystem`
   permission only ever mounts a host path at the *identical* absolute path
   inside the sandbox — it cannot remap. That's fine when a real daemon
   creates the path (root can always write to `/run/whatever`). It stops
   being fine the moment the daemon has to run unprivileged: your userspace
   equivalent's socket has to live somewhere *you* can write, like
   `$XDG_RUNTIME_DIR`, and that is almost never the path the Flatpak's
   manifest — or, worse, the app's *compiled-in default* — expects.

**Always check both halves before reaching for the bridge below:**

- `flatpak info --show-permissions <app-id>` — the exact host path(s) it's
  allowed to see.
- The app's own source (or its client library) for a real override — an
  env var, a `--socket`-style flag, a preferences field. If one exists, use
  it; you need none of this. (Concretely: `tailscale.com/client/local`'s
  `Client.Socket` field is a real, settable override — but only the code
  that *constructs* the client can set it, and third-party GUIs frequently
  never wire it to anything. Verify per app; don't assume either way.)

If there's truly no override, the fixed path is the only way in, and you
have no root to create it there — that's when this doc applies.

## The fix tiers

| tier | what it takes | durability | root used |
|---|---|---|---|
| **A. One-time root** | someone with `sudo` runs `install -d -o "$USER" -g "$USER" /run/whatever` once, plus a `systemd-tmpfiles.d` drop-in so it's recreated every boot | permanent | one brief, auditable action; never again |
| **B. Namespace bridge** (`flatpak/bridge.sh` + `flatpak/install-launcher.sh`) | an unprivileged `bwrap` wrapper around `flatpak run` that substitutes the fixed path for your userspace one *before* Flatpak's own sandbox is built | `bridge.sh` alone is per-invocation; `install-launcher.sh` makes it persistent once, by overriding the app's `.desktop` `Exec=` | none, ever |
| **C. Patch + rebuild the app** | add the missing override yourself, build the app in the userspace prefix instead of using the Flatpak build | permanent, no root | real build effort (the app's own toolchain, e.g. GTK4/libadwaita for a Go+gotk4 app) |

A is the cheapest fix *if* root is reachable at all, even once — it's a
single directory creation, not a service install, and nothing about it
keeps root "standing" afterward. B is what to reach for when root is
genuinely unavailable. C is worth it only for an app you'll keep using
long-term and whose build is tractable.

This doc and `flatpak/bridge.sh` are tier B.

## `flatpak/bridge.sh`

```sh
flatpak/bridge.sh APPID FAKE=REAL [FAKE=REAL...] [-- ARGS...]

# Example: Trayscale expects a system tailscaled it doesn't have; a
# userspace tailscaled is running with --socket=$XDG_RUNTIME_DIR/tailscale/tailscaled.sock
flatpak/bridge.sh dev.deedles.Trayscale \
  /run/tailscale=/run/user/"$(id -u)"/tailscale
```

### Mechanism

An unprivileged mount namespace built the same way `prefix-run.sh`'s
`overlay` mode is (`--ro-bind / /` as the base — see
[`paths.md`](paths.md)), with `flatpak run` executed *inside* it. Flatpak's
own inner sandbox is built from whatever view we hand it, so its
`filesystems=/run/whatever:ro`-style permission picks up the substitute
transparently — no Flatpak-side change at all.

Two things had to be worked out that a naive `--ro-bind / / --bind REAL
FAKE` doesn't handle, both found by testing against a real app, not
assumed:

- **Creating a mountpoint under a read-only tree fails.** `--ro-bind / /`
  makes `/run` read-only, so bwrap can't `mkdir` a fresh `/run/tailscale`
  under it (`Read-only file system`) — regardless of *which* bwrap
  primitive targets it. `prefix-run.sh` sidesteps this for `/usr`/`/etc`
  with a real overlayfs (`--overlay-src`/`--tmp-overlay`); that specific
  mechanism failed here for `/run` (`Invalid argument` — kernel/config
  dependent, not universal). The fallback that needs nothing but bind
  mounts: `--tmpfs` the fake path's *parent*, then re-`--bind` every entry
  that already existed there, so the sandbox's view is identical except for
  the one path being substituted. This is what the script does, scoped
  per-mapping.
- **Flatpak itself needs the normal writable locations.** A bare
  `--ro-bind / /` breaks Flatpak's own temp/state writes (`open(O_TMPFILE):
  Read-only file system`) because `/tmp` and `$HOME` are read-only too. The
  script binds both writable, matching `prefix-run.sh`'s own base (see
  `build_cmd()` in `tools/prefix-run.sh`) — this isn't specific to the
  bridge, it's a prerequisite for running *anything* GUI-shaped through a
  `--ro-bind / /` sandbox.

### Verifying a bridge actually works

Don't trust a clean launch alone — `flatpak run` on an already-running
single-instance app (GTK `GApplication`s are, by default) just D-Bus
activates the existing process and tells you nothing about the new
sandbox. Kill every existing instance of the app first, then check the
*content* of the app's own log, not just its exit code:

- **Before the fix**: `dial unix .../whatever.sock: connect: no such file
  or directory` — no daemon reachable at all.
- **After the fix**: real errors *from* the daemon (a proper HTTP status,
  an application-level message like `"not connected to the tailnet"`) —
  proof the socket connected and the daemon answered, even if some other,
  unrelated precondition (auth, a missing directory) isn't met yet. That
  distinction — connection-refused vs. an answer from the other end — is
  the actual proof, not "the app didn't crash."

## `flatpak/install-launcher.sh` — making the bridge persistent

`bridge.sh` only fixes the one launch you invoke it for. Nothing else
about how you'd normally start the app — the icon, the taskbar entry,
the app switcher — goes through it, so the very next launch reverts to
the broken, unbridged path. `install-launcher.sh` closes that gap once:

```sh
flatpak/install-launcher.sh APPID FAKE=REAL [FAKE=REAL...]

flatpak/install-launcher.sh dev.deedles.Trayscale \
  /run/tailscale=/run/user/"$(id -u)"/tailscale
```

It finds the app's Flatpak-exported `.desktop` file (owned by Flatpak,
regenerated on every update — never edit it in place), copies every field
except `Exec=`, and writes the result to
`~/.local/share/applications/<APPID>.desktop`. That shadows the
Flatpak-managed entry for the same desktop-file ID, because `$XDG_DATA_HOME`
(`~/.local/share`) is searched before Flatpak's own exports dir is added to
`$XDG_DATA_DIRS` — the standard, supported way to override a Flatpak app's
launcher command without touching Flatpak's own files. Run it once per app;
every subsequent icon click, taskbar launch, or app-switcher entry goes
through the bridge automatically from then on.

Verify the same way as the bridge itself (kill every running instance,
check for real daemon responses instead of `dial unix ... no such file`)
but launch it the way a person would: `gio launch
~/.local/share/applications/<APPID>.desktop`, not `bridge.sh` directly —
that's what actually proves the persistent path works, not just the
one-off invocation.

## Recording a fix: `flatpak/fixes/<app-id>.fix`

One file per bridged app, plain `key value` lines, same spirit as
`recipes/<pkg>.recipe` (see [`standard.md`](standard.md)) but for this
different problem:

| key | required | meaning |
|---|---|---|
| `app` | yes | the Flatpak application ID (must match the filename) |
| `expects` | yes | the fixed host path the app/manifest requires, and why it has no override (cite the source checked) |
| `daemon` | yes | how the userspace-side daemon is started (command, socket path) |
| `bridge` | yes | the exact `FAKE=REAL` mapping(s) passed to `bridge.sh` |
| `launcher` | no | the `install-launcher.sh` invocation, if a persistent launcher override was installed |
| `verify` | yes | the log evidence that proves the connection (not just "it launched") |
| `status` | yes | `verified` (run for real, log evidence recorded) or `proposed` (untested) |
| `note` | no | free text, repeatable — caveats, unrelated gaps found along the way |

See `flatpak/fixes/dev.deedles.Trayscale.fix` for a worked, verified
example.
