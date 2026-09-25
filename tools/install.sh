#!/usr/bin/env bash
# tools/install.sh — install sudo-less's tools into the prefix, or check them.
#
#   tools/install.sh           install what differs, and say what it changed
#   tools/install.sh --check   only say what differs (exit 1 if anything does)
#
# The one list of what sudo-less puts in the prefix to run: the scripts of
# tools/ (in $PREFIX/lib/sudo-less), the dpkg wrapper in front of each of
# dpkg's programs, and the apt hooks that call them. apt-dpkg/install.sh
# and scripts/bootstrap/build-dpkg.sh call it; after changing a tool, run
# it. It touches nothing else: not the dpkg database, the apt sources, or
# PATH (apt-dpkg/install.sh does those).
set -eu

: "${PREFIX:=$HOME/.local}"
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=${HERE%/*}
L=$PREFIX/lib/sudo-less
CHECK=
[ "${1:-}" != --check ] || CHECK=1

# tools/NAME.sh is installed as $L/NAME.
TOOLS='prefix-view prefix-sandbox prefix-integrate prefix-wrap prefix-units prefix-check'
# dpkg's programs that run in the install view: the real one is in $L/dpkg
# (build-dpkg.sh moves it there), and $PREFIX/bin/NAME is the wrapper.
DPKG_TOOLS='dpkg dpkg-query dpkg-divert dpkg-statoverride dpkg-trigger update-alternatives'
# apt-dpkg/config/apt.conf.d/NAME.in, with @PREFIX@ filled in.
HOOKS='02integrate 03check'
# What earlier versions installed and nothing uses any more.
OLD='etc/apt/apt.conf.d/01update-desktop-database etc/apt/apt.conf.d/02view-wrappers
  etc/apt/apt.conf.d/04units .sudo-less/view/wrappers.stamp .sudo-less/units.stamp'

differs=0
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

put() {  # put SOURCE TARGET MODE
  if [ -f "$2" ] && cmp -s "$1" "$2" &&
     [ "$(stat -c %a "$2")" = "${3#0}" ]; then
    return 0
  fi
  differs=1
  if [ -n "$CHECK" ]; then echo "differs: ${2#"$PREFIX"/}"; return 0; fi
  mkdir -p "${2%/*}"
  install -m "$3" "$1" "$2"
  echo "installed: ${2#"$PREFIX"/}"
}

for t in $TOOLS; do put "$HERE/$t.sh" "$L/$t" 0755; done
for f in "$HERE"/syscalls/*; do put "$f" "$L/syscalls/${f##*/}" 0644; done
for t in $DPKG_TOOLS; do
  [ -x "$L/dpkg/$t" ] || continue
  put "$REPO/apt-dpkg/dpkg-wrapper.sh" "$PREFIX/bin/$t" 0755
done
for h in $HOOKS; do
  sed "s|@PREFIX@|$PREFIX|g" "$REPO/apt-dpkg/config/apt.conf.d/$h.in" > "$tmp"
  put "$tmp" "$PREFIX/etc/apt/apt.conf.d/$h" 0644
done
for f in $OLD; do
  [ -e "$PREFIX/$f" ] || [ -L "$PREFIX/$f" ] || continue
  differs=1
  if [ -n "$CHECK" ]; then echo "left over: $f"; continue; fi
  rm -f "$PREFIX/$f"
  echo "removed: $f"
done

if [ -n "$CHECK" ]; then
  [ $differs = 0 ] && echo "the prefix's tools match $REPO"
  exit $differs
fi
[ $differs = 1 ] || echo "the prefix's tools already match $REPO"
