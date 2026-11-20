# TODO

Open work carried over from the sudo-less and dsb trackers on 2026-11-20.

## sudo-less

### View on overlayfs

- Old tracker #34 (bug, parked
  2026-09-24). Inside Docker/Podman the home is on overlayfs, which
  overlayfs refuses as an upper layer, so every view and every dpkg run
  fails. CI works around it with tmpfs prefixes (`.github/workflows/build.yml`).
  To do: fail early in `bootstrap.sh` / `apt-dpkg/install.sh` /
  `prefix-view` on `stat -f -c %T "$PREFIX"` = `overlayfs` with a clear
  message; document it in `docs/view.md` ("What it needs") and
  `docs/problems.md`; a fallback (fuse-overlayfs, tmpfs upper) is probably
  not worth it.

### Prefix orphan files

- Old tracker #39 (bug).
  Files under `$PREFIX/usr|etc|var|opt` that no prefix package owns (left
  by pre-view layouts or an old `--reseed`) hide the host's newer copies,
  e.g. shared libraries. Proposal: a read-only check listing orphans that
  shadow the host (owned = `.list` files of `ii` packages + alternatives),
  repair on request by moving them to a dated backup, report them on
  `--reseed`, and document the rule in `docs/view.md`.

### Admin feature scripts

- Old tracker #37. Split admin setup into per-feature root-once scripts
  (`docs/admin-features.md`, "Layout"): `admin/features/userns.sh` with
  detection, the Ubuntu 24.04+ AppArmor userns restriction (prefer a narrow
  profile), no hardcoded `max_user_namespaces` lowering, an updated final
  message (prefix-view, not prefix-run/bwrap), and `--undo`; then
  `linger.sh`, `ports.sh`, `sockbuf.sh`; `enable-userspace.sh` becomes a thin
  wrapper; a no-root detection side (`sudo-less doctor`); docs updated as
  each lands. Every change under `admin/` needs the admin's confirmation
  before it runs on a real host.

### Survey of services

- Old tracker #36. Sample services by popularity from the Contents
  index, the ~50 most-installed packages shipping a unit (popcon) plus a
  random tail; install, let `prefix-units` start it, check it answers,
  remove; record the first failure class (`docs/problems.md`); report
  counts and popcon-weighted shares in `docs/survey.md`; automate beside
  `dev/survey.sh`. Questions: share of used services that run; how many the
  strict default sandbox breaks; how many the services' own `/run`
  rescues; which root-once grants unlock most.

### Differences from plain apt

- Old tracker #40. A service's CLI does not find its socket under
  `$XDG_RUNTIME_DIR/sudo-less/run` (bind it into the run view). Document that
  services only run while logged in and link to
  [admin feature scripts](#admin-feature-scripts) for linger.
  Version-skew errors read like a broken system (a
  plain message from prefix-check or `sudo-less doctor`); ~0.4 s service
  start cost (measure first); a helper or clear message for sandbox holes
  (`~/.config/sudo-less/sandbox/UNIT`); tell the user at the end of
  bootstrap that a new shell/session is needed. (The "two apts" seam is
  addressed by the `sl-*` commands.)

### Uninstall and prefix directory

- Old tracker #41. The prefix is `~/.sudo-less` and the tree provides
  `sl-uninstall` and `tools/migrate.sh`.
  Left to verify from the issue's checklist: user units living in the
  prefix instead of `~/.local/share/systemd/user` (does the user manager's
  search path follow environment.d?), man pages and bash completion from
  the new prefix, and the admin's `--undo`
  ([admin feature scripts](#admin-feature-scripts)).

### Maintainer-script path rewriting

- Old tracker #42. Try sed-based path rewriting as a fast path before the view
  (enhancement, idea): rewriting literal `/etc`, `/usr`, `/var`, `/opt`
  paths in maintainer scripts between `--unpack` and `--configure`, as the
  Android port does. Only worth it if a survey shows
  most scripts use literal paths; the view stays the correct fallback.

### Bare Debian testing

- Old tracker #22 (partly done, parked
  2026-09-24): CI already builds on a clean `debian:trixie` container and
  smoke-tests as an unprivileged user. Missing: the non-root minimal
  Debian VM layer of the test ladder, and running `dev/survey.sh` there
  instead of on the deployment host.

## dsb

### rootcall

- Old tracker #1. A separate companion that runs fixed,
  predefined root commands (`rootcall NAME`, `NAME` an admin-owned
  executable in `/etc/rootcall/`; the file's permissions are the policy;
  a systemd `Accept=yes` socket instead of setuid; clean environment, no
  caller fds, journal log, timeout). Proposal only; written up in
  [`dsb/docs/rootcall.md`](dsb/docs/rootcall.md), which also places it in
  the `adb shell` model (way in, identity, confinement, privileged
  services acting on the identity's behalf).
