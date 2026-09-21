#!/usr/bin/env bash
# Install runtime configuration for the userspace apt/dpkg and seed the dpkg
# database from the system so apt treats already-installed libraries as
# satisfied (and only installs the leaf packages you ask for).
#
# Re-running is safe. Pass --reseed to refresh the seeded status from the system.
source "$(dirname "$0")/common.sh"

RESEED=0
[ "${1:-}" = "--reseed" ] && RESEED=1

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

log "done. Add to PATH:"
printf '  export PATH="%s/sbin:%s/bin:%s/usr/bin:$PATH"\n' "$PREFIX" "$PREFIX" "$PREFIX"
