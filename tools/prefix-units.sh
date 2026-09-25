#!/usr/bin/env bash
# prefix-units — run the services the prefix installed under your own
# systemd user manager.
#
#   tools/prefix-units.sh LIST...  the units of these packages (their dpkg
#                                  .list files: prefix-integrate passes the
#                                  changed ones), and those of removed packages
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
#   programs   every Exec line runs in a service view (prefix-view
#              --service): /usr, /etc, /opt and /var from the prefix, and
#              /run the services' own ($XDG_RUNTIME_DIR/sudo-less/run), so
#              the service finds its config and keeps its state and sockets
#              where Debian does, and it all lands in the prefix
#   sandbox    in three stages:
#              1. redirected: directives that name paths or filter
#                 syscalls (ProtectSystem=, ReadWritePaths=,
#                 StateDirectory=, SystemCallFilter=, ...) become
#                 "# sudo-less sandbox:" lines in the unit, which
#                 prefix-sandbox applies on top of the view, where the
#                 paths are the prefix's. The rest (PrivateNetwork=,
#                 ProtectKernelTunables=, ...) stay for systemd, which
#                 builds them around the view.
#              2. supplemented: on Debian a system service runs as a
#                 system user, which cannot touch your files; here it runs
#                 as you. So a system unit gets ProtectSystem=strict,
#                 ProtectHome=yes, PrivateTmp=yes unless it sets them,
#                 with /run and its package's own directories in /var/lib,
#                 /var/cache, /var/log and /var/spool writable.
#              3. secured: the package wrote the unit, so a system unit's
#                 sandbox is checked last and never goes below the floor:
#                 ProtectHome= yes, ProtectSystem= full or strict,
#                 PrivateTmp= yes, NoNewPrivileges= yes; no write access
#                 or bind outside a service's state (not $HOME, your
#                 session, /usr, /etc, the package database); no Exec
#                 outside [Service]. What it changes is noted in the unit.
#              A user unit (meant to run as you) gets no default. Only you
#              loosen a sandbox: ~/.config/sudo-less/sandbox/UNIT
#              (tools/prefix-sandbox.sh).
#   paths      paths systemd itself reads (EnvironmentFile=, PIDFile=,
#              Condition*=) get their $PREFIX copy when there is one, and
#              /run/X is %t/sudo-less/run/X; in a system unit %t, %S, %C,
#              %L and %E are /run, /var/lib, ... as the system manager has
#              them
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
# prefix-integrate runs this after each dpkg run (tools/prefix-integrate.sh).
# SUDO_LESS_UNITS=off skips it, SUDO_LESS_UNITS=nostart translates and
# enables but starts nothing.
set -eu

[ "${SUDO_LESS_UNITS:-}" != off ] || exit 0
: "${PREFIX:=$HOME/.local}"
INFO=$PREFIX/var/lib/dpkg/info
DB=$PREFIX/var/lib/sudo-less/units      # per package: the units it got
ENABLED=$PREFIX/var/lib/sudo-less/units-enabled   # a file per unit enabled here
VIEW=$PREFIX/lib/sudo-less/prefix-view
UNITS=${XDG_DATA_HOME:-$HOME/.local/share}/systemd/user
TAG='# sudo-less user unit (prefix-units); regenerated, do not edit'
SBXMARK='# sudo-less sandbox: '   # a directive for prefix-sandbox (--sandbox-from)

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

# Directives dropped: who the service runs as, and what a non-root service
# cannot have. CapabilityBoundingSet= would drop capabilities the service
# does not have on the host, and it gets them all back inside a user
# namespace of its own; RestrictNamespaces= is what stops that.
IDENTITY=' User Group DynamicUser SupplementaryGroups CapabilityBoundingSet AmbientCapabilities SecureBits PAMName SocketUser SocketGroup '
# Directives prefix-sandbox applies inside the view: systemd would apply
# them to the host's paths under it, or forbid the mount() and unshare() it
# is built with (tools/prefix-sandbox.sh).
TOSANDBOX=' ProtectSystem ProtectHome PrivateTmp ReadWritePaths ReadOnlyPaths InaccessiblePaths ReadWriteDirectories ReadOnlyDirectories InaccessibleDirectories TemporaryFileSystem BindPaths BindReadOnlyPaths StateDirectory CacheDirectory LogsDirectory ConfigurationDirectory SystemCallFilter SystemCallErrorNumber SystemCallArchitectures RestrictNamespaces '
# Directives with no way to keep them (a root of the unit's own, a mount
# option on host paths), and the modes of the directories prefix-sandbox
# makes in /var (they are yours).
NOSANDBOX=' ExecPaths NoExecPaths RootDirectory RootImage MountAPIVFS StateDirectoryMode CacheDirectoryMode LogsDirectoryMode ConfigurationDirectoryMode '
# The default sandbox of a system unit, for what it does not set itself.
DEFAULT_SANDBOX=' ProtectSystem=strict ProtectHome=yes PrivateTmp=yes '
DEPS=' After Before Wants Requires Requisite BindsTo PartOf Upholds Conflicts OnFailure OnSuccess '

in_prefix() { [ -e "$PREFIX$1" ] || [ -L "$PREFIX$1" ]; }

# The services' /run outside the view (tools/prefix-view.sh --service).
RUN=%t/sudo-less/run

# In a system unit, the specifiers the user manager would expand to paths
# under $HOME or $XDG_RUNTIME_DIR, as the system manager does: the view has
# them where Debian does.
system_specifiers() {
  local v=$1
  if [ -n "${system:-}" ]; then
    v=${v//%t//run}; v=${v//%S//var/lib}; v=${v//%C//var/cache}
    v=${v//%L//var/log}; v=${v//%E//etc}
  fi
  printf %s "$v"
}

# A path that systemd itself reads, outside any view: the prefix's copy, or
# the services' /run.
host_path() {
  local flag p
  p=$(system_specifiers "$1")
  flag=${p%%/*} p=/${p#*/}
  case $1 in /*|-/*|!/*|\|/*|!\|/*|%*|-%*) ;; *) printf %s "$1"; return ;; esac
  case $p in
    /run/*) p=$RUN/${p#/run/} ;;
    /var/run/*) p=$RUN/${p#/var/run/} ;;
    *) ! in_prefix "$p" || p=$PREFIX$p ;;
  esac
  printf %s "$flag$p"
}

# A path of a sandbox directive, for prefix-sandbox in the view.
sandbox_path() {
  local f=${1%%[!-+]*} v=${1#"${1%%[!-+]*}"}
  v=$(system_specifiers "$v")
  case $v in /var/run/*) v=/run/${v#/var/run/} ;; esac
  printf %s "$f$v"
}

# Under the default ProtectSystem=strict, the directories the unit's
# package ($PKG_LIST, its dpkg .list) has in /var/lib, /var/cache, /var/log
# and /var/spool stay writable: on Debian its system user owns them.
own_var_dirs() {
  local d
  [ -n "${PKG_LIST:-}" ] || return 0
  while IFS= read -r d; do
    [ -d "$PREFIX$d" ] && [ ! -L "$PREFIX$d" ] && SBX+="ReadWritePaths=-$d"$'\n'
  done < <(grep -E '^/var/(lib|cache|log|spool)/[^/]+$' "$PKG_LIST" 2>/dev/null)
}

# The generated unit's path on an Exec line: systemd unescapes \, and
# expands % and $ there.
exec_path() {
  local p=$1
  case $p in *[!A-Za-z0-9/._@:+\\-]*)
    echo "prefix-units: cannot name $p on an Exec line" >&2; return 1 ;; esac
  printf %s "${p//\\/\\\\}"
}

exec_value() {  # the Exec line's value, in the view with the sandbox $SBX
  local v=$1 pre prog out w
  pre=${v%%[!-@:+!]*}
  v=${v#"$pre"}
  pre=${pre//+/}; pre=${pre//!/}    # full privileges mean nothing here
  set -f; set -- $v; set +f
  [ $# -gt 0 ] || { printf %s "$pre"; return; }
  prog=$1; shift
  # @: the next word is argv[0]; the view runs the program by its path.
  case $pre in *@*) pre=${pre//@/}; [ $# -eq 0 ] || shift ;; esac
  out=
  for w; do out+=" $(system_specifiers "$w")"; done
  # The sandbox is read from the unit file itself (the "# sudo-less
  # sandbox:" lines), not passed here: what the package wrote never goes
  # through systemd's parsing of this line into prefix-view's options.
  # Always, even with no directives: your own settings for the unit
  # (~/.config/sudo-less/sandbox/UNIT) come in there.
  local from
  from=" --sandbox-from=$(exec_path "$OUTUNIT")" || return 1
  printf '%s%s --service%s -- %s%s' "$pre" "$VIEW" "$from" "$prog" "$out"
}

# sandbox_opt KEY VALUE: the directives for prefix-sandbox, one per line on
# $SBX (written to the unit as "# sudo-less sandbox: K=V" lines).
sandbox_opt() {
  local k=$1 v=$2 w
  case $k in
    SystemCallFilter|RestrictNamespaces|SystemCallArchitectures)
      SBX+="$k=$v"$'\n' ;;
    *)
      [ -n "$v" ] || { SBX+="$k="$'\n'; return; }
      set -f
      for w in $v; do SBX+="$k=$(sandbox_path "$w")"$'\n'; done
      set +f ;;
  esac
}

# --- the security stage ---------------------------------------------------
# The package wrote the unit, and the sandbox is there to protect you from
# its service: so whatever the unit says, a system unit's sandbox never
# goes below the floor, the protection a Debian system user has. The
# checks run on the sandbox as translated and supplemented, just before
# the unit is written; what they change is noted in the unit and on
# stderr ($NOTES).

# Paths of sudo-less's own that no service may write: the prefix's package
# database and apt's state.
PROTECTED='/var/lib/dpkg /var/lib/apt /var/cache/apt /var/log/apt /var/lib/sudo-less'

clean_path() {  # an absolute path with no . or .. component
  case $1 in /*) ;; *) return 1 ;; esac
  case /$1/ in */../*|*/./*) return 1 ;; esac
}
# A path a service may be given write access to: its state, not your home,
# your session, the prefix's programs or sudo-less's own state.
writable_ok() {
  local p=${1#[-+]} q
  clean_path "$p" || return 1
  for q in $PROTECTED; do case $p in "$q"|"$q"/*) return 1 ;; esac; done
  case $p in /run/user|/run/user/*) return 1 ;; esac
  case $p in
    /run|/run/*|/tmp/?*|/var/tmp/?*|/srv/?*|/var/www|/var/www/*|/var/mail/?*) return 0 ;;
    /var/lib/?*|/var/cache/?*|/var/log/?*|/var/spool/?*|/var/opt/?*|/var/backups/?*) return 0 ;;
  esac
  return 1
}
# A path a service may have bound elsewhere: not your home or session, nor
# a directory holding them (a bind of / or /run would show them again,
# out of reach of ProtectHome=).
bind_source_ok() {
  local p=${1#[-+]}
  clean_path "$p" || return 1
  case $p in /|/home|/home/*|/root|/root/*|/run|/run/user|/run/user/*) return 1 ;; esac
}
# A name for StateDirectory= and the like: relative, no . or .. component.
dir_name_ok() {
  local n=${1%%:*}
  case $n in ''|/*|*[!A-Za-z0-9._+@/-]*) return 1 ;; esac
  case /$n/ in */../*|*/./*) return 1 ;; esac
}

note() { NOTES+="$1"$'\n'; }

# secure_sandbox: rewrite $SBX for a system unit, to the floor.
secure_sandbox() {
  local out= l k v src dst
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    k=${l%%=*} v=${l#*=}
    case $k in
      ProtectHome)
        case ${v,,} in yes|true|on|1|tmpfs) ;; *)
          note "ProtectHome=$v raised to yes: a service does not see your home"; l=ProtectHome=yes ;; esac ;;
      ProtectSystem)
        case ${v,,} in strict|full) ;; *)
          note "ProtectSystem=$v raised to full: a service does not write /usr or /etc"
          l=ProtectSystem=full ;; esac ;;
      PrivateTmp)
        case ${v,,} in ''|no|false|off|0)
          note "PrivateTmp=$v raised to yes: /tmp holds your session's files"; l=PrivateTmp=yes ;; esac ;;
      ReadWritePaths)
        [ -z "$v" ] || writable_ok "$v" || { note "dropped ReadWritePaths=$v: not a service's state"; continue; } ;;
      BindPaths|BindReadOnlyPaths)
        src=${v%%:*} dst=$src
        case $v in *:*) dst=${v#*:}; dst=${dst%%:*} ;; esac
        if ! bind_source_ok "$src" || ! clean_path "${dst#[-+]}"; then
          note "dropped $k=$v: it would show your home or session"; continue
        fi
        if [ $k = BindPaths ] && { ! writable_ok "$src" || ! writable_ok "$dst"; }; then
          note "dropped $k=$v: not a service's state"; continue
        fi ;;
      StateDirectory|CacheDirectory|LogsDirectory|RuntimeDirectory|ConfigurationDirectory)
        [ -z "$v" ] || dir_name_ok "$v" || { note "dropped $k=$v: not a plain directory name"; continue; } ;;
      TemporaryFileSystem|ReadOnlyPaths|InaccessiblePaths)
        v=${v%%:*}; [ -z "$v" ] || clean_path "${v#[-+]}" || { note "dropped $k=$v: not a clean path"; continue; } ;;
    esac
    out+=$l$'\n'
  done <<<"$SBX"
  SBX=$out
  # The floor itself: what a Debian system user cannot write stays so.
  for v in $PROTECTED; do SBX+="ReadOnlyPaths=-$v"$'\n'; done
}

# Translate unit file $1 to stdout.
translate() {
  local src=$1 lines=() l cont='' sec='' k v t out
  while IFS= read -r l || [ -n "$l" ]; do
    if [ "${l%\\}" != "$l" ]; then cont+="${l%\\} "; continue; fi
    lines+=("$cont$l"); cont=
  done < "$src"
  # The sandbox, from the [Service] section, before the Exec lines use it.
  SBX= sec=
  local set=' ' system=
  case $src in */systemd/system/*) system=1 ;; esac
  for l in "${lines[@]}"; do
    case $l in \[*\]) sec=$l; continue ;; esac
    [ "$sec" = '[Service]' ] || continue
    case $l in *=*) ;; *) continue ;; esac
    k=${l%%=*} v=${l#*=}
    k=${k%"${k##*[![:space:]]}"}; v=${v#"${v%%[![:space:]]*}"}
    case $k in ''|'#'*|';'*|*[[:space:]]*) continue ;; esac   # a comment, not a directive
    set+="$k "
    # RuntimeDirectory= stays for systemd too, which makes it in $RUN.
    case "$TOSANDBOX RuntimeDirectory " in *" $k "*) sandbox_opt "$k" "$v" ;; esac
  done
  NOTES=
  if [ -n "$system" ] && [ "${#lines[@]}" -gt 0 ]; then
    for d in $DEFAULT_SANDBOX; do
      case $set in *" ${d%%=*} "*) ;; *) SBX+="$d"$'\n' ;; esac
    done
    # /run (the services' own, tools/prefix-view.sh) stays writable for
    # pid files, as it is on Debian without ProtectSystem=strict.
    case $set in *" ProtectSystem "*) ;; *) SBX+="ReadWritePaths=/run"$'\n'; own_var_dirs ;; esac
    secure_sandbox
  fi
  printf '%s\n# from %s\n' "$TAG" "$src"
  if [ -n "$NOTES" ]; then
    while IFS= read -r d; do
      [ -z "$d" ] || { printf '# sudo-less security: %s\n' "$d"; echo "prefix-units: ${src##*/}: $d" >&2; }
    done <<<"$NOTES"
  fi
  for l in "${lines[@]}"; do
    case $l in
      \[*\]) sec=$l; printf '%s\n' "$l"
        if [ "$sec" = '[Service]' ]; then
          printf 'Environment=PREFIX=%s\n' "$PREFIX"
          while IFS= read -r d; do
            [ -z "$d" ] || printf '%s%s\n' "$SBXMARK" "$d"
          done <<<"$SBX"
          # Setuid programs of the host (sudo, pkexec) stay out of reach,
          # whatever the unit says (the security stage).
          [ -z "$system" ] || printf 'NoNewPrivileges=yes\n'
        fi
        continue ;;
    esac
    # A line only prefix-units may write: prefix-sandbox reads it.
    case $l in "$SBXMARK"*|"${SBXMARK% }"*) continue ;; esac
    case $l in *=*) ;; *) printf '%s\n' "$l"; continue ;; esac
    k=${l%%=*} v=${l#*=}
    k=${k%"${k##*[![:space:]]}"}
    case $k in ''|'#'*|';'*) printf '%s\n' "$l"; continue ;; esac
    case "$IDENTITY$TOSANDBOX$NOSANDBOX" in *" $k "*) continue ;; esac
    if [ -n "$system" ]; then
      case $k in NoNewPrivileges) continue ;; esac
      # The security stage: a command outside [Service] (a socket's
      # ExecStartPre=) would run outside the view and its sandbox.
      case $sec:$k in \[Service\]:*) ;; *:Exec*)
        printf '# sudo-less security: dropped %s=%s: it would run without the sandbox\n' "$k" "$v"
        echo "prefix-units: ${src##*/}: dropped $k=$v: it would run without the sandbox" >&2
        continue ;; esac
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
      \[Service\]:RuntimeDirectory)   # systemd makes it, and removes it on stop
        out=
        for t in $v; do dir_name_ok "$t" && out+=" sudo-less/run/$t"; done
        [ -n "$out" ] || continue
        v=${out# } ;;
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
    f=/usr${f#/usr}   # /lib is /usr/lib (merged /usr); $PREFIX/lib is sudo-less's
    [ -f "$PREFIX$f" ] || continue
    case $f in
      */system/*)
        n=${f##*/}
        [ -f "$PREFIX/usr/lib/systemd/user/$n" ] && grep -qE "^(/usr)?/lib/systemd/user/$n\$" "$1" && continue ;;
    esac
    echo "$f"
  done
}

enabled_by_package() {   # the package's postinst enabled unit $1
  [ -n "$(find "$PREFIX/etc/systemd" -type l -name "$1" 2>/dev/null | head -1)" ]
}

if [ "${1:-}" = --check ]; then
  shift
  for f; do OUTUNIT=$UNITS/${f##*/} translate "$f"; echo; done
  exit 0
fi

if [ "${1:-}" = --all ]; then set -- "$INFO"/*.list; fi
mkdir -p "$DB" "$ENABLED" "$UNITS"
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

for list; do
  case $list in "$INFO"/*.list) [ -f "$list" ] || continue ;; *) continue ;; esac
  pkg=${list##*/}; pkg=${pkg%.list}
  rec=$DB/$pkg made=()
  while IFS= read -r f; do
    n=${f##*/}
    out=$(PKG_LIST=$list OUTUNIT=$UNITS/$n translate "$PREFIX$f") || continue
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
# enables them in dpkg's configure run, which can come in a later dpkg run
# than the unpack run that brought the unit files (dpkg --unpack by hand,
# or apt with Pre-Depends), so every unit is looked at. The marker keeps a
# unit you disabled from being enabled again.
for rec in "$DB"/*; do
  [ -f "$rec" ] || continue
  while IFS= read -r u; do
    [ ! -e "$ENABLED/$u" ] && enabled_by_package "$u" || continue
    start+=("$u"); : > "$ENABLED/$u"; reload=1
  done < "$rec"
done
[ -n "$reload" ] || exit 0
sc daemon-reload
if [ ${#start[@]} -gt 0 ]; then
  if [ "${SUDO_LESS_UNITS:-}" = nostart ]; then sc enable "${start[@]}"
  else sc enable --now "${start[@]}"; fi
fi
[ ${#restart[@]} -eq 0 ] || sc try-restart "${restart[@]}"
[ -n "$USERMGR" ] || [ ${#start[@]} -eq 0 ] ||
  echo "prefix-units: no user manager here; enable later with: systemctl --user enable --now ${start[*]}" >&2
