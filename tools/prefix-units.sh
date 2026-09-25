#!/usr/bin/env bash
# prefix-units — run the services the prefix installed under your own
# systemd user manager.
#
#   tools/prefix-units.sh          the packages installed or changed since last time
#   tools/prefix-units.sh --all    every package
#   tools/prefix-units.sh --check UNIT-FILE...   print the translation, change nothing
#
# A package's units are written for the system manager (PID 1, root):
# /usr/lib/systemd/system/*.service runs as User=redis, after
# network.target, wanted by multi-user.target. In the prefix they land in
# $PREFIX/usr/lib/systemd/..., where no manager looks. This translates each
# unit (system or user) into a user unit in $UNITS, a directory the user
# manager reads (systemd.unit(5), "User Unit Search Path"):
#
#   identity   User=, Group=, DynamicUser=, capabilities: dropped, the
#              service runs as you
#   programs   an Exec line whose program needs the view (it has a
#              prefix-wrap script) or names a file in the prefix runs in a
#              service view (prefix-view --service): /usr, /etc, /opt and
#              /var from the prefix, so the service finds its config and
#              keeps its state in /var as on Debian; a program that runs
#              directly gets its $PREFIX path
#   sandbox    for a program in the prefix, directives that give the service
#              its own namespaces (ProtectSystem=, PrivateTmp=, ...) are
#              dropped: they name host paths and hide $HOME. Otherwise
#              kept.
#   paths      /run/X and /var/run/X become %t/X ($XDG_RUNTIME_DIR); paths
#              systemd itself reads (EnvironmentFile=, PIDFile=,
#              Condition*=) get their $PREFIX copy when there is one
#   ordering   targets only the system manager has (network.target,
#              multi-user.target, ...) are dropped from dependencies, and
#              WantedBy= them becomes default.target
#
# A package that ships a user unit of the same name as a system unit (mpd,
# syncthing) gets its user unit only. Drop-in directories (*.service.d) are
# not read.
#
# A unit the package enabled (deb-systemd-helper in the install view leaves
# its symlinks in $PREFIX/etc/systemd) is enabled and started, as Debian
# starts a service on install; one that changed is restarted if running; the
# units of a removed package are stopped, disabled and deleted. Services run
# while you are logged in; to keep them running without a session the admin
# enables linger once (docs/admin-features.md).
#
# The apt hook in apt-dpkg/config/apt.conf.d/04units.in runs this after
# every dpkg run (after prefix-wrap). SUDO_LESS_UNITS=off skips it,
# SUDO_LESS_UNITS=nostart translates and enables but starts nothing.
set -eu

[ "${SUDO_LESS_UNITS:-}" != off ] || exit 0
: "${PREFIX:=$HOME/.local}"
INFO=$PREFIX/var/lib/dpkg/info
DB=$PREFIX/var/lib/sudo-less/units      # per package: the units it got
ENABLED=$PREFIX/var/lib/sudo-less/units-enabled   # a file per unit enabled here
STAMP=$PREFIX/.sudo-less/units.stamp
VIEW=$PREFIX/lib/sudo-less/prefix-view
UNITS=${XDG_DATA_HOME:-$HOME/.local/share}/systemd/user
TAG='# sudo-less user unit (prefix-units); regenerated, do not edit'

# Targets the user manager has (systemd.special(7), "Units managed by the
# user service manager"); any other target is the system manager's.
user_target() {
  case $1 in
    default.target|basic.target|sockets.target|timers.target|paths.target|\
    shutdown.target|exit.target|graphical-session.target|\
    graphical-session-pre.target|xdg-desktop-autostart.target|\
    bluetooth.target|printer.target|smartcard.target|sound.target) return 0 ;;
  esac
  return 1
}

# Directives dropped in every unit: who the service runs as.
IDENTITY=' User Group DynamicUser SupplementaryGroups CapabilityBoundingSet AmbientCapabilities SecureBits PAMName SocketUser SocketGroup '
# Directives dropped when a program of the service is in the prefix: the
# mount namespace they build is made of host paths (ProtectHome= hides the
# prefix itself, ExecPaths= lists /usr/bin/..., ReadWritePaths= /var/lib/...).
SANDBOX=' PrivateTmp PrivateDevices PrivateUsers PrivateMounts PrivateIPC PrivatePIDs PrivateNetwork NetworkNamespacePath IPCNamespacePath ProtectSystem ProtectHome ProtectKernelTunables ProtectKernelModules ProtectKernelLogs ProtectControlGroups ProtectClock ProtectHostname ProtectProc ProcSubset ReadWritePaths ReadOnlyPaths InaccessiblePaths ExecPaths NoExecPaths ReadWriteDirectories ReadOnlyDirectories InaccessibleDirectories TemporaryFileSystem BindPaths BindReadOnlyPaths RootDirectory RootImage MountAPIVFS '
# Dropped too in the service view: they forbid unshare() and mount(), which
# building it needs.
NOSETNS=' RestrictNamespaces SystemCallFilter '
DEPS=' After Before Wants Requires Requisite BindsTo PartOf Upholds Conflicts OnFailure OnSuccess '

in_prefix() { [ -e "$PREFIX$1" ] || [ -L "$PREFIX$1" ]; }

# A path that systemd itself reads, outside any view.
host_path() {
  local flag=${1%%/*} p=/${1#*/}
  case $1 in /*|-/*|!/*|\|/*|!\|/*) ;; *) printf %s "$1"; return ;; esac
  case $p in
    /run/*) p=%t/${p#/run/} ;;
    /var/run/*) p=%t/${p#/var/run/} ;;
    *) ! in_prefix "$p" || p=$PREFIX$p ;;
  esac
  printf %s "$flag$p"
}

# The wrapper prefix-wrap made for program $1, if it made one.
has_wrapper() {
  local w
  case $1 in */sbin/*) w=$PREFIX/sbin/${1##*/} ;; *) w=$PREFIX/bin/${1##*/} ;; esac
  [ -f "$w" ] && grep -q 'sudo-less view wrapper' "$w" 2>/dev/null
}

# Of an Exec line's value: whether its program is in the prefix
# (exec_in_prefix) and whether it must run in the service view (exec_needs_view).
exec_in_prefix() {
  local v=${1#"${1%%[!-@:+!]*}"}
  set -f; set -- $v; set +f
  in_prefix "${1:-/}"
}
exec_needs_view() {
  local v=$1 w prog
  v=${v#"${v%%[!-@:+!]*}"}          # the prefixes - @ : + !
  set -f; set -- $v; set +f
  prog=${1:-}
  if in_prefix "$prog" && has_wrapper "$prog"; then return 0; fi
  for w; do
    case $w in /usr/*|/etc/*|/opt/*) [ ! -f "$PREFIX$w" ] || return 0 ;; esac
  done
  return 1
}

exec_value() {  # the Exec line's value, for $VIEWED
  local v=$1 pre prog out w
  pre=${v%%[!-@:+!]*}
  v=${v#"$pre"}
  pre=${pre//+/}; pre=${pre//!/}    # full privileges mean nothing here
  set -f; set -- $v; set +f
  [ $# -gt 0 ] || { printf %s "$pre"; return; }
  prog=$1; shift
  out=
  for w; do
    case $w in
      /run/*) w=%t/${w#/run/} ;;
      /var/run/*) w=%t/${w#/var/run/} ;;
    esac
    out+=" $w"
  done
  if [ "$VIEWED" = 1 ]; then
    printf '%s%s --service %s%s' "$pre" "$VIEW" "$prog" "$out"
  else
    ! in_prefix "$prog" || prog=$PREFIX$prog
    printf '%s%s%s' "$pre" "$prog" "$out"
  fi
}

# Translate unit file $1 to stdout.
translate() {
  local src=$1 lines=() l cont='' sec='' k v t out
  while IFS= read -r l || [ -n "$l" ]; do
    if [ "${l%\\}" != "$l" ]; then cont+="${l%\\} "; continue; fi
    lines+=("$cont$l"); cont=
  done < "$src"
  VIEWED=0 PREFIXED=0
  for l in "${lines[@]}"; do
    case $l in
      Exec*=*)
        ! exec_in_prefix "${l#*=}" || PREFIXED=1
        ! exec_needs_view "${l#*=}" || VIEWED=1 PREFIXED=1 ;;
    esac
  done
  printf '%s\n# from %s\n' "$TAG" "$src"
  for l in "${lines[@]}"; do
    case $l in
      \[*\]) sec=$l; printf '%s\n' "$l"
        if [ "$sec" = '[Service]' ] && [ $VIEWED = 1 ]; then
          printf 'Environment=PREFIX=%s\n' "$PREFIX"
        fi
        continue ;;
    esac
    case $l in *=*) ;; *) printf '%s\n' "$l"; continue ;; esac
    k=${l%%=*} v=${l#*=}
    k=${k%"${k##*[![:space:]]}"}
    case $k in ''|'#'*|';'*) printf '%s\n' "$l"; continue ;; esac
    case "$IDENTITY" in *" $k "*) continue ;; esac
    if [ $PREFIXED = 1 ]; then
      case "$SANDBOX" in *" $k "*) continue ;; esac
    fi
    if [ $VIEWED = 1 ]; then
      case "$NOSETNS" in *" $k "*) continue ;; esac
    fi
    case $sec:$k in
      \[Unit\]:*)
        if [[ $DEPS == *" $k "* ]]; then
          out=
          for t in $v; do
            case $t in
              *.target) user_target "$t" || continue ;;
              *.mount|*.device|*.swap|*.automount|*.slice) continue ;;
            esac
            out+=" $t"
          done
          [ -z "$out" ] || printf '%s=%s\n' "$k" "${out# }"
          continue
        fi
        case $k in Condition*|Assert*) v=$(host_path "$v") ;; esac ;;
      \[Service\]:Exec*)
        [ -z "$v" ] || v=$(exec_value "$v") ;;
      \[Service\]:PIDFile|\[Service\]:EnvironmentFile|\[Service\]:WorkingDirectory)
        v=$(host_path "$v") ;;
      \[Socket\]:Listen*|\[Path\]:Path*)
        v=$(host_path "$v") ;;
      \[Install\]:WantedBy|\[Install\]:RequiredBy|\[Install\]:UpheldBy)
        out=
        for t in $v; do
          case $t in *.target) user_target "$t" || t=default.target ;; esac
          case " $out " in *" $t "*) ;; *) out+=" $t" ;; esac
        done
        v=${out# } ;;
    esac
    printf '%s=%s\n' "$k" "$v"
  done
}

# The unit files package list $1 put in the prefix, one per line: a user
# unit hides the system unit of the same name.
unit_files() {
  grep -E '^(/usr)?/lib/systemd/(system|user)/[^/]+\.(service|socket|timer|path)$' "$1" 2>/dev/null |
  while IFS= read -r f; do
    [ -f "$PREFIX$f" ] || continue
    case $f in
      */system/*)
        n=${f##*/}
        grep -qE "^(/usr)?/lib/systemd/user/$n\$" "$1" && [ -f "$PREFIX/usr/lib/systemd/user/$n" ] && continue ;;
    esac
    echo "$f"
  done
}

enabled_by_package() {   # the package's postinst enabled unit $1
  [ -n "$(find "$PREFIX/etc/systemd" -type l -name "$1" 2>/dev/null | head -1)" ]
}

if [ "${1:-}" = --check ]; then
  shift
  for f; do translate "$f"; echo; done
  exit 0
fi

ALL=
[ "${1:-}" != --all ] || ALL=1
mkdir -p "$DB" "$ENABLED" "${STAMP%/*}" "$UNITS"
: > "$STAMP.new"
# The user manager, if there is one to tell (not in a container or over su).
USERMGR=
if [ -n "${XDG_RUNTIME_DIR:-}" ] && systemctl --user show-environment >/dev/null 2>&1; then
  USERMGR=1
fi
sc() { [ -z "$USERMGR" ] || systemctl --user "$@" 2>&1 | sed 's/^/prefix-units: /' >&2 || :; }
reload=
start=() restart=()

write_unit() {  # write_unit NAME: stdin to $UNITS/NAME
  local tmp=$UNITS/.$1.new.$$
  if [ -e "$UNITS/$1" ] && ! grep -qxF "$TAG" "$UNITS/$1" 2>/dev/null; then
    echo "prefix-units: $UNITS/$1 is not ours, left alone" >&2; cat >/dev/null; return 1
  fi
  cat > "$tmp"
  if cmp -s "$tmp" "$UNITS/$1"; then rm -f "$tmp"; return 0; fi
  [ ! -e "$UNITS/$1" ] || restart+=("$1")
  mv -f "$tmp" "$UNITS/$1"; reload=1
}

remove_unit() {
  [ -f "$UNITS/$1" ] && grep -qxF "$TAG" "$UNITS/$1" 2>/dev/null || return 0
  sc disable --now "$1"
  rm -f "$UNITS/$1" "$ENABLED/$1"; reload=1
}

# Packages that are gone: stop and remove their units.
for rec in "$DB"/*; do
  [ -f "$rec" ] || continue
  [ ! -f "$INFO/${rec##*/}.list" ] || continue
  while IFS= read -r u; do remove_unit "$u"; done < "$rec"
  rm -f "$rec"
done

for list in "$INFO"/*.list; do
  [ -f "$list" ] || continue
  [ -n "$ALL" ] || [ ! -f "$STAMP" ] || [ "$list" -nt "$STAMP" ] || continue
  pkg=${list##*/}; pkg=${pkg%.list}
  rec=$DB/$pkg made=()
  while IFS= read -r f; do
    n=${f##*/}
    out=$(translate "$PREFIX$f")
    write_unit "$n" <<<"$out" || continue
    made+=("$n")
  done < <(unit_files "$list")
  if [ -f "$rec" ]; then
    while IFS= read -r u; do
      case " ${made[*]-} " in *" $u "*) ;; *) remove_unit "$u" ;; esac
    done < "$rec"
  fi
  if [ ${#made[@]} -gt 0 ]; then printf '%s\n' "${made[@]}" > "$rec"; elif [ -f "$rec" ]; then rm -f "$rec"; fi
done
# Units the package enabled that are not enabled here yet. The postinst
# enables them in dpkg's configure run, which apt may make separately from
# the unpack run that brought the unit files, so every unit is looked at.
for rec in "$DB"/*; do
  [ -f "$rec" ] || continue
  while IFS= read -r u; do
    [ ! -e "$ENABLED/$u" ] && enabled_by_package "$u" || continue
    start+=("$u"); : > "$ENABLED/$u"; reload=1
  done < "$rec"
done
mv -f "$STAMP.new" "$STAMP"

[ -n "$reload" ] || exit 0
sc daemon-reload
if [ ${#start[@]} -gt 0 ]; then
  if [ "${SUDO_LESS_UNITS:-}" = nostart ]; then sc enable "${start[@]}"
  else sc enable --now "${start[@]}"; fi
fi
[ ${#restart[@]} -eq 0 ] || sc try-restart "${restart[@]}"
[ -n "$USERMGR" ] || [ ${#start[@]} -eq 0 ] ||
  echo "prefix-units: no user manager here; enable later with: systemctl --user enable --now ${start[*]}" >&2
