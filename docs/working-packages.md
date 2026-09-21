# What installs and works (userspace apt/dpkg)

Empirically tested against the ported `apt 2.8.1` + `dpkg 1.22.6` on this box
(`apt-get install` into `~/.local`). Reproduce with
`scripts/test-packages.sh [PKG...]`.

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
