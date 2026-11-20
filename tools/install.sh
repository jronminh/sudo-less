#!/usr/bin/env bash
# tools/install.sh — install sudo-less's tools into the prefix, or check them.
#
#   tools/install.sh           install what differs, and say what it changed
#   tools/install.sh --check   only say what differs (exit 1 if anything does)
#
# The one list of what sudo-less puts in the prefix to run. The prefix's
# root is the tree the view lays over the host (usr, etc, var, opt);
# everything of sudo-less's own is in one folder, $PREFIX/.sl, which no
# view lays anywhere:
#
#   .sl/bin, .sl/sbin   the sl-* commands, and the launchers of programs
#                       that need the view (prefix-wrap); on PATH
#   .sl/lib             the tools of tools/ (prefix-view, ...)
#   .sl/apt             apt: bin/ (off PATH), lib/ (libapt, methods)
#   .sl/dpkg            dpkg: bin/ (off PATH; a wrapper in front of each
#                       program that runs in the install view), real/ (those
#                       programs), share/dpkg (dpkg's data)
#   .sl/config          your settings (~/.config/sudo-less links here)
#   .sl/state           what the tools keep: units, session, view, db
#
# The builds, the release tarballs before 2026-10 and older prefixes have
# apt and dpkg in bin, sbin and lib: this moves them into .sl. Then the
# apt hooks. apt-dpkg/install.sh and scripts/bootstrap/build-dpkg.sh call
# it; after changing a tool, run it. It touches nothing else: not the dpkg
# database, the apt sources, or PATH (apt-dpkg/install.sh does those).
set -eu

: "${PREFIX:=$HOME/.sudo-less}"
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=${HERE%/*}
S=$PREFIX/.sl
CHECK=
[ "${1:-}" != --check ] || CHECK=1

# tools/NAME.sh is installed as $S/lib/NAME.
TOOLS='prefix-view prefix-sandbox prefix-integrate prefix-wrap prefix-units prefix-check'
# dpkg's programs that run in the install view: the real one is in
# $S/dpkg/real (build-dpkg.sh puts it there), $S/dpkg/bin/NAME the wrapper.
DPKG_TOOLS='dpkg dpkg-query dpkg-divert dpkg-statoverride dpkg-trigger update-alternatives'
# The sl-* commands: tools/sl.sh, as $S/bin/sl-NAME.
SL='install remove purge autoremove update upgrade search show list status shell apt dpkg uninstall reseed help'
# apt-dpkg/config/apt.conf.d/NAME.in, with @PREFIX@ filled in.
HOOKS='02integrate 03check'
# What earlier versions installed and nothing uses any more.
OLD='etc/apt/apt.conf.d/01update-desktop-database etc/apt/apt.conf.d/02view-wrappers
  etc/apt/apt.conf.d/04units .sl/state/view/wrappers.stamp .sl/state/units.stamp'

differs=0 moved=
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

move() {  # move SOURCE DIR: into DIR (an older layout)
  [ -e "$1" ] || [ -L "$1" ] || return 0
  differs=1 moved=1
  if [ -n "$CHECK" ]; then echo "older layout: ${1#"$PREFIX"/}"; return 0; fi
  mkdir -p "$2"
  if [ -d "$1" ] && [ ! -L "$1" ] && [ -d "$2/${1##*/}" ]; then
    cp -a "$1/." "$2/${1##*/}/" && rm -rf "$1"
  else
    mv -f "$1" "$2/"
  fi
  echo "moved: ${1#"$PREFIX"/} -> ${2#"$PREFIX"/}"
}

# --- older layouts ------------------------------------------------------------
# The old run view keeps the old paths busy: stop it first.
if [ -z "$CHECK" ] && [ -x "$PREFIX/lib/sudo-less/prefix-view" ]; then
  PREFIX=$PREFIX "$PREFIX/lib/sudo-less/prefix-view" --stop 2>/dev/null || :
fi
# apt's and dpkg's programs from bin, sbin and lib/sudo-less/bin, but not a
# link (not ours) or a launcher prefix-wrap made for a package's program of
# the same name.
for f in "$PREFIX"/bin/* "$PREFIX"/sbin/* "$PREFIX"/lib/sudo-less/bin/*; do
  [ -f "$f" ] && [ ! -L "$f" ] || continue
  ! grep -qs 'sudo-less view wrapper' "$f" || continue
  case ${f##*/} in
    apt|apt-*) move "$f" "$S/apt/bin" ;;
    dpkg|dpkg-*|update-alternatives|start-stop-daemon) move "$f" "$S/dpkg/bin" ;;
  esac
done
for f in "$PREFIX"/lib/libapt-pkg.so* "$PREFIX"/lib/libapt-private.so* "$PREFIX/lib/apt"; do
  move "$f" "$S/apt/lib"
done
for f in "$PREFIX"/lib/sudo-less/dpkg/*; do move "$f" "$S/dpkg/real"; done
move "$PREFIX/share/dpkg" "$S/dpkg/share"
# What the tools kept: the units and the session files move; the rest (the
# view's work folders, scratch) is made again.
for f in units session integrate.stamp; do move "$PREFIX/.sudo-less/$f" "$S/state"; done
if [ -d "$PREFIX/.sudo-less" ]; then
  differs=1 moved=1
  if [ -n "$CHECK" ]; then echo "older layout: .sudo-less"
  else chmod -R u+rwx "$PREFIX/.sudo-less" 2>/dev/null || :; rm -rf "$PREFIX/.sudo-less"
  fi
fi
for f in units units-enabled wrappers; do move "$PREFIX/var/lib/sudo-less/$f" "$S/state/db"; done
[ -z "$(ls -A "$PREFIX/config" 2>/dev/null)" ] || move "$PREFIX/config" "$S"
if [ -z "$CHECK" ]; then
  # the old tools and commands, and the launchers: installed again below,
  # and by prefix-integrate
  rm -rf "$PREFIX/lib/sudo-less"
  for f in "$PREFIX"/bin/* "$PREFIX"/sbin/*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    case ${f##*/} in sl-*) rm -f "$f" ;; *) ! grep -qs 'sudo-less view wrapper' "$f" || rm -f "$f" ;; esac
  done
  rmdir "$PREFIX/config" "$PREFIX/var/lib/sudo-less" "$PREFIX/bin" "$PREFIX/sbin" "$PREFIX/lib" \
    "$PREFIX/share" 2>/dev/null || :
fi

# --- the tools -----------------------------------------------------------------
for t in $TOOLS; do put "$HERE/$t.sh" "$S/lib/$t" 0755; done
for f in "$HERE"/syscalls/*; do put "$f" "$S/lib/syscalls/${f##*/}" 0644; done
for t in $DPKG_TOOLS; do
  [ -x "$S/dpkg/real/$t" ] || continue
  put "$REPO/apt-dpkg/dpkg-wrapper.sh" "$S/dpkg/bin/$t" 0755
done
for c in $SL; do put "$HERE/sl.sh" "$S/bin/sl-$c" 0755; done
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
# After a move the launchers and the units name the old paths: make them
# again (not in a prefix with no packages yet).
if [ -n "$moved" ] && [ -f "$PREFIX/var/lib/dpkg/status" ] && [ -d "$PREFIX/var/lib/dpkg/info" ]; then
  echo "the launchers and units, for the new layout:"
  PREFIX=$PREFIX "$S/lib/prefix-integrate" --all || :
fi
[ $differs = 1 ] || echo "the prefix's tools already match $REPO"
