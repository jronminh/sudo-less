# Design

The whole of sudo-less on one page: what it is for, how its parts fit, and
which parts exist today. The other documents go deeper into one part each.

## Goal

A user created on a **standard Debian install, with no `sudo`**, installs and
uses `.deb` packages from the supported sections into `~/.local`. The admin
does a few one-time steps and nothing per package. The user types only
`apt-get`; everything else happens by itself.

Measured by three criteria (see the README): a new account works at once,
coverage per Debian section from a random sample, and a clear boundary of
what is the admin's.

## The idea: ride apt's own lifecycle

apt already calls out at every step of its work, through hooks declared in
`apt.conf.d` ([apt.conf(5)](https://manpages.debian.org/apt.conf)).
sudo-less hangs one pipeline on those hooks instead of asking the user to run
tools around apt. Every package goes through the same four stages:

```
apt-get update  ──▶ [1 sync]       APT::Update::Post-Invoke-Success
apt-get install ──▶ [2 classify]   DPkg::Pre-Install-Pkgs   (reads the .deb list)
                    [3 install]    dpkg, with shims on DPkg::Path only
                    [4 integrate]  DPkg::Post-Invoke
```

| stage | what it does | why here |
|---|---|---|
| **1. sync** | re-seed the prefix's view of the system's packages from the host's dpkg database, and keep them held | when the admin upgrades the system, the prefix follows at the next `update`; a stale seed is what makes apt report "held broken packages" |
| **2. classify** | for each incoming `.deb`: decide its **scope** (in scope, the admin's, or `never`, from its section and signals such as `adduser` or a service) and refuse what is out of scope with the reason; decide its **mechanism** (none, environment, overlay); find **unsafe maintainer scripts** (a root-only command with no shim) and stop before dpkg runs; record every decision | the `.deb` files are on disk and nothing is installed yet, so a wrong package costs nothing and the prefix never wedges |
| **3. install** | dpkg runs in the prefix view ([`view.md`](view.md)): the prefix overlaid on `/usr`, `/etc`, `/var` and `/opt`, so maintainer scripts write to `/etc` and `/var` as on Debian and it all lands in the prefix. Shims for root-only helpers (`py3compile`, service helpers) sit in a directory that is on `DPkg::Path` only | maintainer scripts see the prefix and the shims; the user's shell never sees the shims |
| **4. integrate** | for the packages this run changed: write or remove overlay wrappers, refresh launchers and icons, run each ecosystem's integration, and check for half-configured packages (repair, or say exactly what to do) | the files are in place; the user's next command just works |

The hooks are small bash scripts in `$PREFIX/share/sudo-less/hooks/`, each
dispatching to ordered parts (`run-parts` style), so adding a behaviour means
adding a file, not editing a script.

## Parts

| part | role | detail |
|---|---|---|
| **apt/dpkg port** | the real Debian apt and dpkg, following upstream, patched only as far as working without root in a prefix needs (a fork of Termux's patches) | [`apt-dpkg-port.md`](apt-dpkg-port.md) |
| **pipeline** | the four stages above | this page |
| **classifier** | one library that reads a `.deb` and returns scope, mechanism and unsafe scripts; used by stage 2, by `sudo-less explain` and by the survey tools, so the same input always gets the same verdict | `tools/prefix-check.sh` (stage 2) and `scripts/catalog/check-package.sh` (by hand), to become one |
| **views** | where dpkg runs, and the programs that look for their files at `/usr`, `/etc`, `/opt` | [`view.md`](view.md) |
| **problem map** | every obstacle, by when it bites (install, run) and who can fix it (sudo-less, the admin once, nobody) | [`problems.md`](problems.md) |
| **ecosystems** | what each language needs; per-language parts plug into the stages when one is needed (none today) | [`ecosystems.md`](ecosystems.md) |
| **state** | `$PREFIX/var/lib/sudo-less/`: per package, its scope, mechanism and the wrappers it got, so everything can be explained and removed cleanly | — |
| **admin step** | one-time enablement: unprivileged user namespaces, `~/.local/bin` on `PATH` (`admin/enable-userspace.sh`) | [`../admin/`](../admin/) |

What the user sees:

```sh
apt-get install PKG      # installs, or refuses with the reason
PKG                      # runs, whatever mechanism it needs
sudo-less explain PKG    # why it is in or out of scope, and how it runs
sudo-less doctor         # user namespaces, signature verification, wedged packages
```

The evidence behind these choices, and the baseline they are measured
against: [`survey-2026-09.md`](survey-2026-09.md).

## Principles

1. **One classifier.** Scope and mechanism are decided in one place, from the
   package itself. No second list to keep in sync.
2. **Ecosystems plug in; they do not branch off.** A language adds files to
   the stages. Nothing language-specific lives in the core scripts.
3. **Exceptions are documented, not coded.** Where the classifier is wrong
   about a package, the case goes in [`ecosystems.md`](ecosystems.md) and
   the classifier is fixed.
4. **Hooks never break apt.** A failing hook warns. The one deliberate stop
   is a refusal in stage 2, and it always says why.
5. **Everything is explainable.** Every decision is recorded where
   `sudo-less explain` can read it.
6. **apt and dpkg stay as original as possible.** They are patched only as
   far as native needs: no root, a prefix, a relocatable build
   ([`apt-dpkg-port.md`](apt-dpkg-port.md#beyond-termuxs-patches-our-own-changes)).
   Everything around a package is hooks; everything at run time is
   mechanisms.
7. **bash and plain text only**, no other runtime
   ([`standard.md`](standard.md)).
8. **Never root.** Nothing in the pipeline runs as root or asks for it; what
   needs root is the admin's, once.

## What exists today

| part | status |
|---|---|
| apt/dpkg port, prebuilt, `bootstrap.sh` | works; the three bugs a new account hit are fixed, and a fresh account was verified with the release build (criterion 1) |
| stage 1 sync | manual: `lock-seeded.sh --reseed` |
| stage 2 classify | `prefix-check` is hooked (`DPkg::Pre-Install-Pkgs`): it refuses a package that creates a system user or group, or installs kernel modules or into `/boot`, before dpkg runs; `check-package.sh` is not merged into it yet |
| stage 3 install | dpkg runs in the install view, with an empty `/run` so maintainer scripts cannot reach the host's services; no shims needed so far (the view made `py3compile`'s unnecessary) |
| stage 4 integrate | launchers (`01update-desktop-database`); `prefix-wrap` gives programs that need the view a script that runs them in the shared run view, and the rest run directly ([`view.md`](view.md#how-programs-get-there)) |
| ecosystems | documented in [`ecosystems.md`](ecosystems.md); no per-language code |
| state, `explain`, `doctor` | not yet |

## Order of work

1. Fork the patch set, same behaviour as today; rebase it onto current
   upstream apt and dpkg (apt 3.x verifies with `sqv`); add patches A
   (relocatable dpkg) and C (prefix hygiene), and `tools/` to the prebuilt.
   That fixes the three new-account bugs (criterion 1; done). Patch B (two-layer
   database) once the survey shows what a stale seed costs.
2. Stage 3: run dpkg in the prefix view ([`view.md`](view.md)) and the
   installed programs that need it in a shared run view (both done); add
   shims, on a `DPkg::Path`-only directory, for the common root-only
   helpers the survey finds.
3. Stage 2: hook a classifier (done: `prefix-check`); merge
   `check-package.sh` into it, so there is one.
4. Stage 4: state, and check for half-configured packages (the view
   wrappers are done).
5. Stage 1: sync on `update`.
6. `explain` and `doctor`.
7. Re-run the survey after each step; the per-section coverage is how the
   design is judged.
