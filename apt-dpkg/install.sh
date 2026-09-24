#!/usr/bin/env bash
# Install runtime configuration for the userspace apt/dpkg and seed the dpkg
# database from the system so apt treats already-installed libraries as
# satisfied (and only installs the leaf packages you ask for).
#
# Called by scripts/setup/install-config.sh; not usually run directly. Re-running
# is safe. Options:
#   --reseed      refresh the seeded status from the system
#   --no-shell    do not touch ~/.bashrc / ~/.profile
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/common.sh"

RESEED=0
SHELL_PATH=1
for arg in "$@"; do
  case "$arg" in
    --reseed)   RESEED=1 ;;
    --no-shell) SHELL_PATH=0 ;;
  esac
done

log "prefix: $PREFIX"

mkdir -p "$PREFIX/etc/apt/sources.list.d" "$PREFIX/etc/apt/apt.conf.d" \
         "$PREFIX/etc/dpkg/dpkg.cfg.d" \
         "$PREFIX/etc/apt/preferences.d" \
         "$PREFIX/var/lib/apt/lists/partial" \
         "$PREFIX/var/cache/apt/archives/partial" \
         "$PREFIX/var/lib/dpkg"/{info,updates,triggers,alternatives} \
         "$PREFIX/var/log/apt"

install -m 0644 "$REPO/config/sources.list"                  "$PREFIX/etc/apt/sources.list"
# generate the dpkg/apt prefix config from the template, so the prefix is not
# hardcoded (see config/apt.conf.d/00local-prefix.in)
sed "s|@PREFIX@|$PREFIX|g" "$REPO/config/apt.conf.d/00local-prefix.in" \
  > "$PREFIX/etc/apt/apt.conf.d/00local-prefix"
chmod 0644 "$PREFIX/etc/apt/apt.conf.d/00local-prefix"
sed "s|@PREFIX@|$PREFIX|g" "$REPO/config/dpkg/dpkg.cfg.in" > "$PREFIX/etc/dpkg/dpkg.cfg"
chmod 0644 "$PREFIX/etc/dpkg/dpkg.cfg"

# refresh the desktop-entry cache after installs so GUI packages' .desktop
# files actually show up in app grids, not just on disk (see
# config/apt.conf.d/01update-desktop-database.in and docs/working-packages.md)
sed "s|@PREFIX@|$PREFIX|g" "$REPO/config/apt.conf.d/01update-desktop-database.in" \
  > "$PREFIX/etc/apt/apt.conf.d/01update-desktop-database"
chmod 0644 "$PREFIX/etc/apt/apt.conf.d/01update-desktop-database"

# Installed programs that need the prefix view get a script that runs them
# in the shared run view, after every dpkg run (config/apt.conf.d/02view-wrappers.in,
# docs/view.md).
sed "s|@PREFIX@|$PREFIX|g" "$REPO/config/apt.conf.d/02view-wrappers.in" \
  > "$PREFIX/etc/apt/apt.conf.d/02view-wrappers"
chmod 0644 "$PREFIX/etc/apt/apt.conf.d/02view-wrappers"
# Packages that need root to install are refused before dpkg runs
# (config/apt.conf.d/03check.in).
sed "s|@PREFIX@|$PREFIX|g" "$REPO/config/apt.conf.d/03check.in" \
  > "$PREFIX/etc/apt/apt.conf.d/03check"
chmod 0644 "$PREFIX/etc/apt/apt.conf.d/03check"
mkdir -p "$PREFIX/lib/sudo-less"
install -m 0755 "$REPO/tools/prefix-view.sh" "$PREFIX/lib/sudo-less/prefix-view"
install -m 0755 "$REPO/tools/prefix-wrap.sh" "$PREFIX/lib/sudo-less/prefix-wrap"
install -m 0755 "$REPO/tools/prefix-check.sh" "$PREFIX/lib/sudo-less/prefix-check"

# apt verifies signatures with the host's sqv (Debian's default verifier)
if ! command -v sqv >/dev/null; then
  log "note: sqv not found on PATH; apt-get update cannot verify signatures"
  log "      install it, e.g.: extract the 'sqv' .deb into $PREFIX"
fi

STATUS="$PREFIX/var/lib/dpkg/status"
if [ "$RESEED" = 1 ] || [ ! -s "$STATUS" ]; then
  log "seeding dpkg status from /var/lib/dpkg/status"
  cp /var/lib/dpkg/status "$STATUS"
  # copy the system's control-file lists so dpkg doesn't warn that seeded
  # packages are "missing the list control file" / md5sums
  cp -n /var/lib/dpkg/info/*.list "$PREFIX/var/lib/dpkg/info/" 2>/dev/null || true
  cp -n /var/lib/dpkg/info/*.md5sums "$PREFIX/var/lib/dpkg/info/" 2>/dev/null || true
  cp -n /var/lib/dpkg/info/*.conffiles "$PREFIX/var/lib/dpkg/info/" 2>/dev/null || true
fi
# In the view the host's /etc/alternatives shows through, so the prefix's
# database starts with the host's alternatives.
cp -n /var/lib/dpkg/alternatives/* "$PREFIX/var/lib/dpkg/alternatives/" 2>/dev/null || true
# dpkg appends to /var/log/dpkg.log, and in the view a host file cannot be
# written in place: the prefix has its own.
mkdir -p "$PREFIX/var/log"
[ -e "$PREFIX/var/log/dpkg.log" ] || : > "$PREFIX/var/log/dpkg.log"

# Protect the seeded (system) packages: hold them so apt cannot accidentally
# upgrade/remove them into/from the prefix. Our own installs stay upgradable.
bash "$REPO/scripts/setup/lock-seeded.sh" lock

# Make installed packages runnable in new shells (unless opted out).
if [ "$SHELL_PATH" = 1 ]; then
  bash "$REPO/scripts/setup/install-shell-path.sh"
  bash "$REPO/scripts/setup/install-session-env.sh"
else
  log "skipping shell PATH setup (--no-shell). Add manually:"
  printf '  export PATH="%s/sbin:%s/bin:%s/usr/bin:$PATH"\n' "$PREFIX" "$PREFIX" "$PREFIX"
fi
