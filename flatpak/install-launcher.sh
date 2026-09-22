#!/usr/bin/env bash
# flatpak/install-launcher.sh — install a bridged .desktop launcher for a
# Flatpak app, so clicking its icon/taskbar entry goes through
# flatpak/bridge.sh instead of a bare `flatpak run` — the persistence gap
# bridge.sh alone has: it only helps the one launch you invoke it for, and
# every other way of starting the app (icon, taskbar, app switcher) reverts
# to the broken, unbridged path.
#
# Usage:
#   flatpak/install-launcher.sh APPID FAKE=REAL [FAKE=REAL...]
#
# Example:
#   flatpak/install-launcher.sh dev.deedles.Trayscale \
#     /run/tailscale=/run/user/"$(id -u)"/tailscale
#
# What it does: finds the app's own exported .desktop file — owned by
# Flatpak, regenerated on every update, never edited in place — copies
# every field except Exec=, and writes the result to
# ~/.local/share/applications/<APPID>.desktop. That shadows the
# Flatpak-managed one for the same desktop-file ID, because $XDG_DATA_HOME
# (~/.local/share) is searched before Flatpak's own exports dir gets added
# to $XDG_DATA_DIRS — the standard, supported way to override a Flatpak
# app's launcher without touching Flatpak's own files.
#
# See docs/flatpak-bridge.md for the write-up and
# flatpak/fixes/<app-id>.fix for a recorded, verified case.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

[ $# -ge 1 ] || usage 1
case "$1" in
  -h|--help) usage 0 ;;
esac

appid="$1"; shift
[ $# -ge 1 ] || { echo "need at least one FAKE=REAL mapping" >&2; usage 1; }
mappings=("$@")

# Find the app's Flatpak-exported .desktop file — user install first, then
# system install, matching how flatpak itself resolves an app by ID.
src=""
for base in "$HOME/.local/share/flatpak/exports/share/applications" \
            "/var/lib/flatpak/exports/share/applications"; do
  if [ -f "$base/$appid.desktop" ]; then
    src="$base/$appid.desktop"
    break
  fi
done
[ -n "$src" ] || { echo "no exported .desktop found for $appid — is it installed?" >&2; exit 1; }

dest_dir="$HOME/.local/share/applications"
mkdir -p "$dest_dir"
dest="$dest_dir/$appid.desktop"

bridge="$REPO/flatpak/bridge.sh"
newexec="$bridge $appid"
for m in "${mappings[@]}"; do
  newexec+=" $m"
done

# Copy every field as-is; replace only the Exec= line.
awk -v exec="Exec=$newexec" '
  /^Exec=/ { print exec; next }
  { print }
' "$src" > "$dest"
chmod 0644 "$dest"

echo "installed: $dest"
echo "  Exec=$newexec"
command -v desktop-file-validate >/dev/null && desktop-file-validate "$dest"
