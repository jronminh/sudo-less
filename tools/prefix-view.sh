#!/usr/bin/env bash
# prefix-view — run a command in a prefix view.
#
#   tools/prefix-view.sh [--install] CMD [ARG...]   in a fresh install view (dpkg)
#   tools/prefix-view.sh --private [-p D=V]... [--] CMD [ARG...]
#                                            in a fresh private view, sandboxed
#   tools/prefix-view.sh --service ...       --private, with the services' /run
#   tools/prefix-view.sh --run CMD [ARG...]  in the shared run view
#   tools/prefix-view.sh --start | --stop    start or stop the run view
#
# In a view the prefix's directories are persistent overlays on the host's:
# the host's files show through, and every write lands in the prefix, never
# on the host. $PREFIX/usr and /usr (and so on) are the same tree inside it,
# so both spellings of a path agree. The command runs with your own uid.
#
# A private view overlays /usr, /etc, /var and /opt, with the prefix's own
# dpkg database on /var/lib/dpkg. Each call builds a fresh one (~0.15 s).
# The -p options are systemd sandbox directives (ProtectSystem=strict, ...),
# which tools/prefix-sandbox.sh applies on top of the view, last.
#
# The install view is a private view with an empty /run
# (-p TemporaryFileSystem=/run): dpkg runs in it with root "/" and admin dir
# /var/lib/dpkg, like Debian's, and its maintainer scripts cannot reach the
# host's services: no system bus, no systemd, so `systemctl daemon-reload`,
# deb-systemd-invoke and pkexec find nothing to ask (and polkit shows no
# password dialog), and debhelper's `[ -d /run/systemd/system ]` guards skip
# their service steps.
#
# The run view overlays /usr, /etc and /opt only: what installed programs
# need to find their files by the paths compiled into them. /var stays the
# host's. It is built once and kept running in the background; --run joins
# it (~0.03 s), starting it first if needed. It is rebuilt after the prefix
# or the host's packages change (prefix-wrap, --stop).
#
# A service from the prefix (tools/prefix-units.sh) runs in a private view
# with its unit's sandbox (--service): it keeps its state in /var/lib,
# /var/log and /var/cache as on Debian, and it all lands in the prefix. Its
# /run is $XDG_RUNTIME_DIR/sudo-less/run, a directory of yours that the
# prefix's services share (as Debian's services share /run), gone at
# reboot: the service writes /run/foo.pid and makes /run/foo/foo.sock where
# Debian has them, and outside the view they are in that directory. What
# the host has in /run (the system bus, resolved's resolv.conf) is bound in
# on top, on an empty file or directory of the same name there. Not an
# overlay: a unix socket made through one cannot be reached from outside
# it. One view per start of each of its commands.
#
# Host mounts made later (a USB stick) show up in a view too: its mounts are
# slaves of the host's. Inside a view (SUDO_LESS_VIEW set) CMD runs directly.
# docs/view.md.
#
# Needs util-linux unshare and nsenter (>= 2.38, for --map-user), unprivileged
# user namespaces (admin/enable-userspace.sh) and overlayfs (kernel >= 5.11).
set -eu

: "${PREFIX:=$HOME/.local}"
STATE=$PREFIX/.sudo-less/view
RUNPID=$STATE/run.pid
MARK=sudo-less-run-view   # the run view's holder: "$MARK infinity"

# An unprivileged overlay cannot copy up a directory owned by root (the copy
# would have to be chowned to a uid outside the namespace), so nothing can be
# created in a host directory the prefix has no copy of. So before entering
# the install view, the prefix gets its own (empty, yours) copy of each host
# directory that is likely to be written to:
#   * those the .deb files listed in PREFIX_VIEW_DEBS (one per line) put
#     files in;
#   * every directory of /etc, /var and /opt, /usr's first two levels and
#     /usr/share/mime, where maintainer scripts and triggers keep state,
#     configuration and caches (about 1500, redone when the host's package
#     set changes).
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

mirror() {
  local stamp=$STATE/mirror.stamp stale=
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
}

is_holder() { [ "$(tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null)" = "$MARK infinity " ]; }

# The run view's holder pid, if it is running and current. It is stopped
# once the host's packages change, so that it shows their current files.
run_pid() {
  local pid
  pid=$(cat "$RUNPID" 2>/dev/null) && [ -n "$pid" ] && is_holder "$pid" ||
    return 1
  if [ /var/lib/dpkg/status -nt "$RUNPID" ]; then
    kill "$pid" 2>/dev/null || :; rm -f "$RUNPID"; return 1
  fi
  echo "$pid"
}

stop_run() {
  local pid
  if pid=$(cat "$RUNPID" 2>/dev/null) && [ -n "$pid" ] && is_holder "$pid"; then
    kill "$pid" 2>/dev/null || :
  fi
  rm -f "$RUNPID"
}

# Start the run view in the background, once (under a lock), and print its
# holder's pid. Processes already in an older run view keep it until they
# exit.
start_run() {
  local pid= i
  exec 9>>"$STATE/run.lock"
  flock 9
  if ! pid=$(run_pid); then
    rm -f "$RUNPID.new"
    setsid "$BASH" "$0" --hold </dev/null >"$STATE/run.log" 2>&1 9>&- &
    pid=
    for i in $(seq 200); do   # up to 10 s
      [ -n "$pid" ] || pid=$(cat "$RUNPID.new" 2>/dev/null) || :
      if [ -n "$pid" ] && is_holder "$pid"; then break; fi
      if ! kill -0 $! 2>/dev/null && ! { [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }; then
        echo "prefix-view: the run view did not start (see $STATE/run.log);" \
          "it needs unprivileged user namespaces (admin/enable-userspace.sh)" >&2
        return 1
      fi
      sleep 0.05
    done
    is_holder "$pid" || { echo "prefix-view: the run view did not start in time" >&2; return 1; }
    mv "$RUNPID.new" "$RUNPID"
  fi
  exec 9>&-
  echo "$pid"
}

if [ "${1-}" != --inner ]; then
  mode=install SANDBOX=() RUNDIR=
  case ${1-} in
    --install) shift ;;
    --run) mode=run; shift ;;
    --private) mode=private; shift ;;
    --service) mode=private; shift
      [ -z "${XDG_RUNTIME_DIR:-}" ] || [ ! -d "$XDG_RUNTIME_DIR" ] || RUNDIR=$XDG_RUNTIME_DIR ;;
    --start|--stop|--hold) mode=${1#--}; shift ;;
  esac
  if [ $mode = private ]; then
    while [ $# -gt 0 ]; do
      case $1 in
        -p) [ $# -ge 2 ] || break; SANDBOX+=("--property=$2"); shift 2 ;;
        --) shift; break ;;
        *) break ;;
      esac
    done
  fi
  case $mode in
    install|run|private) [ $# -gt 0 ] || {
      echo "usage: prefix-view [--install | --private [-p D=V]... [--] | --run] CMD [ARG...] | --start | --stop" >&2; exit 2; } ;;
  esac
  case $mode:${SUDO_LESS_VIEW:-} in
    *:) ;;
    install:private|run:*) exec "$@" ;;
    private:private)
      [ ${#SANDBOX[@]} -eq 0 ] && [ -z "${SUDO_LESS_SANDBOX:-}" ] || exec "${BASH_SOURCE[0]%/*}/prefix-sandbox" "${SANDBOX[@]}" -- "$@"
      exec "$@" ;;
    stop:*) ;;
    *) echo "prefix-view: already in the run view; run this from outside it" >&2
       exit 1 ;;
  esac
  if [ $mode = install ]; then
    # Not a sandbox the user may turn off (SUDO_LESS_SANDBOX=off).
    mode=private SANDBOX=(--property=TemporaryFileSystem=/run)
    unset SUDO_LESS_SANDBOX NOTIFY_SOCKET
  fi
  case "$PREFIX" in
    /*) ;;
    *) echo "prefix-view: PREFIX must be an absolute path" >&2; exit 1 ;;
  esac
  case "$PREFIX" in
    *:*|*,*) echo "prefix-view: PREFIX may not contain ':' or ','" >&2; exit 1 ;;
    /usr|/usr/*|/etc|/etc/*|/var|/var/*|/opt|/opt/*)
      echo "prefix-view: PREFIX may not be under /usr, /etc, /var or /opt" >&2; exit 1 ;;
  esac
  mkdir -p "$STATE/work" "$STATE/tmp"
  case $mode in
    stop) stop_run; exit 0 ;;
    start) start_run >/dev/null; exit 0 ;;
    run)
      pid=$(run_pid) || pid=$(start_run)
      export PREFIX SUDO_LESS_VIEW=run
      exec nsenter -t "$pid" -U -m --preserve-credentials --wd="$PWD" -- "$@" ;;
    hold)
      echo $$ > "$RUNPID.new"
      cd /   # keep no directory busy (a USB stick could not be unmounted)
      set -- "$BASH" -c "exec -a $MARK sleep infinity"
      view=run DIRS="usr etc opt" ;;
    private)
      view=private DIRS="usr etc var opt"
      mkdir -p "$PREFIX/var/lib/dpkg"
      mirror
      if [ -n "$RUNDIR" ]; then
        mkdir -p "$RUNDIR/sudo-less/run"
      fi ;;
  esac
  unset PREFIX_VIEW_DEBS
  for d in $DIRS; do mkdir -p "$PREFIX/$d"; done
  # Workdirs of views that have exited.
  for w in "$STATE"/work/*; do
    [ -d "$w" ] || continue
    kill -0 "${w##*/}" 2>/dev/null && continue
    chmod -R u+rwx "$w" 2>/dev/null; rm -rf "$w"
  done
  export PREFIX SUDO_LESS_VIEW=$view
  # $$ stays the command's pid: unshare and the inner script exec. The view's
  # mounts are slaves of the host's, so host mounts made later show up.
  exec unshare -Urm --propagation slave "$BASH" "$0" --inner "$DIRS" "$RUNDIR" \
    "$(id -u)" "$(id -g)" "$PWD" ${#SANDBOX[@]} ${SANDBOX[@]+"${SANDBOX[@]}"} "$@"
fi

# --- inside the new user + mount namespace, as its root ---------------------
shift
DIRS=$1 RUNDIR=$2 uid=$3 gid=$4 cwd=$5
shift 5
SANDBOX=("${@:2:$1}")
shift $(($1 + 1))

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
  local v=$1 h=$2 s e n files=()
  if ! has_subm "$v"; then ovl "$h" "$v"; return; fi
  s=$K/skel$v
  mkdir -p "$s" "$K/host$v"
  fs "$h" "$K/host$v" none rbind
  for e in "$v"/*; do
    if [ -L "$e" ] || [ ! -d "$e" ]; then files+=("$e"); else MK+=("$s/${e##*/}"); fi
  done
  if [ ${#files[@]} -gt 0 ]; then
    cp -P --preserve=mode,timestamps -t "$s" -- "${files[@]}" 2>/dev/null || :
    for e in "${files[@]}"; do
      n=$s/${e##*/}
      [ -e "$n" ] || [ -L "$n" ] || : > "$n"
    done
  fi
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
if [ -n "$RUNDIR" ]; then
  R=$RUNDIR/sudo-less/run
  fs /run "$K/host/run" none rbind
  MK+=("$K/host/run")
  fs "$R" /run none bind
  for e in /run/*; do
    n=${e##*/}
    if [ -L "$e" ]; then
      [ -L "$R/$n" ] || cp -P "$e" "$R/$n" 2>/dev/null || :
      continue
    elif [ -d "$e" ]; then
      [ -d "$R/$n" ] && [ ! -L "$R/$n" ] || { rm -f "$R/$n"; mkdir "$R/$n"; } || continue
    else
      [ -f "$R/$n" ] && [ ! -L "$R/$n" ] || { rm -rf "$R/$n"; : > "$R/$n"; } || continue
    fi
    fs "$K/host/run/$n" "/run/$n" none rbind
  done
fi
case " $DIRS " in
  *" var "*) fs "$PREFIX/var/lib/dpkg" /var/lib/dpkg none bind ;;
esac
# $PREFIX/<dir> shows the view too, so both spellings of a path agree.
for d in $DIRS; do [ $d = run ] || fs "/$d" "$PREFIX/$d" none rbind; done
mkdir -p "${MK[@]}"
printf '%s' "$FSTAB" > "$K/fstab"
mount -a -T "$K/fstab"

cd "$cwd" 2>/dev/null || cd /
if [ ${#SANDBOX[@]} -gt 0 ] || { [ -n "${SUDO_LESS_SANDBOX:-}" ] && [ "$SUDO_LESS_SANDBOX" != off ]; }; then
  sbx=${0%/*}/prefix-sandbox
  [ -f "$sbx" ] || sbx=$sbx.sh   # run from the repo
  exec "$BASH" "$sbx" --as-root "$uid" "$gid" "${SANDBOX[@]}" -- "$@"
fi
exec unshare -U --map-user="$uid" --map-group="$gid" -- "$@"
