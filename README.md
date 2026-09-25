# sudo-less

Install Debian packages into your home folder — **no root, no `sudo`**.

![license: GPL-3.0-or-later](https://img.shields.io/badge/license-GPL--3.0--or--later-blue)
![platform: Debian](https://img.shields.io/badge/platform-Debian-A81D33)
![root: not required](https://img.shields.io/badge/root-not%20required-brightgreen)

`sudo-less` gives you a real `apt` and `dpkg` that install `.deb` packages into
`~/.local` instead of the system. Your system files stay untouched, you don't
need admin rights, and you can undo everything by deleting one folder.

Use it when you can't — or would rather not — install software system-wide.

> [!CAUTION]
> **AI-assisted and unaudited.** The scripts, patches and docs were written with
> an AI assistant ([opencode](https://opencode.ai)). Read the code before you run
> it — especially the root script under `admin/`. This is not a security-reviewed
> artifact.

## Install

No root, no compiling:

```sh
curl -fsSL https://raw.githubusercontent.com/jronminh/sudo-less/main/bootstrap.sh | bash
```

Then, in a new shell:

```sh
apt-get update
apt-get install -y ripgrep htop jq     # installs into ~/.local
dpkg -l                                 # your own package list
```

`ripgrep`, `htop` and `jq` are now on your `PATH` — that's the whole idea. The
download is checked against a published hash; see
[`docs/release.md`](docs/release.md) for how the trust works and how to verify a
build yourself.

## Goal

A user created on a **standard Debian install, with no `sudo`**, installs and
uses `.deb` packages from the supported sections into `~/.local`. The admin
does a one-time step (`admin/`) and nothing per package.

Measured by:

1. **A new user works at once:** `bootstrap.sh`, then `apt-get update && apt-get
   install PKG`, on a fresh standard install.
2. **Coverage per section:** the share of randomly sampled packages that
   install and run, per supported Debian section, re-measured each release.
3. **A clear boundary:** which sections are the admin's, and which packages are
   `never` and why.

Where it stands: criterion 1 is verified on a fresh account with the release
build. Criterion 2 is measured by [the survey](#evidence-the-survey) below.
Criterion 3 is the [problem map](docs/problems.md), and `apt-get install`
enforces it.

## Evidence: the survey

The approach (rebuild only apt and dpkg, and make the prefix look like `/`
only for the programs that need it) is checked by a survey rather than by
hand-picked examples. `dev/survey.sh` takes packages sampled at random, 3 per
Debian section. It installs each one into a fresh copy of the same prefix,
then runs every program it ships. It records where each package stops:
while installing or while running, and why.

Latest run, 2026-09-24, on 129 packages from 43 supported sections:

| | packages | share |
|---|---|---|
| **installs and works** | 86 | **67 %** |
| blocked by version skew: the archive is newer than the host | 30 | 23 % |
| a maintainer script fails | 9 | 7 % |
| other (refused at unpack; already on the host; a program fails or runs partly) | 4 | 3 % |

- **Excluding skew, 87 % work.** The admin removes skew by upgrading the
  host; on Debian stable it is close to zero.
- **Most programs need no tricks.** Of the 70 programs checked, 22 run
  directly from `~/.local/usr/bin` and 42 through the shared run view.
- **Better than the first design** (a Termux-style relocated dpkg, same
  129 packages): installs went from 63 % to 68 %, and programs from 14
  working and 12 failing to 26 working and 1 failing.
- **The failures fall into a few known classes:** system users, ownership
  changes, writes to host directories the view has no copy of. Each is
  placed on the [problem map](docs/problems.md) with its fix, or marked as
  the admin's.
- **Outside the supported sections** (36 packages from `admin`, `net`,
  `mail`, `kernel`, ...), 19 install. Most failures are services, system
  users and `/boot`, which the admin's sections are meant to hold. That is
  the basis for a proposed limited admin and net scope.

Read more:

- [**The full report**](docs/survey.md): method, per-section tables,
  package-by-package comparison, failure classes, and next steps.
- The raw results: [`results.tsv`](docs/survey/results.tsv) (one line per
  package: install verdict, error detail, each program and how it ran) and
  the sample, [`list.tsv`](docs/survey/list.tsv).
- The first survey, the baseline:
  [`docs/survey-2026-09.md`](docs/survey-2026-09.md).
- To re-run it: see the header of [`dev/survey.sh`](dev/survey.sh).

## Does it work for my package?

It depends first on the package's Debian **section**
([`docs/standard.md`](docs/standard.md#by-debian-section)):

- **Supported:** libraries and `-dev`, languages (`python`, `perl`, `ruby`,
  `java`, `rust`, `golang`, `javascript`, …; see [`docs/ecosystems.md`](docs/ecosystems.md)),
  `utils`, `text`, `editors`, `doc`, `fonts`, science, graphics, sound, video,
  games, and desktop apps.
- **The admin's:** `admin`, `kernel`, `net` and `mail` servers, `database` and
  `httpd` servers, `tasks`, `metapackages`, and anything that creates a system
  user or ships a service, in any section.

`apt-get install` refuses a package that needs root (one that creates a
system user, or installs kernel modules), before anything is installed,
and says why. To check a package by hand first:

```sh
scripts/catalog/check-package.sh nginx tree ranger
```

What can and cannot work, and why: [`docs/problems.md`](docs/problems.md).

## Why you'd want this

- A **locked-down or managed machine** where you have no admin rights but still
  need real tools and a compiler.
- A **shared server or lab box** where touching system packages is forbidden.
- **Keeping the system clean** — install into `~/.local` even when you *do* have
  `sudo`, and leave `/usr` alone.

**Not** the right tool for: plain CLI tools where [Homebrew](https://brew.sh) is
more mature, scientific stacks (conda/spack), or desktop app isolation
(Flatpak/distrobox). And if you have `sudo` and don't care about a pristine
system, just use `apt`.

## How it works

`apt` and `dpkg` are the real Debian programs (**apt 3.3.3**, **dpkg 1.23.11**)
plus a few patches forked from [Termux](https://github.com/termux/termux-packages)'s, rebuilt to
install into `~/.local`. dpkg runs in a private view where `~/.local` looks like
`/usr`, `/etc` and `/var`, so packages install unchanged
([`docs/view.md`](docs/view.md)). Your copy keeps its own package database, separate from
the system's, and treats everything already on the system as already installed —
so it only fetches what you actually ask for. Neither program is a fork.

The system's own `apt` is untouched: use `sudo apt` to update the OS, and the
plain `apt`/`apt-get` in your shell to manage your own tools.

Full detail: [`docs/apt-dpkg-port.md`](docs/apt-dpkg-port.md).

Everything here is **plain shell scripts** — no daemon, no third-party runtime,
no binaries of our own. The only compiled code is `apt` and `dpkg` themselves.
That's deliberate, and it's what makes the project special: you can read every
line of what runs on your machine, and there is nothing to trust but the code in
this repo.

## Going deeper

- [`docs/design.md`](docs/design.md) — the whole solution on one page: the
  pipeline sudo-less hangs on apt's hooks, its parts, and what exists today.
- [`docs/survey.md`](docs/survey.md) — a random sample by Debian section,
  installed and run: what works today and what blocks the rest.
- [`docs/standard.md`](docs/standard.md) — scope by Debian section, and how
  each package is checked.
- [`docs/ecosystems.md`](docs/ecosystems.md) — what each language and some
  single packages made hard, and what the prefix view changes.
- [`docs/view.md`](docs/view.md) — the prefix views: the one dpkg runs in,
  and the shared one for installed programs that need it.
- [`docs/problems.md`](docs/problems.md) — every obstacle between a `.deb` and a user without root, by when it bites and who can fix it (for contributors).
- [`docs/admin-features.md`](docs/admin-features.md) — planned: one-time admin steps that give userspace more (linger, subid, devices), and the rule that keeps them safe.
- [`docs/porting.md`](docs/porting.md) — building apt/dpkg yourself.
- [`docs/methodology.md`](docs/methodology.md) — the design and its limits.
- [`docs/prior-art.md`](docs/prior-art.md) — Termux and proot-distro: the same problem from the other end, and what we took from them.
- [`dev/`](dev/) — tools for developing sudo-less, such as a
  [dsb](https://github.com/jronminh/dsb) policy with a clean test account.

## Status

A **personal experiment** shared as a toolkit, for Debian-family systems. The
account names in the docs (`mobian` = admin, `master` = unprivileged) are just
examples. One maintainer supports one thing at a time: the install above is the
supported path; everything else (building from source, GUI apps, the deeper
tricks) is experimental. See [`docs/release.md`](docs/release.md).

## Repository layout

```
bootstrap.sh   one-command install (fetches prebuilt apt/dpkg)
apt-dpkg/      apt/dpkg: setup, config/ (apt.conf.d hooks, dpkg.cfg),
               patches/ (a fork of Termux's, patches/UPSTREAM.md)
tools/         prefix-view.sh (the install, run and service views), prefix-wrap.sh
               (which programs run in the view), prefix-units.sh (packages'
               systemd units as user units), prefix-check.sh (refuses what
               needs root), prefix-run.sh (the older overlay), deb2home.sh (extract
               without scripts)
scripts/       build, setup and catalog helpers
admin/         one-time root step that enables userspace: enable-userspace.sh
dev/           tools for developing sudo-less (dsb test policy, survey.sh)
docs/          all the detail
```

## Disclaimer

Provided **"as is", without warranty of any kind** (see [`LICENSE`](LICENSE)). The
admin step changes system settings (user namespaces, `PATH` for all users);
read [`docs/methodology.md`](docs/methodology.md) and the `admin/` script first.
Parts were written with AI assistance and may contain
mistakes. You are responsible for your system and for keeping a recoverable admin
path. Not affiliated with Debian or Termux.

## Contributors & license

Built by **jronminh** with **deepseek-v4-flash** ([opencode](https://opencode.ai))
as pairing assistant — see [`CONTRIBUTORS.md`](CONTRIBUTORS.md).

[GPL-3.0-or-later](LICENSE). The patches under `apt-dpkg/patches/` are a fork of
[`termux/termux-packages`](https://github.com/termux/termux-packages)'s and remain
under their original GPL-2.0-or-later terms (`apt-dpkg/patches/UPSTREAM.md`).
