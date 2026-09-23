# sudo-less

Install Debian packages into your home folder — **no root, no `sudo`**.

![license: GPL-3.0-or-later](https://img.shields.io/badge/license-GPL--3.0--or--later-blue)
![platform: Debian](https://img.shields.io/badge/platform-Debian-A81D33)
![root: not required](https://img.shields.io/badge/root-not%20required-brightgreen)

`sudo-less` gives you a real `apt` and `dpkg` that install `.deb` packages into
`~/.local` instead of the system. Your system files stay untouched, you don't
need admin rights, and you can undo everything by deleting one folder.

Use it when you can't — or would rather not — install software system-wide.

> [!WARNING]
> **If you remove your own admin access, keep a way back in.** This project can
> de-privilege a user on purpose. On a single-user machine that can lock you out
> of `sudo`; it's recoverable (boot a GRUB `init=/bin/bash` shell and run
> `admin/native/unlock.sh`) but needs physical access. Make sure at least one account
> still has a working privileged path, and back up first. See
> [`docs/hardening.md`](docs/hardening.md) and [`docs/roles.md`](docs/roles.md).

> [!CAUTION]
> **AI-assisted and unaudited.** The scripts, patches and docs were written with
> an AI assistant ([opencode](https://opencode.ai)). Read the code before you run
> it — especially the root scripts under `admin/`. This is not a security-reviewed
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

## Does it work for my package?

**Works well:** command-line tools, languages and interpreters (Python, Perl,
Ruby, Java), development libraries (`-dev`), fonts, and single-binary apps.

**Doesn't work:** packages that need root *to install* (services, `systemd`,
`adduser`, `debconf`) and setuid/PAM/kernel packages. GUI and 32-bit apps are
hit-and-miss.

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

- [`docs/paths.md`](docs/paths.md) — why some packages need extra help, and how.
- [`docs/standard.md`](docs/standard.md) — which packages are supported, and how
  each one is checked.
- [`docs/porting.md`](docs/porting.md) — building apt/dpkg yourself.
- [`docs/mobile.md`](docs/mobile.md) — Mobian phones and tablets.
- [`docs/flatpak-bridge.md`](docs/flatpak-bridge.md) — letting a Flatpak app talk
  to a program you installed here.
- [`docs/methodology.md`](docs/methodology.md) — the design and its limits.
- [`docs/system-resources.md`](docs/system-resources.md) — what Termux and Waydroid
  need from the system: unprivileged, fakeable, or admin-once.
- [`docs/updo.md`](docs/updo.md) — design and prototype: `updo` (userspace do), a sudo-like command
  that runs as a bounded middle identity (tier `limited`).

## Status

A **personal experiment** shared as a toolkit, for Debian-family systems. The
account names in the docs (`mobian` = admin, `master` = unprivileged) are just
examples. One maintainer supports one thing at a time: the install above is the
supported path; everything else (building from source, GUI apps, the deeper
tricks) is experimental. See [`docs/release.md`](docs/release.md).

## Repository layout

```
bootstrap.sh   one-command install (fetches prebuilt apt/dpkg)
apt-dpkg/      apt/dpkg setup: config, database seeding, small shims
scripts/       build, setup and catalog helpers
recipes/       per-package notes (see docs/standard.md)
tools/         deb2home.sh, prefix-run.sh, updo/ (prototype: client, daemon, updo-admin, .deb)
flatpak/       bridge for Flatpak apps (docs/flatpak-bridge.md)
admin/         one-time root-side setup that enables userspace (never runs your software)
  native/        base system only: enable-userspace (userns, subuid), unlock
  third-party/   only what needs root to work: install-tools (setuid uidmap, fuse3)
  verify-privs.sh  read-only check of the setup, run as the daily user
patches/       Termux's patches, verbatim
extras/        device-specific, NOT part of the supported core (this machine only)
  device/        root setup: SMART, desktop, Waydroid install
  waydroid/      Waydroid fixes (docs/waydroid-mesa-debug.md)
docs/          all the detail
```

## Disclaimer

Provided **"as is", without warranty of any kind** (see [`LICENSE`](LICENSE)). It
deliberately changes how privilege works on your machine and can run builds as
root inside a sandbox; read [`docs/methodology.md`](docs/methodology.md) and the
`admin/` scripts first. Parts were written with AI assistance and may contain
mistakes. You are responsible for your system and for keeping a recoverable admin
path. Not affiliated with Debian or Termux.

## Contributors & license

Built by **jronminh** with **deepseek-v4-flash** ([opencode](https://opencode.ai))
as pairing assistant — see [`CONTRIBUTORS.md`](CONTRIBUTORS.md).

[GPL-3.0-or-later](LICENSE). The patches under `patches/apt/termux/` and
`patches/dpkg/termux/` are taken verbatim from
[`termux/termux-packages`](https://github.com/termux/termux-packages) and remain
under their original GPL-2.0-or-later terms.
