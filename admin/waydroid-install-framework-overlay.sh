#!/bin/bash
# waydroid-install-framework-overlay.sh
# Run as the `mobian` admin (the only sudo-capable account):
#     sudo bash ~/sudo-less/admin/waydroid-install-framework-overlay.sh [JAR] [--restart]
#
# Installs a patched services.jar into Waydroid's overlay, where it shadows
# the copy inside the read-only Android image. This is the one privileged step
# of the freeform divide-by-zero fix (docs/waydroid-mesa-debug.md §15); build
# the jar unprivileged with waydroid/patch-services-jar.sh first.
#
# Default JAR: /home/master/waydroid-work-backup/patched-services/services.patched.jar
# Revert:      rm /var/lib/waydroid/overlay/system/framework/services.jar
#              (any existing overlay copy is backed up before overwrite)
#
# --restart also restarts waydroid-container to remount the overlay. The
# desktop user must stop/start their session around it:
#     master:  waydroid session stop
#     root:    systemctl restart waydroid-container
#     master:  waydroid session start
set -euo pipefail

log() { printf '==> %s\n' "$*"; }

SRC=""
RESTART=no
for a in "$@"; do
  case "$a" in
    --restart) RESTART=yes ;;
    *)         SRC=$a ;;
  esac
done
SRC=${SRC:-/home/master/waydroid-work-backup/patched-services/services.patched.jar}
DST=/var/lib/waydroid/overlay/system/framework/services.jar

if [ "$(id -u)" -ne 0 ]; then
  echo "must run as root. Use: sudo bash ~/sudo-less/admin/waydroid-install-framework-overlay.sh" >&2
  exit 1
fi
[ -r "$SRC" ] || { echo "source jar not readable: $SRC" >&2; exit 1; }

install -d -m 755 "$(dirname "$DST")"
if [ -e "$DST" ]; then
  bak="$DST.bak.$(date +%Y%m%d-%H%M%S)"
  cp -a "$DST" "$bak"
  log "backed up existing overlay jar -> $bak"
fi
install -m 644 -o root -g root "$SRC" "$DST"
log "installed $DST"
sha256sum "$DST"

if [ "$RESTART" = yes ]; then
  log "restarting waydroid-container"
  systemctl restart waydroid-container
  log "done — start the session as master: waydroid session start"
fi
