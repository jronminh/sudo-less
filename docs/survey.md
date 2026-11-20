# Survey: the view model, measured

The second real-installation survey, and the first run with `dev/survey.sh`.
It checks the same 129 in-scope packages as
[`survey-2026-09.md`](survey-2026-09.md), now with dpkg in the install view
and programs in the run view ([`view.md`](view.md)), so the two results can
be compared package by package. It also tries 36 packages from the sections
[`standard.md`](standard.md) leaves out, as the first evidence for a
limited admin scope. [`problems.md`](problems.md) takes its numbers from
here.

Raw data: [`survey/list.tsv`](survey/list.tsv) (the
sample) and [`survey/results.tsv`](survey/results.tsv)
(one line per package; the columns are described in `dev/survey.sh`'s
header).

## Method

- **Host:** Debian forky/sid, kernel 7.1, the `dpkg-view` branch (dpkg in
  the install view with an empty `/run`, `prefix-wrap` after every dpkg run),
  2026-09-24.
- **Sample:** 174 packages.
  - **In scope:** 129 packages, exactly the 129 of the first survey (the
    first 3 per section of 43 sections).
  - **Out of scope:** the first 3 of each out-of-scope section in
    `survey-2026-09/static.tsv`: 45 packages in 15 sections. The run was
    stopped after 36 of them. `otherosfs`, `tasks` and `zope` were not run.
- **Per package:** a fresh copy of one configured prefix, then
  `apt-get install -y --no-install-recommends`, then every program the
  package puts in `/usr/bin`, `/usr/sbin` or `/usr/games` run with
  `--version`, else `--help`: directly, or through its `prefix-wrap`
  script. Programs run cut off from the desktop session (no display, no
  session bus, an empty `XDG_RUNTIME_DIR`).
- **No `prefix-check` hook** in the base prefix, so a package that would be
  refused is installed and fails as it would without the check. That is how
  the check's gaps show up below.

## Results

### In scope (129 packages)

| install | packages | share |
|---|---|---|
| **ok** | 88 | **68 %** |
| version **skew** with the host | 30 | 23 % |
| a maintainer **script** failed | 9 | 7 % |
| **unpack** refused | 1 | 1 % |
| other | 1 | 1 % |

The one "other" is `libtext-charwidth-perl`, which the host already has. The
survey misreads that case.

Of the 88 installed packages:

| run | packages |
|---|---|
| none: no program on `PATH` (libraries, data, docs, fonts) | 58 |
| ok | 26 |
| partial | 1 (`xfce4-dev-tools`: `xfce-do-release` needs a git repository, a test artifact) |
| untested: needs a display or a terminal | 2 |
| fail | 1 (`progvis`) |

**Installs and works: 86 of 129 (67 %). Leaving out version skew: 86 of 99
(87 %).**

Programs checked: 22 run directly, 42 in the run view, 2 need a display,
2 hang in the view, 2 fail directly. `progvis` fails directly ("Could not
find progvis.main") and hangs in the view, which looks like a `prefix-wrap`
miss (storm-lang).

### Old model against new, same packages

| | 2026-09 (Termux-style port, `prefix-run.sh`) | 2026-09b (views) |
|---|---|---|
| installed | 80 (63 %) | 88 (68 %) |
| skew | 30 | 30 |
| maintainer script | 17 | 9 |
| programs: works / partly / fails | 14 / 5 / 12 | 26 / 1 / 1 |

Package by package (old verdict → new):

| old | new | packages |
|---|---|---|
| installed, no program | ok, none | 48 |
| held (skew) | skew | 30 |
| ran via overlay | ok, ok | 7 |
| ran directly | ok, ok | 6 |
| script | script | 6 |
| script | ok, ok | 5 |
| script | ok, none | 5 |
| run failed | ok, ok | 4 |
| partial | ok, ok | 4 |
| run failed | ok, none | 3 |
| run failed | script | 2 |
| run failed | ok, untested | 2 |
| network | ok, none | 2 |
| host package | other | 1 |
| run failed | ok, fail | 1 |
| partial | ok, partial | 1 |
| ran directly | script | 1 |
| script | unpack | 1 |

- **Fixed by the install view:** 10 script failures now install.
- **Fixed by the run view:** 8 programs that failed or ran partly now work.
- The 3 "run failed → ok, none" (`ruby-sentry-sidekiq`, `ruby-money`,
  `wesnoth-1.18-tools`) are a survey limit. Their programs are outside the
  bin directories, so the new survey does not run them.
- **Regressions** (3):
  - `sedsed`: `py3compile` writes `__pycache__` into the host's
    `dist-packages`, which the view has no copy of (the mirror gap, below).
  - `ng-cjk`: `update-alternatives` cannot remove the host's
    `/usr/share/man/da/man1/editor.1.gz` (the same gap).
  - `erlang-odbc`: its dependency `erlang-base` creates a system user through
    `sysusers.d`. That fails properly now. The old model skipped it, but the
    user was never created.

### Per section, in scope

Works = installs and its programs run (or it has none). Out of 3 per section;
skew in parentheses.

| section | works | | section | works | | section | works |
|---|---|---|---|---|---|---|---|
| comm | 1 | | gnu-r | 0 (3) | | perl | 2 |
| debug | 0 (2) | | golang | 3 | | php | 3 |
| devel | 1 (2) | | graphics | 1 (2) | | python | 3 |
| doc | 3 | | hamradio | 3 | | ruby | 3 |
| editors | 1 (1) | | haskell | 3 | | rust | 3 |
| education | 1 (1) | | interpreters | 1 (1) | | science | 1 (2) |
| electronics | 3 | | introspection | 3 | | shells | 2 |
| embedded | 3 | | java | 3 | | sound | 1 |
| fonts | 3 | | javascript | 3 | | tex | 2 (1) |
| games | 3 | | kde | 0 (3) | | text | 2 (1) |
| gnome | 3 | | libdevel | 3 | | utils | 2 |
| lisp | 2 (1) | | libs | 2 (1) | | vcs | 1 (2) |
| localization | 2 (1) | | math | 2 (1) | | video | 2 (1) |
| ocaml | 3 | | web | 1 (1) | | x11 | 2 (1) |
| xfce | 0 (2) | | | | | | |

Every section below 3 without skew fails on one of the classes below.

### Out of scope (36 packages run)

| install | packages |
|---|---|
| ok | 19 |
| skew | 7 |
| script | 6 |
| unpack | 4 |

| section | works | failures |
|---|---|---|
| admin | 1 | `apt-verify` skew; `arpwatch` system user (sysusers.d) |
| cli-mono | 3 | |
| database | 1 | `fis-gtm` setuid helper; `kexi-mysql-driver` skew |
| gnustep | 0 | all 3 skew |
| httpd | 3 | Apache modules install; they are useful only to a host Apache |
| kernel | 0 | 3 × `/boot`, refused at unpack |
| mail | 2 | `biabam` pulls in `exim4-config` (an MTA, debconf `passwords.dat`) |
| metapackages | 2 | `jupyter`: `libdebuginfod-common` and `__pycache__` |
| misc | 1 | `fp-units-castle-game-engine` skew; `libhsm-bin` → `opendnssec-common` system user |
| net | 1 | `fireqos` → `tcpdump` system user (sysusers.d); `ahcpd` has no `--version` (a test artifact) |
| news | 2 | `inn` system user (sysusers.d) |
| oldlibs | 2 | `libclutter-1.0-dev` skew |

Outside the kernel and service packages, these sections do about as well as
the in-scope ones. The scope line is about what a package does, not which
section it is in (see "Admin and net", below).

`libhsm-bin` hung on a debconf prompt in the first run: the survey did not
set `DEBIAN_FRONTEND=noninteractive`. With it set, the package fails on its
system user.

## Failure classes

Each class is placed on the [problem map](problems.md). "Package → deb" names
the dependency whose script failed.

### System users (never)

| package → deb | how |
|---|---|
| `asterisk-mysql` → `asterisk`, `wmbusmeters`, `libhsm-bin` → `opendnssec-common` | `adduser --system`: "Only root may add a user" |
| `erlang-odbc` → `erlang-base`, `arpwatch`, `fireqos` → `tcpdump`, `inn` | `/usr/lib/sysusers.d/*.conf` and `systemd-sysusers` in the postinst (`dh_installsysusers`): "Failed to take /etc/passwd lock" |

`prefix-check` refuses the `adduser` kind. It **misses the sysusers.d kind**,
the more common of the two in new packages. `erlang-base`'s user is only for
`epmd`, and it blocks all of Erlang: this is still an open question.

### Ids the user namespace cannot map (root once)

`xen-utils-common` (`install -g adm /var/log/xen`) and `yash`
(`chown /etc/shells.tmp`): chown or chgrp to an unmapped id fails with
`EINVAL`. Fixes:

- **subid** (root once, [`admin-features.md`](admin-features.md)): the view
  maps the ids;
- **a `chown` shim** on a `DPkg::Path`-only directory (non-root): it drops
  ownership changes to ids the namespace cannot map.

### Mirror gap (non-root)

A script writes into a host directory the prefix has no copy of, and gets
`EACCES` ([`view.md`](view.md#limits-of-an-unprivileged-overlay-and-how-the-view-works-around-them)):

- `sedsed`, `jupyter` (`python3-jupyter-core`):
  `/usr/lib/python3/dist-packages/__pycache__`;
- `ng-cjk`: `/usr/share/man/da/man1`;
- `tuxguitar-jack` → `fluid-soundfont-gm`: `/usr/share/sounds/sf3`.

Fix: also mirror the host's subdirectories under each directory the `.deb`
files ship, and the man page locale directories.

### Moving a root-owned host file (to study)

`mopidy-alsamixer` → `docutils-common`: `update-xmlcatalog` cannot rename
`/etc/xml/catalog` to `catalog.old`. The copy-up of a root-owned file fails
with `EOVERFLOW` ("Value too large").

### Unpack

- `ceilometer-common`: ships `/etc/sudoers.d`;
- `fis-gtm`: a setuid `gtmsecshr` in a `dr-x------` directory;
- 3 kernel `linux-base-*` packages: `/boot`, refused by `prefix-check` ✓.

### Other

- `biabam` → `exim4-config`: debconf cannot open `passwords.dat`. An MTA is
  the admin's.
- `jupyter` → `libdebuginfod-common`: the postinst runs `chmod` on
  `/etc/profile.d/debuginfod.sh`, which is not there.
- `wmbusmeters` also hits "No diversion … usr-is-merged" (exit 54).
- Partial runs are test artifacts. `fai-deps` and
  `mysql_convert_table_format` miss a Recommends (`Graph::Directed`, `DBI`)
  because of `--no-install-recommends`. `fai-kvm` and `ahcpd` have no
  `--version`.

## Gaps in prefix-check

`prefix-check` has 4 rules today. Rules it needs, from the failures above:

| rule | would have refused |
|---|---|
| a file under `usr/lib/sysusers.d/`, or `systemd-sysusers` in a maintainer script | `erlang-base`, `arpwatch`, `tcpdump`, `inn` |
| a file under `etc/sudoers.d/` | `ceilometer-common` |
| a setuid or setgid file mode in the `.deb` | `fis-gtm` |

Also to measure: shipping a system unit, and "every program is in `sbin`"
(see below).

## Admin and net: a limited scope

sid has 1689 packages in `admin` and 2138 in `net`. 200 and 355 of them
depend on `adduser`, `init-system-helpers` or `debconf`. Many are plain user
tools:

- admin: `tmux`, `ncdu`, `gdu`, `borgbackup`, `ansible`, `mmdebstrap`,
  `debootstrap`, `distrobox`, `podman`, `cpulimit`;
- net: `rsync`, `rclone`, `mtr-tiny`, `nmap`, `bmon`.

Others really are the admin's:

- `sudo` (setuid);
- `sysstat` (a service);
- `iotop` and `nvme-cli` (in `sbin`, need root);
- `etckeeper` (manages the host's `/etc`);
- `iftop` and `nethogs` (file capabilities).

**Proposal:** decide by signals read from the `.deb`, not by an allowlist or
by section. A package is the user's unless it:

1. ships a service or creates a system user;
2. has a setuid or setgid file, or file capabilities;
3. has all its programs in `/usr/sbin` (new and cheap);
4. writes host state or diverts host files.

Nothing blocks admin or net packages today: sudo-less does not look at the
section. Before adding these rules to `prefix-check` and changing
`standard.md`'s scope, run an admin and net sample (about 30 each) and
check each signal against what actually happens.

## Next steps

1. `prefix-check`: the sysusers.d, sudoers.d and setuid/setgid rules.
2. The view: mirror subdirectories under shipped directories, and man
   locale directories.
3. Ids: a `chown` shim, or subid.
4. `progvis`: find the `prefix-wrap` miss.
5. `dev/survey.sh`: set `DEBIAN_FRONTEND=noninteractive`; report packages
   already on the host as "host"; also run programs outside the bin
   directories.
6. The admin and net sample, for the proposal above.
