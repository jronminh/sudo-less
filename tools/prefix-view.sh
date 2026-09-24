#!/usr/bin/env bash
# prefix-view — run a command in the prefix view.
#
#   tools/prefix-view.sh CMD [ARG...]
#
# In the view, $PREFIX/usr, $PREFIX/etc, $PREFIX/var and $PREFIX/opt are
# persistent overlays on /usr, /etc, /var and /opt: the host's files show
# through, and every write lands in the prefix, never on the host.
# /var/lib/dpkg is the prefix's own dpkg database, not merged with the
# host's. Inside the view $PREFIX/usr and /usr (and so on) are the same tree,
# so both spellings of a path agree. The command runs with your own uid.
#
# This is what lets the prefix's dpkg run with root "/" and admin dir
# /var/lib/dpkg, like Debian's, and a package's compiled-in paths resolve
# (docs/view.md). Inside a view (SUDO_LESS_VIEW set) it just runs CMD.
#
# Needs util-linux unshare (>= 2.38, for --map-user), unprivileged user
# namespaces (admin/enable-userspace.sh) and overlayfs (kernel >= 5.11).
set -eu

: "${PREFIX:=$HOME/.local}"
DIRS="usr etc var opt"
STATE=$PREFIX/.sudo-less/view

# An unprivileged overlay cannot copy up a directory owned by root (the copy
# would have to be chowned to a uid outside the namespace), so nothing can be
# created in a host directory the prefix has no copy of. So before entering,
# the prefix gets its own (empty, yours) copy of each host directory that is
# likely to be written to:
#   * those the .deb files listed in PREFIX_VIEW_DEBS (one per line) put
#     files in;
#   * every directory of /etc, /var and /opt, and /usr's first two levels,
#     where maintainer scripts and triggers keep state, configuration and
#     caches (about 1500, redone when the host's package set changes).
# PREFIX_VIEW_MIRROR=full copies every host directory under /usr too.
# need: give the prefix a copy of each host directory on stdin (one absolute
# path per line) and of its parents, with the host's mode (at least u+rwx).
need() {
  local p t m skip=// hs=() ts=()
  awk -F/ '{ p = ""; for (i = 2; i <= NF; i++) if ($i != "") {
               p = p "/" $i; if (!seen[p]++) print p } }' |
  xargs -r -d '\n' realpath -m -- | LC_ALL=C sort -u | {
    while IFS= read -r p; do
      case $p in /var/lib/dpkg|/var/lib/dpkg/*|"$skip"/*) continue ;; esac
      t=$PREFIX$p
      if [ -L "$t" ] || { [ -e "$t" ] && [ ! -d "$t" ]; }; then
        skip=$p   # replaced or deleted (a whiteout) in the prefix
      elif [ ! -e "$t" ] && [ -d "$p" ]; then
        hs+=("$p") ts+=("$t")
      fi
    done
    [ ${#hs[@]} -gt 0 ] || return 0
    # Parents sort first, so they are made first.
    set -- $(stat -c %a -- "${hs[@]}")
    for t in "${ts[@]}"; do
      printf -v m %o $((8#$1 | 8#700)); shift
      mkdir -m "$m" "$t" 2>/dev/null || :
    done
  }
}

# The directories the files of a .deb go in.
deb_dirs() {
  local deb=$PREFIX/bin/dpkg-deb
  [ -x "$deb" ] || deb=dpkg-deb
  "$deb" --fsys-tarfile "$1" | tar -t | sed -n 's|^\./|/|; s|/[^/]*/*$||p'
}

if [ "${1-}" != --inner ]; then
  [ $# -gt 0 ] || { echo "usage: prefix-view CMD [ARG...]" >&2; exit 2; }
  if [ -n "${SUDO_LESS_VIEW:-}" ]; then exec "$@"; fi
  case "$PREFIX" in
    /*) ;;
    *) echo "prefix-view: PREFIX must be an absolute path" >&2; exit 1 ;;
  esac
  case "$PREFIX" in
    *:*|*,*) echo "prefix-view: PREFIX may not contain ':' or ','" >&2; exit 1 ;;
    /usr|/usr/*|/etc|/etc/*|/var|/var/*|/opt|/opt/*)
      echo "prefix-view: PREFIX may not be under /usr, /etc, /var or /opt" >&2; exit 1 ;;
  esac
  for d in $DIRS; do mkdir -p "$PREFIX/$d"; done
  mkdir -p "$PREFIX/var/lib/dpkg" "$STATE/work" "$STATE/tmp"
  stamp=$STATE/mirror.stamp
  stale=
  if [ "${PREFIX_VIEW_MIRROR:-}" = full ] || [ ! -f "$stamp" ] ||
     [ /var/lib/dpkg/status -nt "$stamp" ]; then
    stale=1; : > "$stamp.new"
  fi
  {
    if [ -n "$stale" ]; then
      find /etc /var /opt -xdev -type d 2>/dev/null || :
      if [ "${PREFIX_VIEW_MIRROR:-}" = full ]; then
        find /usr -xdev -type d 2>/dev/null || :
      else
        find /usr -xdev -maxdepth 2 -type d 2>/dev/null || :
        find /usr/share/mime -xdev -type d 2>/dev/null || :
      fi
    fi
    printf '%s\n' "${PREFIX_VIEW_DEBS:-}" | while IFS= read -r f; do
      [ -z "$f" ] || deb_dirs "$f"
    done
  } | need
  [ -z "$stale" ] || mv "$stamp.new" "$stamp"
  unset PREFIX_VIEW_DEBS
  # Workdirs of views that have exited.
  for w in "$STATE"/work/*; do
    [ -d "$w" ] || continue
    kill -0 "${w##*/}" 2>/dev/null && continue
    chmod -R u+rwx "$w" 2>/dev/null; rm -rf "$w"
  done
  export PREFIX SUDO_LESS_VIEW=1
  # $$ stays the command's pid: unshare and the inner script exec.
  exec unshare -Urm --propagation private "$BASH" "$0" --inner "$(id -u)" "$(id -g)" "$PWD" "$@"
fi

# --- inside the new user + mount namespace, as its root ---------------------
shift
uid=$1 gid=$2 cwd=$3
shift 3

W=$STATE/work/$$    # this view's overlay workdirs (same fs as the uppers)
K=$STATE/tmp        # skeletons and host stashes, on a tmpfs gone on exit
mount -t tmpfs -o mode=0700 tmpfs "$K"

# Host mount points (octal escapes left as they are: such paths are skipped).
MNTS=$'\n'
while read -r _ _ _ _ m _; do MNTS+=$m$'\n'; done < /proc/self/mountinfo
is_mnt()   { [[ $MNTS == *$'\n'"$1"$'\n'* ]]; }
has_subm() { [[ $MNTS == *$'\n'"$1"/* ]]; }

# The mounts go to one fstab, run by a single mount -a, and the directories
# they need to one mkdir: much faster than a process each.
FSTAB= MK=()
esc() { E=${1//\\/\\134}; E=${E// /\\040}; E=${E//$'\t'/\\011}; }
fs() { local src; esc "$1"; src=$E; esc "$2"; FSTAB+="$src $E $3 $4 0 0"$'\n'; }

ovl() {  # ovl LOWER VIEWPATH: the prefix's copy of VIEWPATH over LOWER
  local up=$PREFIX$2 wk=$W/${2//\//%}
  [ -d "$up" ] || MK+=("$up")
  MK+=("$wk")
  fs overlay "$2" overlay "lowerdir=$1,upperdir=$up,workdir=$wk,userxattr"
}

# layer VIEWPATH HOSTPATH: overlay the prefix on VIEWPATH. overlayfs refuses a
# lower layer with mounts under it (they are locked in a user namespace), so
# such a directory gets a skeleton of its entries as the lower layer instead,
# and each entry is handled on its own: plain directories get their own
# overlay, mount points are bound from the host, and directories with mounts
# further down recurse. Nothing is mounted yet, so VIEWPATH still shows the
# host; the mounts use a stash of it, bound before VIEWPATH is covered.
layer() {
  local v=$1 h=$2 s e n
  if ! has_subm "$v"; then ovl "$h" "$v"; return; fi
  s=$K/skel$v
  mkdir -p "$s" "$K/host$v"
  fs "$h" "$K/host$v" none rbind
  for e in "$v"/*; do
    n=${e##*/}
    if [ -L "$e" ] || [ ! -d "$e" ]; then
      cp -P --preserve=mode,timestamps "$e" "$s/$n" 2>/dev/null || : > "$s/$n"
    else
      mkdir "$s/$n"
    fi
  done
  ovl "$s" "$v"
  for e in "$v"/*; do
    [ -d "$e" ] && [ ! -L "$e" ] || continue
    n=${e##*/}
    # The prefix replaced or deleted it (a non-directory or a whiteout).
    if [ -e "$PREFIX$v/$n" ] || [ -L "$PREFIX$v/$n" ]; then
      [ -d "$PREFIX$v/$n" ] && [ ! -L "$PREFIX$v/$n" ] || continue
    fi
    if [ "$v/$n" = /var/lib/dpkg ]; then continue
    elif is_mnt "$v/$n"; then fs "$K/host$v/$n" "$v/$n" none rbind
    elif has_subm "$v/$n"; then layer "$v/$n" "$K/host$v/$n"
    else ovl "$K/host$v/$n" "$v/$n"; fi
  done
}

shopt -s nullglob dotglob
for d in $DIRS; do layer "/$d" "/$d"; done
fs "$PREFIX/var/lib/dpkg" /var/lib/dpkg none bind
# $PREFIX/<dir> shows the view too, so both spellings of a path agree.
for d in $DIRS; do fs "/$d" "$PREFIX/$d" none rbind; done
mkdir -p "${MK[@]}"
printf '%s' "$FSTAB" > "$K/fstab"
mount -a -T "$K/fstab"

cd "$cwd" 2>/dev/null || cd /
exec unshare -U --map-user="$uid" --map-group="$gid" -- "$@"
