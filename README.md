# sudo-less

<a id="caution"></a>

> [!WARNING]
> **Keep a way back in — this project removes standing root on purpose.**
>
> Before you apply it, make sure at least one account still has a working
> privileged path: a `sudo`-capable account with a password you know, or a key
> you can log in with.
>
> On a **single-user device**, de-privileging the only user and stripping that
> last path **soft-locks you out of `sudo`/root**. It is recoverable, not a
> brick — boot a GRUB `init=/bin/bash` shell and use `admin/unlock.sh`
> (`passwd`, `usermod -aG sudo`) — but that needs physical access.
>
> Keep the admin account (`mobian` here) and its recovery route healthy and
> tested, and back up first. See `docs/hardening.md` and `docs/roles.md`.

> [!CAUTION]
> **AI-assisted and unaudited.** The scripts, patches, and docs here were
> written with an AI pairing assistant ([opencode](https://opencode.ai) /
> `deepseek-v4-flash`) — read the code, and don't treat it as a trusted or
> security-reviewed artifact. Be especially careful with the root scripts under
> `admin/` before running them.

> Run, build, and install software on Debian **as an unprivileged user** — no
> `sudo`, no root — including a **userspace `apt` + `dpkg`** that installs
> `.deb` packages into `~/.local`.

![license: GPL-3.0-or-later](https://img.shields.io/badge/license-GPL--3.0--or--later-blue)
![platform: Debian](https://img.shields.io/badge/platform-Debian-A81D33)
![root: not required](https://img.shields.io/badge/root-not%20required-brightgreen)

`sudo-less` is both a small toolkit and a recorded experiment: take a normal
Debian box, remove standing root from the daily user, and **still keep it fully
usable** — you can build from source, install packages, and manage them, without
ever escalating.

## Contents

- [Highlights](#highlights)
- [On mobile & tablets (Mobian)](#on-mobile--tablets-mobian)
- [Quick start](#quick-start)
- [Two package managers — don't mix them up](#two-package-managers--dont-mix-them-up)
- [Why this exists](#why-this-exists)
- [Who is this for](#who-is-this-for)
- [Who it is *not* for](#who-it-is-not-for)
- [Use cases](#use-cases)
- [Why it's cheap](#why-its-cheap)
- [How it works](#how-it-works)
- [What works](#what-works)
- [Repository layout](#repository-layout)
- [Scope & status](#scope--status)
- [Disclaimer](#disclaimer)
- [Contributors](#contributors)
- [License](#license)

## Highlights

- **Userspace apt/dpkg.** Debian **apt 2.8.1** + **dpkg 1.22.6**, built from
  [Termux's patches](https://github.com/termux/termux-packages) retargeted to
  `~/.local`, with real dependency resolution and a real dpkg database
  (`apt install`, `remove`, `upgrade`, `dpkg -l`, …).
- **No standing privileges.** Builds run in a *scoped, disposable* root — a
  user namespace, a real rootfs, or a rootless container — never on the host.
- **Reproducible.** One command per path: with root, without root, or in a
  container.
- **Predict before you install.** `check-package.sh` scores any package as
  `OK` / `RISKY` / `UNLIKELY` from its cached `.deb` — no install.
- **It just runs.** After setup, `apt-get install foo` works and `foo` is on
  your PATH in a new shell.
- **Cheap and dependency-light.** Nothing but this repo — no daemon, service,
  setuid helper, network listener, or third-party runtime; the no-root path uses
  standard in-distro tools (`mmdebstrap`, `bwrap`). See *Why it's cheap* below.

## On mobile & tablets (Mobian)

[Mobian](https://mobian-project.org/) devices — **ARM64 phones** and **x86_64
tablets** alike — are a **first-class target**, not a toy. It is exactly the
case this repo is for: install tools and dev libraries without root, keep the
system image pristine, and stay recoverable — a botched user-space install
cannot brick the device.

- **Architecture is auto-detected** (`amd64` or `arm64`), so both x86 tablets
  and ARM phones work; the rootfs and container follow the host arch.
- **x86_64 tablets are the fast case**: builds run natively (no ARM emulation),
  so `build-on-host.sh` with `sudo` is quick — the best place to *produce*
  artifacts for slower ARM phones.
- **On ARM phones**, prefer the root path if you have `sudo`; bootstrapping a
  rootfs on-device is heavier (~2 GB RAM, ~1.5 GB disk). Cross-built or
  CI-built artifacts are the friendlier route.
- Unprivileged user namespaces must be enabled; if `proot` fails, the repo
  already uses `bwrap` (this host's `yama.ptrace_scope=2` breaks `proot`).
- The reliability win is separation: the system apt (admin account) stays the
  single source of truth for the OS, while everything you experiment with lives
  in `~/.local` and is disposable.
- **Termux is the ancestor, not a source.** You *can* add `packages.termux.dev`
  and apt will download/extract the `.deb`s — but nothing runs: Termux packages
  are **bionic** (Android) ELFs with hardcoded `/data/data/com.termux/...`
  paths, and `proot` can't supply the missing libc. Running them needs the
  Android runtime (**Waydroid**, see `docs/waydroid.md`), not glibc.

The build is **relocatable**: build once on a fast x86 tablet, copy the tarball
to the phone, regenerate config, done. Recipes in
[`docs/mobile.md`](docs/mobile.md).

## Quick start

```sh
git clone https://github.com/jronminh/sudo-less && cd sudo-less

# 1. Have root/sudo on Debian? lightest path (no sandbox at all):
./scripts/build-on-host.sh

# 2. No root, but user namespaces + subuid: real rootfs, entered with bwrap
./scripts/make-buildroot.sh && ./scripts/build-in-rootfs.sh

# 3. No root, rootless podman available:
./scripts/build-in-container.sh
```

Then, in a new shell:

```sh
apt-get update
apt-get install -y ripgrep htop jq        # into ~/.local
dpkg -l                                    # your own database
```

See [`docs/porting.md`](docs/porting.md) for prerequisites and overrides, and
[`docs/working-packages.md`](docs/working-packages.md) for what installs well.

## Two package managers — don't mix them up

There are deliberately **two separate apt/dpkg setups** on the machine. Know
which one you're using:

| | system | user-space (this repo) |
|---|---|---|
| run as | `mobian` (admin) | `master` (daily user) |
| command | `sudo apt update && sudo apt upgrade` | `apt-get update && apt-get upgrade` |
| installs to | `/usr`, `/etc`, `/var` | `~/.local` |
| database | `/var/lib/dpkg` | `~/.local/var/lib/dpkg` |

- **To update the system**, log in as **`mobian`** and use the system `apt`.
  That is the only account that can — and should — touch system packages.
- **To update your own tooling**, as **`master`** use the user-space apt (the
  bare `apt`/`apt-get` in your shell *is* the user-space one). It only ever
  writes to `~/.local`.
- The two share **no** state: separate databases, config, caches and locks.
  Seeded system packages are held, so the user-space apt cannot change them.
- The userspace `apt` refuses to run as root, so it can't be used to touch the
  system by accident.

## Why this exists

The usual way to harden a box is to take capabilities away — and then it stops
being usable. This is the opposite experiment: **remove standing root from the
daily user, keep the machine fully usable.**

The key idea is that **root inside a sandbox is not root on the host**:

- The daily user has no `sudo`, so there is nothing to phish and a compromised
  session owns only its own files.
- When real privileges are needed, they are obtained *scoped and disposable*:
  a user namespace (`unshare -Ur`), a real rootfs (`mmdebstrap`), or a rootless
  container (`podman`) is a full, normal Debian where you are root *inside it* —
  while the host's `/usr`, `/etc`, `/var` are untouched.
- A few narrowly-scoped **polkit** actions cover genuinely privileged runtime
  needs (power, network, storage, a small service allowlist).
- The heavy lifting (retargeting and building apt/dpkg) happens in that scoped
  root; only the finished artifacts land in `~/.local`, and the build
  environment is thrown away and rebuilt from scripts.

The result: the transformation is *easy* (a real root to work with) and the
host stays *safe* (that root never reaches it).

**The hardening is optional.** The userspace package manager — and the tiered
approach to which packages work, and how — are useful with or without `sudo`.
What changes is only *which* build path and runtime tier are reachable, not
whether the toolkit is worth using. Run it **sudo-ful** and you still get a
clean `~/.local` prefix, a pristine `/usr`, and disposable per-project
toolchains; you additionally get the lighter `build-on-host` path and the
strongest tiers for free. sudo-less is the extreme end of a spectrum, not the
only mode.

## Who is this for

- **Locked-down / managed Linux** where you have no admin rights but still need
  CLI tools and dev libraries.
- **Shared multi-user hosts** — labs, jumphosts, CI sandboxes — where touching
  system packages is forbidden or antisocial.
- **Hardened / minimal systems** that are deliberately root-free.
- **You have `sudo` but want a pristine system** — install into `~/.local`
  anyway and leave `/usr` untouched (the sudo-ful mode).
- **Mobian phones and tablets** — see above.
- Anyone who wants **Debian `.deb`s + apt/dpkg semantics** (a real package
  database, `remove`/`upgrade`/`list`) in their home — not Homebrew bottles or
  conda environments.
- Security/DevOps folks interested in the **scoped-root pattern** itself.

## Who it is *not* for

- If you have `sudo` **and don't care about keeping the system tree pristine**,
  just use `apt`. (The prefix isolation is still useful sudo-ful — see *Why this
  exists*.)
- For plain user-space CLI tools, **Homebrew/Linuxbrew** is more mature.
- HPC/scientific stacks: **conda / spack / modules** already cover it.
- Desktop isolation: **distrobox / toolbox / flatpak / nix**.
- Immutable distros ship their own story.

## Use cases

- **Locked-down work laptop** — no admin rights, but you still need `git`,
  `ripgrep`, a compiler, `-dev` libraries. Install them into `~/.local`.
- **Shared multi-user host / lab / jumphost** — per-user toolchains without
  touching system packages or stepping on other users.
- **Hardened desktop** — no `sudo` by design; user-space tools still work.
- **Mobian phone or x86 tablet** — keep the OS image clean, install dev tools,
  and stay recoverable.
- **CI sandboxes / containers without root** — a package DB and resolver for a
  user you can't give root to.
- **Rescue / repair** — a broken or locked system where you still need to fetch
  and run tools.
- **Reproducible per-project environments** — install and pin versions in a
  prefix, throw it away, rebuild from scripts.

## Why it's cheap

- **Nothing but this repo.** All text — no binaries, no service, no daemon, no
  network listener, no third-party runtime, no proprietary installer, no
  `curl | bash`. (The optional *container* path relies on the distro's setuid
  `newuidmap`/`newgidmap`, as every rootless container does; the rootfs path
  needs no setuid at all.)
- The **root path needs zero extra tooling** — just `apt` and these scripts.
- The **no-root path uses standard Debian packages** (`mmdebstrap`, `bwrap`,
  `proot`), in-distro and auditable — not exotic or questionable binaries.
- The **build environment is disposable**: the scoped root/rootfs/container is
  thrown away; only the finished artifacts stay.
- Small on disk: scripts and patches. The rootfs is the largest cost and it is
  optional.

## How it works

- **apt** is upstream Debian apt + Termux's 14 patches; **dpkg** is upstream
  dpkg + Termux's 9 patches and `configure.diff`. Neither is a fork.
- `@TERMUX_PREFIX@` (a self-contained Termux rootfs) is remapped: helper
  binaries → `/usr/bin`, `tmp` → `/tmp`, apt's own `etc/apt` → `$PREFIX`.
- **dpkg is compiled with `-D__ANDROID__`** so Termux's patches activate and
  skip the root-only steps (superuser check, `chown`) — i.e. it behaves like
  Termux's dpkg.
- Packages install with `--instdir=$PREFIX` (a real rootfs layout:
  `$PREFIX/usr/bin`, …) plus `--force-script-chrootless`.
- The local dpkg database is **seeded from the system's**, so apt treats
  already-installed libraries as satisfied and only installs leaf packages.

Full write-up: [`docs/apt-dpkg-port.md`](docs/apt-dpkg-port.md). Methodology
behind the no-root build paths: [`docs/methodology.md`](docs/methodology.md).

## What works

Great for **user-space tooling and dev libraries**: CLI tools, interpreters and
toolchains, `-dev` packages, fonts, single-binary apps.

Not a system package manager: packages that need root in their maintainer
scripts (services, `systemd`, `adduser`, `debconf`), Python *applications*
(absolute `dist-packages` paths), or setuid/PAM/kernel bits will not work.
Details and the `check-package.sh` predictor:
[`docs/working-packages.md`](docs/working-packages.md).

## Repository layout

```
docs/        methodology, mobile, porting, apt-dpkg-port, working-packages,
             polkit, roles, hardening, waydroid
scripts/     build-apt, build-dpkg, build-on-host, make-buildroot, build-in-rootfs,
             build-in-container, install-config, install-shell-path,
             install-session-env, lock-seeded, check-package, test-packages,
             fetch-sources, common
patches/     apt/{termux,local}, dpkg/termux   (verbatim upstream patches + our fixes)
config/      apt.conf.d template, sources.list
tools/       deb2home.sh   (extract a .deb into $HOME without root)
admin/       root-side scripts run by the admin account (example setup)
```

## Scope & status

A **personal experiment** recorded as a reusable toolkit. The user names
`mobian` (admin) and `master` (unprivileged) are **example personas** for a
two-user split; substitute your own. Host-specific details (network ranges, SSH
key names, absolute home paths) are genericised, and the prefix config is
generated from `$PREFIX` rather than hardcoded.

Targets Debian-family systems. Nothing here is guaranteed — read it alongside
`docs/methodology.md`. Issues and PRs welcome.

## Disclaimer

`sudo-less` is a **personal experiment recorded as a reusable toolkit**,
provided **"as is", without warranty of any kind** (see [`LICENSE`](LICENSE)).
It deliberately changes how privilege works on your machine and runs builds as
*scoped* root; read `docs/methodology.md` and the scripts under `admin/` before
running them. Parts were written with AI assistance and may contain mistakes.
You are responsible for the state of your system and for keeping
a recoverable admin path (see [Caution](#caution)). Not affiliated with Debian
or Termux.

## Contributors

See [`CONTRIBUTORS.md`](CONTRIBUTORS.md) — built by **jronminh** with
**deepseek-v4-flash** ([opencode](https://opencode.ai)) as pairing assistant.

## License

[GPL-3.0-or-later](LICENSE). The patches under `patches/apt/termux/` and
`patches/dpkg/termux/` are taken verbatim from
[`termux/termux-packages`](https://github.com/termux/termux-packages) and remain
under their original GPL-2.0-or-later terms; the apt and dpkg sources they apply
to are likewise GPL-2.0-or-later, which is compatible with GPL-3.0.
