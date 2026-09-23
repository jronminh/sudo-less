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

## Does it work for my package?

It depends first on the package's Debian **section**
([`docs/standard.md`](docs/standard.md#scope-by-debian-section)):

- **Supported:** libraries and `-dev`, languages (`python`, `perl`, `ruby`,
  `java`, `rust`, `golang`, `javascript`, …; see [`ecosystems/`](ecosystems/)),
  `utils`, `text`, `editors`, `doc`, `fonts`, science, graphics, sound, video,
  games, and desktop apps.
- **The admin's:** `admin`, `kernel`, `net` and `mail` servers, `database` and
  `httpd` servers, `tasks`, `metapackages`, and anything that creates a system
  user or ships a service, in any section.

Check any package *before* installing it:

```sh
scripts/catalog/check-package.sh nginx tree ranger
```

More detail: [`docs/working-packages.md`](docs/working-packages.md).

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

`apt` and `dpkg` are the real Debian programs (**apt 2.8.1**, **dpkg 1.22.6**)
plus [Termux](https://github.com/termux/termux-packages)'s patches, rebuilt to
install into `~/.local`. Your copy keeps its own package database, separate from
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
- [`docs/survey-2026-09.md`](docs/survey-2026-09.md) — a random sample by
  Debian section: what installs today and what blocks the rest.
- [`docs/standard.md`](docs/standard.md) — scope by Debian section, recipes,
  and how each package is checked.
- [`ecosystems/`](ecosystems/) — what each language needs (Python, Java, Perl,
  Ruby).
- [`docs/mechanisms.md`](docs/mechanisms.md) — how packages are made to run: environment variables and the overlay (for contributors).
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
apt-dpkg/      apt/dpkg setup: config, database seeding
ecosystems/    per-language support: install hooks, shims, notes (python, java, perl, ruby)
recipes/       per-package notes (see docs/standard.md)
tools/         prefix-run.sh (the overlay), deb2home.sh (extract without scripts)
scripts/       build, setup and catalog helpers
admin/         one-time root step that enables userspace: enable-userspace.sh
patches/       Termux's patches, verbatim
dev/           tools for developing sudo-less (dsb test policy)
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

[GPL-3.0-or-later](LICENSE). The patches under `patches/apt/termux/` and
`patches/dpkg/termux/` are taken verbatim from
[`termux/termux-packages`](https://github.com/termux/termux-packages) and remain
under their original GPL-2.0-or-later terms.
