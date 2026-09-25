#!/usr/bin/env bash
# prefix-integrate — after dpkg ran in the prefix, make what it installed
# usable: launchers, programs, services.
#
#   tools/prefix-integrate.sh        the packages changed since last time
#   tools/prefix-integrate.sh --all  every package
#
# It finds the packages (and alternatives) that changed once, by their dpkg
# .list files being newer than its stamp, and hands the same list to each
# step, in order:
#
#   1. the desktop database, so a package's .desktop file shows up in app
#      grids (the host's update-desktop-database; skipped if it has none)
#   2. prefix-wrap: programs that need the run view get a script that runs
#      them in it (docs/view.md)
#   3. prefix-units: the packages' systemd units run as user units
#      (docs/services.md)
#
# A step that fails never fails the dpkg run; the next run tries again.
#
# apt runs it once, after all its dpkg runs (DPkg::Post-Invoke in
# apt-dpkg/config/apt.conf.d/02integrate.in); the dpkg wrapper runs it after
# a dpkg run apt did not make (apt-dpkg/dpkg-wrapper.sh).
set -eu

: "${PREFIX:=$HOME/.local}"
INFO=$PREFIX/var/lib/dpkg/info
ALTS=$PREFIX/var/lib/dpkg/alternatives
STATE=$PREFIX/.sudo-less
STAMP=$STATE/integrate.stamp
HERE=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")

tool() {  # installed as lib/sudo-less/NAME, in the repo as tools/NAME.sh
  if [ -x "$HERE/$1" ]; then echo "$HERE/$1"; else echo "$HERE/$1.sh"; fi
}

mkdir -p "$STATE"
exec 9>>"$STATE/integrate.lock"
flock 9
: > "$STAMP.new"   # before the scan: what changes during this run is seen next time

changed=()
for f in "$INFO"/*.list "$ALTS"/*; do
  [ -f "$f" ] || continue
  [ "${1:-}" = --all ] || [ ! -f "$STAMP" ] || [ "$f" -nt "$STAMP" ] || continue
  changed+=("$f")
done

# dpkg puts .desktop files in $PREFIX/usr/share/applications (on
# XDG_DATA_DIRS, scripts/setup/install-session-env.sh); $PREFIX/share is
# ~/.local/share, the user's own launchers.
if command -v update-desktop-database >/dev/null 2>&1; then
  for d in "$PREFIX/usr/share/applications" "$PREFIX/share/applications"; do
    [ ! -d "$d" ] || update-desktop-database "$d" >/dev/null 2>&1 || :
  done
fi
PREFIX=$PREFIX bash "$(tool prefix-wrap)" ${changed[@]+"${changed[@]}"} ||
  echo "prefix-integrate: prefix-wrap failed" >&2
PREFIX=$PREFIX bash "$(tool prefix-units)" ${changed[@]+"${changed[@]}"} ||
  echo "prefix-integrate: prefix-units failed" >&2

mv -f "$STAMP.new" "$STAMP"
