#!/usr/bin/env bash
# Install runtime configuration for the userspace apt/dpkg and seed the dpkg
# database from the system so apt treats already-installed libraries as
# satisfied (and only installs the leaf packages you ask for).
#
# Re-running is safe. Options:
#   --reseed      refresh the seeded status from the system
#   --no-shell    do not touch ~/.bashrc / ~/.profile
source "$(dirname "$0")/common.sh"

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

# apt's gpgv verifier needs a gpgv binary (Debian ships gpgv in its own package)
if ! command -v gpgv >/dev/null; then
  log "note: gpgv not found on PATH; apt-key verification will fail"
  log "      install it, e.g.: extract the 'gpgv' .deb into $PREFIX/bin"
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

# Protect the seeded (system) packages: hold them so apt cannot accidentally
# upgrade/remove them into/from the prefix. Our own installs stay upgradable.
bash "$REPO/scripts/lock-seeded.sh" lock

# Install recipe shims (scripts a recipe's `shim` key requires on PATH ahead
# of the real one; see docs/standard.md).
mkdir -p "$PREFIX/bin"
for s in "$REPO/shims/"*; do
  install -m 0755 "$s" "$PREFIX/bin/$(basename "$s")"
done

# Make installed packages runnable in new shells (unless opted out).
if [ "$SHELL_PATH" = 1 ]; then
  bash "$REPO/scripts/install-shell-path.sh"
  bash "$REPO/scripts/install-session-env.sh"
else
  log "skipping shell PATH setup (--no-shell). Add manually:"
  printf '  export PATH="%s/sbin:%s/bin:%s/usr/bin:$PATH"\n' "$PREFIX" "$PREFIX" "$PREFIX"
fi

log "done."
