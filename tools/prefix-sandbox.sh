#!/usr/bin/env bash
# prefix-sandbox — run a command in a systemd-like sandbox, without root.
#
#   tools/prefix-sandbox.sh [-p DIRECTIVE=VALUE]... [--from=FILE] [--check] [--] CMD [ARG...]
#
# --from=FILE also takes the directives on FILE's "# sudo-less sandbox: D=V"
# lines: prefix-units writes a service's sandbox into its user unit that
# way, so that what the package wrote reaches this script as data, never
# through systemd's parsing of an Exec line (issue #38). Then your own
# settings for that unit, from ~/.config/sudo-less/sandbox/UNIT (UNIT is
# FILE's name): "off" on a line turns the sandbox off, any other line is
# one more DIRECTIVE=VALUE. A package cannot write there: the install view
# and the service sandbox hide your home.
#
# The directives are systemd.exec(5)'s, with their meaning there:
#
#   files      ProtectSystem=, ProtectHome=, PrivateTmp=, ReadWritePaths=,
#              ReadOnlyPaths=, InaccessiblePaths=, TemporaryFileSystem=,
#              BindPaths=, BindReadOnlyPaths= (and the old *Directories=)
#   state      StateDirectory=, CacheDirectory=, LogsDirectory=,
#              RuntimeDirectory=, ConfigurationDirectory=: made where Debian
#              puts them (/var/lib/X, /var/cache/X, /var/log/X, /run/X,
#              /etc/X), left writable under
#              ProtectSystem=strict, and named in $STATE_DIRECTORY, ...
#   syscalls   SystemCallFilter=, SystemCallErrorNumber=,
#              SystemCallArchitectures=, RestrictNamespaces=
#
# Why not let systemd do it: a service from the prefix runs in a private
# prefix view (tools/prefix-view.sh), whose /usr, /etc and /var are mounted
# after systemd built the unit's sandbox. systemd's ProtectSystem= would
# protect the host's /usr under them, its ReadWritePaths= would name the
# host's /var/lib, its ProtectHome= hides the prefix before the view can use
# it, and its SystemCallFilter= and RestrictNamespaces= forbid the mount()
# and unshare() the view is built with. So prefix-view calls this last, as
# root of the view's user namespace: the mounts go on top of the view, then
# the command gets your uid back, then the syscall filters are loaded (a
# seccomp BPF program built here, loaded by util-linux's setpriv), then it
# runs. The mounts belong to the
# view's user namespace, which the command is no longer root of: it can
# neither undo them nor, in a namespace of its own, uncover what they hide.
#
# Run on its own it makes a user and mount namespace of its own first.
#
# Without --from, SUDO_LESS_SANDBOX=off in the environment ignores every
# directive; any other value is more DIRECTIVE=VALUE words, applied after
# the -p ones. With --from (a service) the environment is not read: the
# unit, and so its package, sets it (Environment=, EnvironmentFile=).
#
# Directives it cannot give a non-root service are not taken:
# CapabilityBoundingSet= (the service has no capability on the host to
# drop, and a user namespace of its own gives them all back inside it; what
# stops that is RestrictNamespaces=), User=, DynamicUser=.
set -eu

: "${PREFIX:=$HOME/.local}"
SELF=$(readlink -f -- "${BASH_SOURCE[0]}")
SCRATCH=$PREFIX/.sudo-less/sandbox
PATH_CMD=$PATH
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 022

usage() {
  echo "usage: prefix-sandbox [-p DIRECTIVE=VALUE]... [--check] [--] CMD [ARG...]" >&2
  exit 2
}

# --- directives -------------------------------------------------------------
declare -A D=()        # directive -> its values, one per line
KNOWN=' ProtectSystem ProtectHome PrivateTmp ReadWritePaths ReadOnlyPaths InaccessiblePaths ReadWriteDirectories ReadOnlyDirectories InaccessibleDirectories TemporaryFileSystem BindPaths BindReadOnlyPaths StateDirectory CacheDirectory LogsDirectory RuntimeDirectory ConfigurationDirectory SystemCallFilter SystemCallErrorNumber SystemCallArchitectures RestrictNamespaces '

set_directive() {
  local k=${1%%=*} v=${1#*=}
  case $1 in *=*) ;; *) echo "prefix-sandbox: not DIRECTIVE=VALUE: $1" >&2; exit 2 ;; esac
  case $k in
    ReadWriteDirectories) k=ReadWritePaths ;;
    ReadOnlyDirectories) k=ReadOnlyPaths ;;
    InaccessibleDirectories) k=InaccessiblePaths ;;
  esac
  case $KNOWN in
    *" $k "*) ;;
    *) echo "prefix-sandbox: $k= is not supported, ignored" >&2; return 0 ;;
  esac
  case $k in
    ProtectSystem|ProtectHome|PrivateTmp|SystemCallErrorNumber) D[$k]=$v ;;  # the last one wins
    SystemCallFilter|RestrictNamespaces) D[$k]+=$v$'\n' ;;   # each line counts, in order
    *) if [ -z "$v" ]; then D[$k]=; else D[$k]+=$v$'\n'; fi ;;   # lists; empty resets
  esac
}

ROOT= CHECK= FROM= opts=()
while [ $# -gt 0 ]; do
  case $1 in
    -p) [ $# -ge 2 ] || usage; opts+=("$2"); shift 2 ;;
    -p*) opts+=("${1#-p}"); shift ;;
    --property=*) opts+=("${1#*=}"); shift ;;
    --from=*)
      f=${1#*=} FROM=${1#*=}; shift
      [ -f "$f" ] || { echo "prefix-sandbox: no such file: $f" >&2; exit 1; }
      while IFS= read -r l; do
        case $l in "# sudo-less sandbox: "*) opts+=("${l#"# sudo-less sandbox: "}") ;; esac
      done < "$f" ;;
    --check) CHECK=1; shift ;;
    --as-root) [ $# -ge 3 ] || usage; ROOT="$2 $3"; shift 3 ;;   # from prefix-view
    --) shift; break ;;
    -*) usage ;;
    *) break ;;
  esac
done
[ $# -gt 0 ] || [ -n "$CHECK" ] || usage

if [ -n "$FROM" ]; then
  f=${XDG_CONFIG_HOME:-$HOME/.config}/sudo-less/sandbox/${FROM##*/}
  if [ -f "$f" ]; then
    while IFS= read -r l; do
      case $l in
        ''|'#'*) ;;
        off) opts=(); break ;;
        *=*) opts+=("$l") ;;
        *) echo "prefix-sandbox: $f: not DIRECTIVE=VALUE: $l" >&2 ;;
      esac
    done < "$f"
  fi
  given=(${opts[@]+"${opts[@]}"})
else
  given=(${opts[@]+"${opts[@]}"})
  case ${SUDO_LESS_SANDBOX:-} in
    off) opts=() ;;
    '') ;;
    *) set -f; opts+=($SUDO_LESS_SANDBOX); set +f ;;
  esac
fi
for o in ${opts[@]+"${opts[@]}"}; do set_directive "$o"; done

yes() { case ${1,,} in 1|yes|true|on) return 0 ;; esac; return 1; }

# Words of all the values of directive $1 (paths have no spaces in units).
words() { printf '%s' "${D[$1]-}" | tr -s ' \n' '\n\n' | sed '/^$/d'; }

# --- the plan: what to mount, in order --------------------------------------
# Writable holes: paths that stay writable under ProtectSystem=strict and
# visible under ProtectHome=, and bind sources, are opened before anything is
# hidden and mounted back from there (/proc/self/fd/N/...).
HOLES=()     # absolute paths
BINDS=()     # "ro|rw SRC DST"
RO=()        # absolute paths made read-only
HIDE=()      # absolute paths made inaccessible
TMPFS=()     # "PATH OPTIONS"
EMPTY=()     # ProtectHome=yes|tmpfs: paths covered by an empty read-only tmpfs
ENVS=()

state_dir() {  # state_dir DIRECTIVE BASE VAR
  local n list=
  for n in $(words "$1"); do
    n=${n%%:*}; n=$2/${n#/}
    HOLES+=("$n"); list+=${list:+:}$n
  done
  [ -z "$list" ] || ENVS+=("$3=$list")
}
state_dir StateDirectory /var/lib STATE_DIRECTORY
state_dir CacheDirectory /var/cache CACHE_DIRECTORY
state_dir LogsDirectory /var/log LOGS_DIRECTORY
state_dir RuntimeDirectory /run RUNTIME_DIRECTORY
cfg=
for n in $(words ConfigurationDirectory); do cfg+=${cfg:+:}/etc/${n%%:*}; done
[ -z "$cfg" ] || ENVS+=("CONFIGURATION_DIRECTORY=$cfg")
for p in $(words ReadWritePaths); do HOLES+=("$p"); done
# sd_notify() must still reach the manager (Type=notify).
case ${NOTIFY_SOCKET:-} in /*) HOLES+=("?$NOTIFY_SOCKET") ;; esac

case ${D[ProtectSystem]-} in
  '') ;;
  strict)
    for p in /*; do
      [ -d "$p" ] && [ ! -L "$p" ] || continue
      case $p in /dev|/proc|/sys) continue ;; esac
      RO+=("$p")
    done ;;
  full) RO+=(/usr /boot /efi /etc) ;;
  *) ! yes "${D[ProtectSystem]}" || RO+=(/usr /boot /efi) ;;
esac
case ${D[ProtectHome]-} in
  '') ;;
  read-only) RO+=(/home /root /run/user) ;;
  tmpfs) EMPTY+=(/home /root /run/user) ;;
  *) ! yes "${D[ProtectHome]}" || EMPTY+=(/home /root /run/user) ;;
esac
for p in $(words ReadOnlyPaths); do RO+=("$p"); done
for p in $(words InaccessiblePaths); do HIDE+=("$p"); done
for t in $(words TemporaryFileSystem); do
  case $t in *:*) TMPFS+=("${t%%:*} mode=0755,${t#*:}") ;; *) TMPFS+=("$t mode=0755") ;; esac
done
case ${D[PrivateTmp]-} in
  ''|no|false|off|0) ;;
  *) TMPFS+=("/tmp mode=1777" "/var/tmp mode=1777") ;;
esac
for d in BindPaths BindReadOnlyPaths; do
  m=rw; [ $d = BindPaths ] || m=ro
  for b in $(words $d); do
    src=${b%%:*} dst=$src
    case $b in *:*) dst=${b#*:}; dst=${dst%%:*} ;; esac
    BINDS+=("$m $src $dst")
  done
done

SECCOMP=
for k in SystemCallFilter SystemCallErrorNumber SystemCallArchitectures RestrictNamespaces; do
  [ -z "${D[$k]-}" ] || SECCOMP+=$(printf '%s' "${D[$k]}" | sed "s/^/$k=/")$'\n'
done

if [ -n "$CHECK" ]; then
  for p in ${HOLES[@]+"${HOLES[@]}"}; do echo "writable     ${p#\?}"; done
  for p in ${RO[@]+"${RO[@]}"}; do echo "read-only    $p"; done
  for p in ${EMPTY[@]+"${EMPTY[@]}"}; do echo "empty        $p"; done
  for p in ${HIDE[@]+"${HIDE[@]}"}; do echo "inaccessible $p"; done
  for t in ${TMPFS[@]+"${TMPFS[@]}"}; do echo "tmpfs        $t"; done
  for b in ${BINDS[@]+"${BINDS[@]}"}; do echo "bind         $b"; done
  for e in ${ENVS[@]+"${ENVS[@]}"}; do echo "env          $e"; done
  [ -z "$SECCOMP" ] || printf '%s' "$SECCOMP" | sed 's/^/seccomp      /'
  exit 0
fi

# --- syscall filters ----------------------------------------------------------
# A seccomp BPF program for SystemCallFilter=, SystemCallErrorNumber=,
# SystemCallArchitectures= and RestrictNamespaces=, as systemd.exec(5) has
# them, written to stdout for setpriv --seccomp-filter. The syscall numbers
# are tools/syscalls/ARCH (dev/syscall-tables.sh); the groups (@system-service,
# ...) are the host's systemd's.
#
# One BPF instruction: u16 code, u8 jt, u8 jf, u32 k, little-endian.
BPF=()
ins() {
  local b
  printf -v b '\\x%02x' $(($1 & 255)) $(($1 >> 8)) "$2" "$3" \
    $(($4 & 255)) $((($4 >> 8) & 255)) $((($4 >> 16) & 255)) $((($4 >> 24) & 255))
  BPF+=("$b")
}
LD=0x20 JEQ=0x15 JGE=0x35 JSET=0x45 RET=0x06        # BPF_LD|W|ABS, BPF_JMP|..|K, BPF_RET|K
KILL=$((0x80000000)) ALLOW=$((0x7fff0000))            # SECCOMP_RET_KILL_PROCESS, _ALLOW
errno_ret() { echo $((0x50000 | $1)); }               # SECCOMP_RET_ERRNO

# The errno numbers of Linux's generic ABI (x86_64 and aarch64 share them).
declare -A ERRNO=([EPERM]=1 [ENOENT]=2 [ESRCH]=3 [EINTR]=4 [EIO]=5 [ENXIO]=6
  [E2BIG]=7 [ENOEXEC]=8 [EBADF]=9 [ECHILD]=10 [EAGAIN]=11 [ENOMEM]=12
  [EACCES]=13 [EFAULT]=14 [EBUSY]=16 [EEXIST]=17 [EXDEV]=18 [ENODEV]=19
  [ENOTDIR]=20 [EISDIR]=21 [EINVAL]=22 [ENFILE]=23 [EMFILE]=24 [ENOTTY]=25
  [EFBIG]=27 [ENOSPC]=28 [ESPIPE]=29 [EROFS]=30 [EMLINK]=31 [EPIPE]=32
  [EDOM]=33 [ERANGE]=34 [ENOSYS]=38 [EOPNOTSUPP]=95 [EAFNOSUPPORT]=97)
# The return value for errno spec $1 (a name, a number or "kill").
action() {
  case $1 in
    kill) echo $KILL ;;
    *[!0-9]*) [ -n "${ERRNO[$1]-}" ] || { warn "unknown errno $1"; return 1; }
      errno_ret "${ERRNO[$1]}" ;;
    *) errno_ret "$1" ;;
  esac
}

declare -A GROUP=() NR=()
load_groups() {
  local l g=
  while IFS= read -r l; do
    case $l in
      @*) g=$l GROUP[$g]= ;;
      '    #'*|'') ;;
      '    '*) [ -z "$g" ] || GROUP[$g]+="${l# } " ;;
    esac
  done < <(systemd-analyze syscall-filter --no-pager 2>/dev/null)
}
# The syscall names in group or name $1, as the keys of OUT.
declare -A SEEN=() OUT=()
expand() {
  local m
  case $1 in
    @*) [ -z "${SEEN[$1]-}" ] || return 0; SEEN[$1]=1
        [ -n "${GROUP[$1]+x}" ] || { warn "unknown syscall group $1"; return 1; }
        for m in ${GROUP[$1]}; do expand "$m"; done ;;
    *) OUT[$1]=1 ;;
  esac
}

seccomp_filter() {
  local arch audit table l k v inv mode= item n e s nr f default=$KILL
  local -A chosen=()
  arch=$(uname -m)
  case $arch in
    x86_64) audit=$((0xc000003e)) ;;
    aarch64) audit=$((0xc00000b7)) ;;
    *) warn "no syscall filter on $arch"; return 1 ;;
  esac
  setpriv --help 2>/dev/null | grep -q -- --seccomp-filter ||
    { warn "this setpriv cannot load a syscall filter (util-linux 2.40 or later can)"; return 1; }
  table=${SELF%/*}/syscalls/$arch
  [ -f "$table" ] || { warn "$table is missing"; return 1; }
  while read -r n nr; do [ "${n#\#}" = "$n" ] && NR[$n]=$nr; done < "$table"
  load_groups

  # SystemCallFilter=: the first line picks allow- or deny-listing, the next
  # ones add to the set or take out of it; an empty one resets.
  while IFS= read -r l; do
    k=${l%%=*} v=${l#*=}
    [ "$k" = SystemCallFilter ] || continue
    if [ -z "$v" ]; then mode= chosen=(); continue; fi
    inv=; [ "${v#\~}" = "$v" ] || { inv=1; v=${v#\~}; }
    [ -n "$mode" ] || { if [ -n "$inv" ]; then mode=deny; else mode=allow; fi; }
    for item in $v; do
      n=${item%%:*} e=; [ "$n" = "$item" ] || e=${item#*:}
      SEEN=() OUT=()
      expand "$n" || return 1
      for s in "${!OUT[@]}"; do
        if { [ $mode = allow ] && [ -z "$inv" ]; } || { [ $mode = deny ] && [ -n "$inv" ]; }; then
          chosen[$s]=$e
        else
          unset "chosen[$s]"
        fi
      done
    done
  done <<<"$SECCOMP"
  e=$(printf '%s\n' "$SECCOMP" | sed -n 's/^SystemCallErrorNumber=//p' | tail -1)
  [ -z "$e" ] || default=$(action "$e") || return 1
  case $(printf '%s\n' "$SECCOMP" | sed -n 's/^SystemCallArchitectures=//p' | tr '\n' ' ') in
    ''|*native*|*"${arch/_/-}"*|*"$arch"*) ;;
    *) warn "SystemCallArchitectures=: only the native one is allowed" ;;
  esac

  # Other ABIs (i386, x32) are refused: the table is the native one's.
  ins $LD 0 0 4; ins $JEQ 1 0 "$audit"; ins $RET 0 0 $KILL
  ins $LD 0 0 0
  [ "$arch" != x86_64 ] || { ins $JGE 0 1 $((0x40000000)); ins $RET 0 0 $KILL; }

  # RestrictNamespaces=: the namespace types unshare() and clone() may make
  # and setns() may join (their flags, in the low word of arg 0, or arg 1).
  local -A NSF=([cgroup]=0x02000000 [ipc]=0x08000000 [net]=0x40000000
    [mnt]=0x00020000 [pid]=0x20000000 [user]=0x10000000 [uts]=0x04000000
    [time]=0x00000080)
  local allowed=unset blocked=0 t
  while IFS= read -r l; do
    k=${l%%=*} v=${l#*=}
    [ "$k" = RestrictNamespaces ] || continue
    case ${v,,} in
      ''|no|false|off|0) allowed="${!NSF[*]}" ;;
      yes|true|on|1) allowed= ;;
      \~*) [ "$allowed" != unset ] || allowed="${!NSF[*]}"
           for t in ${v#\~}; do allowed=" $allowed "; allowed=${allowed// $t / }; done ;;
      *) [ "$allowed" != unset ] || allowed=
         allowed+=" $v" ;;
    esac
  done <<<"$SECCOMP"
  if [ "$allowed" != unset ]; then
    for t in "${!NSF[@]}"; do
      case " $allowed " in *" $t "*) ;; *) blocked=$((blocked | NSF[$t])) ;; esac
    done
  fi
  if [ $blocked -ne 0 ]; then
    local eperm; eperm=$(errno_ret 1)
    for s in unshare clone; do
      [ -n "${NR[$s]-}" ] || continue
      ins $JEQ 0 4 "${NR[$s]}"; ins $LD 0 0 16
      ins $JSET 0 1 $blocked; ins $RET 0 0 "$eperm"; ins $LD 0 0 0
    done
    if [ -n "${NR[setns]-}" ]; then
      ins $JEQ 0 6 "${NR[setns]}"; ins $LD 0 0 24
      ins $JEQ 0 1 0; ins $RET 0 0 "$eperm"
      ins $JSET 0 1 $blocked; ins $RET 0 0 "$eperm"; ins $LD 0 0 0
    fi
    # clone3() has its flags behind a pointer: ENOSYS, and libc falls back
    # to clone().
    [ -z "${NR[clone3]-}" ] || { ins $JEQ 0 1 "${NR[clone3]}"; ins $RET 0 0 "$(errno_ret 38)"; }
  fi

  case $mode in
    allow)   # @default is always allowed (execve, exit, ...)
      SEEN=() OUT=()
      expand @default
      for s in "${!OUT[@]}"; do chosen[$s]=; done
      for s in "${!chosen[@]}"; do
        [ -n "${NR[$s]-}" ] || continue
        ins $JEQ 0 1 "${NR[$s]}"; ins $RET 0 0 $ALLOW
      done
      ins $RET 0 0 "$default" ;;
    deny)
      for s in "${!chosen[@]}"; do
        [ -n "${NR[$s]-}" ] || continue
        f=$default; [ -z "${chosen[$s]}" ] || f=$(action "${chosen[$s]}") || return 1
        ins $JEQ 0 1 "${NR[$s]}"; ins $RET 0 0 "$f"
      done
      ins $RET 0 0 $ALLOW ;;
    *) ins $RET 0 0 $ALLOW ;;
  esac
  [ ${#BPF[@]} -le 4096 ] || { warn "syscall filter too long"; return 1; }
  local IFS=
  printf "${BPF[*]}"
}

# --- standalone: a user and mount namespace of our own ----------------------
if [ -z "$ROOT" ]; then
  mkdir -p "$SCRATCH"
  export PATH=$PATH_CMD
  exec unshare -Urm --propagation slave "$BASH" "$SELF" --as-root "$(id -u)" "$(id -g)" \
    ${given[@]+"${given[@]/#/--property=}"} -- "$@"
fi

# --- as root of the view's user namespace -----------------------------------
uid=${ROOT% *} gid=${ROOT#* }
cwd=$PWD
cd /
# -n: no /run/mount/utab (it would appear in an empty /run).
mount() { command mount -n "$@"; }
mnt() { mount --no-canonicalize "$@"; }
warn() { echo "prefix-sandbox: $*" >&2; }

# The scratch tmpfs holds the holes, bound there while they are still
# visible, and nodes for InaccessiblePaths=.
mkdir -p "$SCRATCH" 2>/dev/null || :
mount -t tmpfs -o mode=0700 sudo-less-sandbox "$SCRATCH"
mkdir -m 000 "$SCRATCH/none.d"; : > "$SCRATCH/none.f"; chmod 000 "$SCRATCH/none.f"

# Make the state directories (in the view they land in the prefix).
for p in ${HOLES[@]+"${HOLES[@]}"}; do
  case $p in /var/lib/*|/var/cache/*|/var/log/*|/run/*|"$HOME"/?*) mkdir -p "$p" 2>/dev/null || :;; esac
done

# stash PATH: bind it into the scratch now, as $SCRATCH/$n.
n=0
stash() {
  local s=$SCRATCH/$((++n))
  if [ -d "$1" ] && [ ! -L "$1" ]; then mkdir "$s"; else : > "$s"; fi
  mnt --rbind "$1" "$s"
}
declare -A HOLE=() BSRC=()
for p in ${HOLES[@]+"${HOLES[@]}"}; do
  opt=; case $p in \?*|-*) opt=1; p=${p#?} ;; esac
  if [ -e "$p" ]; then ! stash "$p" || HOLE[$p]=$n
  elif [ -z "$opt" ]; then warn "ReadWritePaths=$p: no such file or directory"; fi
done
for b in ${BINDS[@]+"${BINDS[@]}"}; do
  read -r _ src _ <<<"$b"
  opt=; case $src in -*) opt=1; src=${src#-} ;; esac
  if [ -e "$src" ]; then ! stash "$src" || BSRC[$src]=$n
  elif [ -z "$opt" ]; then warn "bind source $src: no such file or directory"; fi
done
exec {sfd}<"$SCRATCH"
S=/proc/self/fd/$sfd
if [ -n "$SECCOMP" ]; then
  seccomp_filter > "$SCRATCH/filter" || exit 1
  exec {bpf}<"$SCRATCH/filter"
fi

ro() {  # make path $1 read-only, with everything under it
  mnt --rbind "$1" "$1" && mount -o remount,bind,ro=recursive "$1"
}
for p in ${RO[@]+"${RO[@]}"}; do
  opt=; case $p in -*) opt=1; p=${p#-} ;; esac; p=${p#+}
  if [ -e "$p" ]; then
    # /boot and /efi may be closed to you: nothing there to protect.
    ro "$p" 2>/dev/null || case $p in /boot|/efi) ;; *) warn "cannot make $p read-only" ;; esac
  elif [ -z "$opt" ] && [ "$p" != /boot ] && [ "$p" != /efi ]; then warn "ReadOnlyPaths=$p: no such file or directory"; fi
done
for p in ${HIDE[@]+"${HIDE[@]}"}; do
  opt=; case $p in -*) opt=1; p=${p#-} ;; esac; p=${p#+}
  if [ -d "$p" ] && [ ! -L "$p" ]; then mnt --bind "$S/none.d" "$p" && mount -o remount,bind,ro "$p"
  elif [ -e "$p" ]; then mnt --bind "$S/none.f" "$p" && mount -o remount,bind,ro "$p"
  elif [ -z "$opt" ]; then warn "InaccessiblePaths=$p: no such file or directory"; fi
done
for t in ${TMPFS[@]+"${TMPFS[@]}"}; do
  p=${t%% *}
  mkdir -p "$p" 2>/dev/null || :
  mount -t tmpfs -o "${t#* }" sudo-less-sandbox "$p" || warn "cannot mount a tmpfs on $p"
done
# on PATH (an existing mount point, or one made on an empty tmpfs) bind the
# stashed $2, read-only if $3 is ro.
put() {
  if [ ! -e "$1" ]; then
    if [ -d "$S/$2" ]; then mkdir -p "$1"; else mkdir -p "${1%/*}" && : > "$1"; fi
  fi 2>/dev/null
  mnt --rbind "$S/$2" "$1" || return 1
  [ "${3:-}" != ro ] || mount -o remount,bind,ro=recursive "$1"
}
for b in ${BINDS[@]+"${BINDS[@]}"}; do
  read -r m src dst <<<"$b"
  src=${src#-}
  [ -n "${BSRC[$src]-}" ] || continue
  put "$dst" "${BSRC[$src]}" "$m" || warn "cannot bind $src on $dst"
done
for p in "${!HOLE[@]}"; do
  [ -n "${HOLE[$p]}" ] || continue
  put "$p" "${HOLE[$p]}" || warn "cannot keep $p writable"
done
# ProtectHome= last, so that a hole (ReadWritePaths=/run) does not bring
# back what it hides; the holes inside what it hides come back on top.
under_empty() {
  local e
  for e in ${EMPTY[@]+"${EMPTY[@]}"}; do case $1 in "$e"/*) return 0 ;; esac; done
  return 1
}
for p in ${EMPTY[@]+"${EMPTY[@]}"}; do
  [ -d "$p" ] && mount -t tmpfs -o mode=0755 sudo-less-sandbox "$p" || :
done
# Holes and binds inside what it hides come back, parents first.
inside_empty() {
  local p b m src dst
  for p in "${!HOLE[@]}"; do
    [ -n "${HOLE[$p]}" ] && under_empty "$p" && printf '%s\t%s\t%s\n' "$p" "${HOLE[$p]}" rw
  done
  for b in ${BINDS[@]+"${BINDS[@]}"}; do
    read -r m src dst <<<"$b"; src=${src#-}
    [ -n "${BSRC[$src]-}" ] && under_empty "$dst" && printf '%s\t%s\t%s\n' "$dst" "${BSRC[$src]}" "$m"
  done
  return 0
}
while IFS=$'\t' read -r p n m; do
  put "$p" "$n" "$m" || warn "cannot keep $p visible"
done < <(inside_empty | LC_ALL=C sort -t $'\t' -k1,1)
# The empty tmpfs got the mount points of the holes; now nothing else.
for p in ${EMPTY[@]+"${EMPTY[@]}"}; do
  [ -d "$p" ] && mount -o remount,bind,ro "$p" 2>/dev/null || :
done
exec {sfd}<&-

for e in ${ENVS[@]+"${ENVS[@]}"}; do export "$e"; done
export PATH=$PATH_CMD
cd "$cwd" 2>/dev/null || cd /

if [ -z "$SECCOMP" ]; then
  exec unshare -U --map-user="$uid" --map-group="$gid" -- "$@"
fi
# The filter file is hidden by now (the scratch is under $HOME); setpriv
# reads it through the descriptor opened before, which the command inherits
# (read-only, the filter itself: nothing to learn from it).
exec unshare -U --map-user="$uid" --map-group="$gid" -- \
  setpriv --no-new-privs --seccomp-filter "/proc/self/fd/$bpf" -- "$@"
