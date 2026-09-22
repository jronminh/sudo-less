# What installs and works (userspace apt/dpkg)

Empirically tested against the ported `apt 2.8.1` + `dpkg 1.22.6` on this box
(`apt-get install` into `~/.local`). Reproduce with
`scripts/test-packages.sh [PKG...]`.

The reason a package can install cleanly and still fail is that relocating a
`.deb` does not rewrite paths compiled into its binaries; see
[`paths.md`](paths.md) for the model and [`tools/prefix-run.sh`](../tools/prefix-run.sh)
for the runtime fix. `scripts/check-package.sh --runtime` labels each package
`direct`, `env`, `overlay`, or `never` (an `interp=`/`shebang:` hint on `env`
and `overlay` says which gap — see [`standard.md`](standard.md) and #7).

## Predict without installing: `scripts/check-package.sh`

Fetch the `.deb` from the repo and read it offline with `dpkg-deb` — no install,
no dpkg-db change:

```sh
./scripts/check-package.sh tree gcc nginx ranger libssl-dev
#   tree        OK        section=utils
#   gcc         RISKY     script: update-alternatives
#   nginx       UNLIKELY  script: /etc/init.d,invoke-rc.d
#   ranger      RISKY     script: py3compile paths: /usr/lib/python3/,/usr/lib/python3/dist-packages/
#   libssl-dev  OK        section=libdevel

./scripts/check-package.sh --meta nginx     # index metadata only (no download)
```

Verdicts are split into **hard blockers** and **benign/soft (incl. shipped
fixes)** signals:

- **UNLIKELY** — a hard blocker this repo has no fix for:
  - maintainer script calls a root-only step that fails
    (`systemctl`, `invoke-rc.d`, `update-rc.d`, `adduser`, `debconf`,
    `ldconfig`, `chroot`, `dpkg-statoverride`, …);
  - file list has a hard path (`/etc/pam.d/`, `/lib/modules/`, …) → PAM/kernel
    module;
  - deps pull plumbing (`init-system-helpers`, `adduser`, `debconf`,
    `initramfs-tools`, …); or `Essential: yes`.
- **RISKY** — installs and usually works, but touches system integration, or
  hits a blocker this repo already ships a fix for:
  - `update-alternatives`, `update-menus`, `update-desktop-database`,
    `install-info`, … (Debian tolerates these);
  - ships systemd units / `init.d` / `udev` / dbus / polkit / `tmpfiles.d`,
    or `/usr/libexec/`;
  - **`py3compile` postinst / `/usr/lib/python3/dist-packages/` files** — pure
    Python app. `shims/py3compile` fixes the install, and
    `install-config.sh`'s `.pth` fixes `sys.path` (#5) — see `ranger.recipe`.
- **OK** — none of the above.

Remember the **seeded db**: packages already installed system-wide are treated
as satisfied, so apt does *not* copy them into the prefix (they just run from
the system). Only packages the system lacks are actually installed into
`~/.local/usr`.

## Verified working (installed into `~/.local`, binaries run)

| package | notes |
|---|---|
| `fzf` `htop` `ncdu` `tree` `duf` `procs` `hyperfine` | simple CLI tools |
| `shellcheck` `shfmt` | static-ish analyzers |
| `sqlite3` | CLI + lib |
| `patchelf` `strace` `ltrace` | dev/debug tools |
| `ranger` | pure-Python app — was "usually broken" (see below); fixed by `shims/py3compile` + `install-config.sh`'s `.pth`, see `recipes/ranger.recipe` and #5 |
| `pmarkdown` | pure-Perl CLI — `PERL5LIB`, see `recipes/pmarkdown.recipe` and #7 |
| `yard` | Ruby (pulls in a fresh interpreter) — run via `tools/prefix-run.sh --mode overlay`, see `recipes/yard.recipe` and #7 |

General rule: **leaf, user-space binaries with no root-needing maintainer
script** install and run. A postinst blocker or interpreter search-path gap
isn't necessarily fatal — check `recipes/` first (see
[`standard.md`](standard.md)) before assuming a package is broken.

## Verified failing (and why)

| package | failure | cause |
|---|---|---|
| `bat` | `libgit2.so.1.9: cannot open shared object` | dependency not present; `bat`'s binary name is also `batcat`, not `bat` |
| `screen` | `dpkg ... returned error code (1)` | postinst touched something root-only (`/run/screen`, `/lib/systemd/system`, `update-rc.d`) with no `\|\| true` guard — genuine `tier never`, see `recipes/screen.recipe` |
| `javascript-common` | `dpkg ... returned error code (1)` | same shape as `screen`, see `recipes/javascript-common.recipe` |

## Categories

**Usually fine**
- CLI utilities, text/file tools, shells (`tmux`, `jq`, `fd-find`→`fdfind`,
  `ripgrep`→`rg`, `bat`→`batcat`), fonts (`fonts-*`).
- Interpreters and toolchains installed as data/binaries (`nodejs`, `go`,
  `rustc`, `python3`, `gcc`, `clang`).
- `-dev` libraries for building against (use `PKG_CONFIG_PATH`,
  `CMAKE_PREFIX_PATH`, `LD_LIBRARY_PATH`).
- Single-binary apps and self-contained runtimes.

**Usually fixable (not "usually broken")**
- Python, Perl, Ruby applications: an interpreter's own default module search
  path (`sys.path`/`@INC`/`$LOAD_PATH`) doesn't reach `$PREFIX`, or (Python)
  postinst `py3compile` writes to the absolute `/usr/lib/python3`. See
  [*Prefer `pip`/`pipx` for pure Python*](#prefer-pippipx-for-pure-python-apps)
  below and #7 for Perl/Ruby/Java. `check-package.sh --runtime` reports the
  gap as `env interp=...` or `overlay shebang:...` rather than a hard
  blocker — check `recipes/` before assuming it's broken.

**Usually broken**
- Anything with **systemd units**, `adduser`, `systemctl`, `ldconfig`, `debconf`
  in maintainer scripts (servers: `nginx`, `postgresql`, `docker.io`, …).
- setuid/privileged helpers (`sudo`, `passwd`, `su`), PAM, kernel/initramfs
  packages, X/display servers, desktop environments.
- Packages needing **privileged ports** or system users.

**Silent no-ops** (already system-installed → apt skips them): on a normal
desktop this is most common tools. That's intended (don't duplicate system
libraries), but it means "apt said OK" ≠ "installed into the prefix".

## Prefer `pip`/`pipx` for pure-Python apps

For a **pure-Python** CLI tool, stop fighting apt: `pip install --user` /
`pipx install` land on `sys.path` and `PATH` with zero tricks, because the
system Python's user site (`python3 -m site --user-site`) and user base
(`python3 -m site` → `USER_BASE`) are already *inside* `$PREFIX`
(`~/.local/lib/python3.X/site-packages`, `~/.local/bin`). No `.pth`, no
`PYTHONPATH`, no maintainer script. Verified on this host:

```sh
pipx install <tool>              # cleanest: manages its own venv, no flags
python3 -m pip install --user --break-system-packages <tool>  # also works
```

**Caveat found testing this**: Debian's Python is
[PEP 668](https://peps.python.org/pep-0668/) "externally managed" —
plain `pip install --user` refuses outright (`error:
externally-managed-environment`) unless you pass
`--break-system-packages`. `pipx` doesn't hit this at all (it builds an
isolated venv per tool), so **`pipx` is the actually-recommended path**, not
just an alternative to `pip --user`.

The apt route (`recipes/ranger.recipe`) still earns its keep for packages
with **compiled C extensions** or real system integration — `pip`/`pipx`
can't relocate those any better than apt can.

## Notable rough edges seen

- `update-alternatives` in postinsts referenced `/usr/bin/...` (system paths)
  rather than the prefix, because the maintainer script passes absolute paths
  and dpkg's `--instdir` is not chrooted. It doesn't write to the system as
  non-root (no privilege), but the alternatives it records are not useful in the
  prefix.
- `apt-key`/signature verification needs a real `gpgv` on PATH.
- Binary names differ from package names for several tools (`batcat`,
  `fdfind`, `rg`).

## Bottom line

Good for **user-space tooling and dev libraries**. Not a system package
manager: skip anything that installs services, users, setuid bits, or
privileged ports. Python/Perl/Ruby apps are no longer in that bucket — see
`recipes/` and #7.
