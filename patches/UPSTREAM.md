# Where these patches come from

sudo-less's apt and dpkg patches are a fork of Termux's, cut down to what a
user-writable prefix on Debian needs ([`../docs/apt-dpkg-port.md`](../docs/apt-dpkg-port.md)).
Each patch starts with an `Origin:`, `Change:` and `License:` header; the
`series` file in each directory is the order they are applied in.

**Base:** [termux-packages](https://github.com/termux/termux-packages)
commit `91af886a0af1bcd0b9231cda883013027c3e9490` (2026-09), whose apt
patches have not changed since `4e756e3` (2024-08-15) and whose dpkg patches
not since `bd75fa6` (2025-08-07). Termux builds apt 2.8.1 and dpkg 1.22.6
there. The Termux patches are GPL-2.0-or-later, like apt and dpkg.

## apt

| Termux patch | here | why |
|---|---|---|
| `0000-cmake-fix` | `0001-cmake-no-libutil-no-tests` | kept verbatim for now; build-system changes for the NDK, probably unneeded on Debian |
| `0001-no-macro-redef` | `0002-no-ramfs-magic-redef` | kept verbatim |
| `0002-no-locales` | dropped | acts only under `__ANDROID__`, which apt is not built with |
| `0003-no-srv-records` | dropped | same |
| `0004-no-hardcoded-paths` | `0003-prefix-paths` | kept verbatim: the prefix paths, a native need |
| `0005-http2-fix` | `0004-http2-status-line` | kept verbatim |
| `0006-no-init-arch-tuple` | dropped | acts only under `__ANDROID__` |
| `0007-aptkey-no-root` | `0005-apt-key-no-root` | kept verbatim: a native need |
| `0008-fix-function-args` | `0006-socklen-t` | kept verbatim |
| `0009-update-error-messages` | dropped | Termux's own messages, only under `__ANDROID__` |
| `0010-prevent-usage-as-root` | `0007-refuse-root` | kept verbatim: the userspace apt never runs as root |
| `0011-keep-downloaded-packages` | dropped | Debian's default (do not keep `.deb` files) saves the user's disk |
| `0012-ndk-r27` | dropped | an NDK compiler fix |
| `0013-fix-patterns` | dropped | renames apt's search patterns away from Debian's documented names |
| (sudo-less) `local/0001-gcc16-fixes` | `0008-gcc16-fixes` | ours, for GCC 16 |

## dpkg

Termux's dpkg patches guard their changes with `#ifndef __ANDROID__`, and
sudo-less used to build dpkg with `-D__ANDROID__`, which switched on every
Android branch. Now only the changes a prefix needs are kept, as plain
patches, and nothing is built with `__ANDROID__`.

| Termux patch | here | why |
|---|---|---|
| `dbmodify_dont_require_root` | `0001-no-superuser-check` | adapted: no guard. A native need |
| `src-archives.c` | `0002-no-chown` (with the next) | adapted: only the `chown`/`fchown`/`lchown` removals. Not taken: `rename` instead of hard links and the symlink-size warnings, both Android specifics |
| `src-statoverride-main.c` | `0002-no-chown` | adapted: no guard |
| `src-help.c` | `0003-no-ldconfig-check` | adapted: no guard; `ldconfig` is not on a user's `PATH`, and a prefix never runs it |
| `configure.diff` | dropped | fixed the architecture for Termux's cross build; a native build detects it |
| `lib-dpkg-atomic-file.c`, `src-configure.c` | dropped | `rename` instead of hard links: Android specifics |
| `lib-dpkg-path-remove.c` | dropped | an `EROFS` case of Android's read-only `/` |
| `mandoc_hook` | dropped | Termux uses mandoc; Debian uses man-db |
| `scripts-dpkg-scanpackages.pl` | dropped | a Termux path in a tool sudo-less does not use |

## Updating

Upstream apt and dpkg are followed: when Debian moves to a new version,
rebase the `series` onto it. When Termux changes a patch that is kept here,
compare it against this table.
