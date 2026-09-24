#!/usr/bin/env bash
# prefix-wrap — make each program the prefix installed runnable by its name,
# directly or in the run view.
#
#   tools/prefix-wrap.sh          the packages installed or changed since last time
#   tools/prefix-wrap.sh --all    every package
#   tools/prefix-wrap.sh --check PROG...   print how each would run, change nothing
#
# dpkg installs into the prefix view, so a program lands in $PREFIX/usr/bin
# (on PATH) but may still look for its files at /usr/..., /etc/... or /opt/...
# Such a program gets a small script of the same name in $PREFIX/bin (or
# $PREFIX/sbin), ahead of $PREFIX/usr/bin on PATH, that runs it in the run
# view (prefix-view --run). Every other program runs directly from
# $PREFIX/usr/bin, with no view at all.
#
# A program needs the view when (first match):
#   link      it is a symlink that leaves the prefix (/etc/alternatives/...)
#   shebang   its script interpreter is not on the host
#   interp    its interpreter searches only compiled-in module paths
#             (python, perl, ruby, node, php, lua, tcl, R, guile)
#   libs      ldd cannot find a library (it is in $PREFIX/usr/lib)
#   paths     it names a file or directory under /usr, /etc or /opt that the
#             prefix has its own copy of
# docs/view.md. The apt hook in config/apt.conf.d/02view-wrappers.in runs this
# after every dpkg run. When a package changed it stops the run view, which
# the next --run rebuilds on the new files.
set -eu

: "${PREFIX:=$HOME/.local}"
INFO=$PREFIX/var/lib/dpkg/info
ALTS=$PREFIX/var/lib/dpkg/alternatives
DB=$PREFIX/var/lib/sudo-less/wrappers   # per package (or alternatives=NAME): its scripts
STAMP=$PREFIX/.sudo-less/view/wrappers.stamp
VIEW=$PREFIX/lib/sudo-less/prefix-view
TAG='# sudo-less view wrapper (prefix-wrap); regenerated, do not edit'

# Directories many packages share, which the prefix has files in as soon as
# it has any package there: naming one says nothing about this program.
shared_dir() {
  case $1 in
    /usr/*/*|/etc/*|/opt/*) ;;
    *) return 0 ;;   # /usr, /usr/bin, /usr/share, /etc, /opt
  esac
  case $1 in
    /usr/lib/*-linux-gnu|/usr/local/*|/usr/share/doc|/usr/share/man|\
    /usr/share/info|/usr/share/locale|/usr/share/icons|/usr/share/pixmaps|\
    /usr/share/applications|/usr/share/mime|/usr/share/fonts) return 0 ;;
  esac
  return 1
}

# How the program at absolute path $1 runs: prints "direct" or
# "view REASON EVIDENCE".
classify() {
  local p=$1 f=$PREFIX$1 t head='' interp hit
  if [ -L "$f" ]; then
    t=$(readlink -f -- "$f") || t=
    case $t in
      "$PREFIX"/*) f=$t ;;
      *) echo "view link $(readlink -- "$f")"; return ;;
    esac
  fi
  IFS= read -r -n 128 head < "$f" 2>/dev/null || :
  if [ "${head:0:2}" = '#!' ]; then
    set -- ${head#\#!}
    interp=${1:-}
    [ "$interp" != /usr/bin/env ] || { shift; [ "${1:-}" != -S ] || shift; interp=${1:-}; }
    case $interp in
      /*) [ -x "$interp" ] || { echo "view shebang $interp"; return; } ;;
    esac
    case ${interp##*/} in
      python*|pypy*|perl*|ruby*|node*|php*|lua*|tclsh*|wish*|Rscript|guile*)
        echo "view interp ${interp##*/}"; return ;;
    esac
  elif [ "${head:0:4}" = $'\x7fELF' ]; then
    hit=$(ldd "$f" 2>/dev/null | awk '/not found/ { print $1; exit }')
    [ -z "$hit" ] || { echo "view libs $hit"; return; }
  fi
  hit=$(grep -aoE '/(usr|etc|opt)/[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)*' "$f" 2>/dev/null |
    LC_ALL=C sort -u | while IFS= read -r t; do
      t=${t%/}
      [ "$t" != "$p" ] || continue
      if [ -f "$PREFIX$t" ] ||
         { [ -d "$PREFIX$t" ] && ! shared_dir "$t" &&
           [ -n "$(ls -A "$PREFIX$t" 2>/dev/null)" ]; }; then
        echo "$t"; break
      fi
    done)
  if [ -n "$hit" ]; then echo "view paths $hit"; else echo direct; fi
}

# The script for program $1 (absolute path in the view) goes in $2.
write_wrapper() {
  local tmp
  if [ -e "$2" ] && ! grep -qxF "$TAG" "$2" 2>/dev/null; then
    echo "prefix-wrap: $2 is not ours, left alone" >&2; return 1
  fi
  tmp=$2.new.$$
  printf '#!/bin/sh\n%s\nexec %q --run %q "$@"\n' "$TAG" "$VIEW" "$1" > "$tmp"
  chmod 0755 "$tmp"
  if cmp -s "$tmp" "$2"; then rm -f "$tmp"; else mv -f "$tmp" "$2"; changed=1; fi
}

# Remove script $1 that record $2 made, unless another record has it too (a
# package's own link and an alternative can name one program).
remove_wrapper() {
  if grep -lxF -- "$1" "$DB"/* 2>/dev/null | grep -qvxF -- "$2"; then return; fi
  if [ -f "$1" ] && grep -qxF "$TAG" "$1" 2>/dev/null; then
    rm -f "$1"; changed=1
  fi
}

# The programs on PATH that exist in the prefix, as "FILE:PROGRAM" lines,
# for each file named: a package's .list, or an alternative (its links come
# before the first empty line; they are not in any package's .list).
programs() {
  local f lists=()
  {
    for f; do
      case $f in
        "$ALTS"/*) sed "/^\$/q; s|^|$f:|" "$f" ;;
        *) lists+=("$f") ;;
      esac
    done
    [ ${#lists[@]} -eq 0 ] || grep -H '' /dev/null "${lists[@]}"
  } 2>/dev/null | grep -E ':/(usr/)?(s?bin|games)/[^/]+$' | while IFS= read -r l; do
    f=$PREFIX${l##*:}
    [ -e "$f" ] || [ -L "$f" ] || continue
    [ -d "$f" ] || echo "$l"
  done
}

wrapper_path() {
  case $1 in */sbin/*) echo "$PREFIX/sbin/${1##*/}" ;; *) echo "$PREFIX/bin/${1##*/}" ;; esac
}

if [ "${1:-}" = --check ]; then
  shift
  for p in "$@"; do
    case $p in /*) ;; *) p=/usr/bin/$p ;; esac
    printf '%-24s %s\n' "$p" "$(classify "$p")"
  done
  exit 0
fi

ALL=
[ "${1:-}" != --all ] || ALL=1
mkdir -p "$DB" "${STAMP%/*}" "$PREFIX/bin" "$PREFIX/sbin"
: > "$STAMP.new"
changed=

# Packages that are gone: remove their scripts.
for rec in "$DB"/*; do
  [ -f "$rec" ] || continue
  case ${rec##*/} in
    alternatives=*) [ ! -f "$ALTS/${rec##*=}" ] || continue ;;
    *) [ ! -f "$INFO/${rec##*/}.list" ] || continue ;;
  esac
  while IFS= read -r w; do remove_wrapper "$w" "$rec"; done < "$rec"
  rm -f "$rec"; changed=1
done

lists=()
for list in "$INFO"/*.list "$ALTS"/*; do
  [ -f "$list" ] || continue
  [ -n "$ALL" ] || [ ! -f "$STAMP" ] || [ "$list" -nt "$STAMP" ] || continue
  lists+=("$list")
done
[ ${#lists[@]} -eq 0 ] || changed=1   # the prefix changed under the run view
declare -A progs=()
while IFS= read -r l; do
  progs[${l%:*}]+="${l##*:} "
done < <([ ${#lists[@]} -eq 0 ] || programs "${lists[@]}")

for list in "${lists[@]}"; do
  case $list in
    "$ALTS"/*) pkg=alternatives=${list##*/} ;;
    *) pkg=${list##*/}; pkg=${pkg%.list} ;;
  esac
  rec=$DB/$pkg made=()
  for p in ${progs[$list]-}; do
    set -- $(classify "$p")
    [ "$1" = view ] || continue
    w=$(wrapper_path "$p")
    write_wrapper "$p" "$w" && made+=("$w") || :
  done
  # Scripts from an older version that are no longer needed.
  if [ -f "$rec" ]; then
    while IFS= read -r w; do
      case " ${made[*]-} " in *" $w "*) ;; *) remove_wrapper "$w" "$rec" ;; esac
    done < "$rec"
  fi
  if [ ${#made[@]} -gt 0 ]; then printf '%s\n' "${made[@]}" > "$rec"; elif [ -f "$rec" ]; then rm -f "$rec"; fi
done

mv -f "$STAMP.new" "$STAMP"
if [ -n "$changed" ] && [ -x "$VIEW" ]; then
  PREFIX=$PREFIX "$VIEW" --stop
fi
