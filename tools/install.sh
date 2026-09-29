#!/usr/bin/env bash
# tools/install.sh — install sudo-less's tools into the prefix, or check them.
#
#   tools/install.sh           install what differs, and say what it changed
#   tools/install.sh --check   only say what differs (exit 1 if anything does)
#
# The one list of what sudo-less puts in the prefix to run: the scripts of
# tools/ (in $PREFIX/lib/sudo-less), the dpkg wrapper in front of each of
# dpkg's programs, the sl-* commands (tools/sl.sh), and the apt hooks that
# call them. apt-dpkg/install.sh
# and scripts/bootstrap/build-dpkg.sh call it; after changing a tool, run
# it. It touches nothing else: not the dpkg database, the apt sources, or
# PATH (apt-dpkg/install.sh does those).
set -eu

: "${PREFIX:=$HOME/.sudo-less}"
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=${HERE%/*}
L=$PREFIX/lib/sudo-less
CHECK=
[ "${1:-}" != --check ] || CHECK=1

# tools/NAME.sh is installed as $L/NAME.
TOOLS='prefix-view prefix-sandbox prefix-integrate prefix-wrap prefix-units prefix-check'
# apt's and dpkg's programs live in $L/bin, off PATH, so `apt` and `dpkg`
# are always the system's; the sl-* commands run them. The builds install
# them in $PREFIX/bin and $PREFIX/sbin, and this moves them (MOVE, below).
# dpkg's programs that run in the install view: the real one is in $L/dpkg
# (build-dpkg.sh moves it there), and $L/bin/NAME is the wrapper.
DPKG_TOOLS='dpkg dpkg-query dpkg-divert dpkg-statoverride dpkg-trigger update-alternatives'
# The sl-* commands: tools/sl.sh, as $PREFIX/bin/sl-NAME.
SL='install remove purge autoremove update upgrade search show list status shell apt dpkg uninstall help'
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

# Moved from $PREFIX/bin and sbin to $L/bin: apt's and dpkg's programs, but
# not a link (not ours) or a launcher prefix-wrap made for a package's
# program of the same name.
for f in "$PREFIX"/bin/* "$PREFIX"/sbin/*; do
  case ${f##*/} in
    apt|apt-*|dpkg|dpkg-*|update-alternatives|start-stop-daemon) ;;
    *) continue ;;
  esac
  [ -f "$f" ] && [ ! -L "$f" ] || continue
  ! grep -qs 'sudo-less view wrapper' "$f" || continue
  differs=1
  r=${f#"$PREFIX"/}
  if [ -n "$CHECK" ]; then echo "on PATH: $r"; continue; fi
  mkdir -p "$L/bin"
  mv -f "$f" "$L/bin/"
  echo "moved: $r -> lib/sudo-less/bin"
done
# dpkg-maintscript-helper finds its data in ../share/dpkg next to itself
# (apt-dpkg/patches/dpkg/0100-maintscript-helper-datadir.patch).
if [ "$(readlink "$L/share" 2>/dev/null)" != ../../share ]; then
  differs=1
  if [ -n "$CHECK" ]; then echo "differs: lib/sudo-less/share"
  else mkdir -p "$L"; ln -sfn ../../share "$L/share"; echo "installed: lib/sudo-less/share"
  fi
fi
for t in $TOOLS; do put "$HERE/$t.sh" "$L/$t" 0755; done
for f in "$HERE"/syscalls/*; do put "$f" "$L/syscalls/${f##*/}" 0644; done
for t in $DPKG_TOOLS; do
  [ -x "$L/dpkg/$t" ] || continue
  put "$REPO/apt-dpkg/dpkg-wrapper.sh" "$L/bin/$t" 0755
done
for c in $SL; do put "$HERE/sl.sh" "$PREFIX/bin/sl-$c" 0755; done
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
