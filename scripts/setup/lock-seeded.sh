#!/usr/bin/env bash
# Lock (or unlock) the *seeded* packages in the userspace dpkg database.
#
#   ./scripts/setup/lock-seeded.sh [lock|unlock|status]
#
# The dpkg database is seeded from the system, so apt sees system libraries as
# installed. Without a lock, `apt upgrade` / `apt remove` would try to
# upgrade/remove those *system* packages into/from the prefix. We mark only the
# packages that also exist in the system db as "hold", so apt leaves them alone
# while packages you actually install into the prefix stay upgradable.
#
# Names are matched ignoring the ":arch" qualifier (dpkg --get-selections emits
# "libc6:amd64", the status file says "Package: libc6").
set -euo pipefail
source "$(dirname "$0")/../common.sh"

DPKG="$PREFIX/bin/dpkg"
ADMINDIR="$PREFIX/var/lib/dpkg"
SYS_STATUS="/var/lib/dpkg/status"
[ -f "$ADMINDIR/status" ] || die "no dpkg database at $ADMINDIR (run scripts/setup/install-config.sh)"

MODE="${1:-lock}"
case "$MODE" in lock|unlock|status) ;; *) die "usage: $0 [lock|unlock|status]" ;; esac

declare -A SEEDED=()
while read -r p; do SEEDED["${p%%:*}"]=1; done < <(sed -n 's/^Package: //p' "$SYS_STATUS")

if [ "$MODE" != status ]; then
  want="hold"; [ "$MODE" = unlock ] && want="install"
  "$DPKG" --admindir="$ADMINDIR" --get-selections | while read -r name state; do
    if [[ "${SEEDED[${name%%:*}]:-0}" == 1 ]]; then
      echo "$name $want"
    fi
  done | "$DPKG" --admindir="$ADMINDIR" --set-selections
fi

held=$("$DPKG" --admindir="$ADMINDIR" --get-selections | awk '$2=="hold"' | wc -l)
installed=$("$DPKG" --admindir="$ADMINDIR" --get-selections | awk '$2=="install"' | wc -l)
printf 'held (seeded/system): %s\n' "$held"
printf 'install (upgradable):  %s\n' "$installed"
