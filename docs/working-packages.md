# What installs and works (userspace apt/dpkg)

Empirically tested against the ported `apt 2.8.1` + `dpkg 1.22.6` on this box
(`apt-get install` into `~/.local`). Reproduce with
`scripts/test-packages.sh [PKG...]`.

The reason a package can install cleanly and still fail is that relocating a
`.deb` does not rewrite paths compiled into its binaries; see
[`paths.md`](paths.md) for the model and [`tools/prefix-run.sh`](../tools/prefix-run.sh)
for the runtime fix. `scripts/check-package.sh --runtime` labels each package
`direct`, `overlay`, or `never`.

## Predict without installing: `scripts/check-package.sh`

Fetch the `.deb` from the repo and read it offline with `dpkg-deb` — no install,
no dpkg-db change:

```sh
./scripts/check-package.sh tree gcc nginx ranger libssl-dev
#   tree        OK        section=utils
#   gcc         RISKY     script: update-alternatives
#   nginx       UNLIKELY  script: /etc/init.d,invoke-rc.d
#   ranger      UNLIKELY  script: py3compile paths: /usr/lib/python3/dist-packages/
#   libssl-dev  OK        section=libdevel

./scripts/check-package.sh --meta nginx     # index metadata only (no download)
```

Verdicts are split into **hard blockers** and **benign/soft** signals:

- **UNLIKELY** — a hard blocker:
  - maintainer script calls a root-only step that fails
    (`systemctl`, `invoke-rc.d`, `update-rc.d`, `adduser`, `debconf`,
    `ldconfig`, `chroot`, `py3compile`, `dpkg-statoverride`, …);
  - file list has a hard path (`/usr/lib/python3/dist-packages/`, `/etc/pam.d/`,
    `/lib/modules/`, …) → Python app / system module;
  - deps pull plumbing (`init-system-helpers`, `adduser`, `debconf`,
    `initramfs-tools`, …); or `Essential: yes`.
- **RISKY** — installs and usually works, but touches system integration:
  - `update-alternatives`, `update-menus`, `update-desktop-database`,
    `install-info`, … (Debian tolerates these);
  - ships systemd units / `init.d` / `udev` / dbus / polkit / `tmpfiles.d`,
    or `/usr/libexec/`.
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
| `screen` | binary runs; its postinst reported an error (see below) |

General rule: **leaf, user-space binaries with no root-needing maintainer
script** install and run.

## Verified failing (and why)

| package | failure | cause |
|---|---|---|
| `ranger` | Python traceback | its `postinst` byte-compiles into the **hardcoded** `/usr/lib/python3/dist-packages/...` (absolute path, ignores the prefix) |
| `bat` | `libgit2.so.1.9: cannot open shared object` | dependency not present; `bat`'s binary name is also `batcat`, not `bat` |
| `screen` | `dpkg ... returned error code (1)` | postinst touched something root-only; the installed binary still runs |

## Categories

**Usually fine**
- CLI utilities, text/file tools, shells (`tmux`, `jq`, `fd-find`→`fdfind`,
  `ripgrep`→`rg`, `bat`→`batcat`), fonts (`fonts-*`).
- Interpreters and toolchains installed as data/binaries (`nodejs`, `go`,
  `rustc`, `python3`, `gcc`, `clang`).
- `-dev` libraries for building against (use `PKG_CONFIG_PATH`,
  `CMAKE_PREFIX_PATH`, `LD_LIBRARY_PATH`).
- Single-binary apps and self-contained runtimes.

**Usually broken**
- Python applications: postinst `py3compile` writes to `/usr/lib/python3`
  (absolute), and modules land under the prefix where the system `python3`
  won't look.
- Anything with **systemd units**, `adduser`, `systemctl`, `ldconfig`, `debconf`
  in maintainer scripts (servers: `nginx`, `postgresql`, `docker.io`, …).
- setuid/privileged helpers (`sudo`, `passwd`, `su`), PAM, kernel/initramfs
  packages, X/display servers, desktop environments.
- Packages needing **privileged ports** or system users.

**Silent no-ops** (already system-installed → apt skips them): on a normal
desktop this is most common tools. That's intended (don't duplicate system
libraries), but it means "apt said OK" ≠ "installed into the prefix".

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
Python-app byte-compilation into system paths.
