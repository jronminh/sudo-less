#!/usr/bin/env bash
# prefix-sandbox — run a command in a systemd-like sandbox, without root.
#
#   tools/prefix-sandbox.sh [-p DIRECTIVE=VALUE]... [--check] [--] CMD [ARG...]
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
# the command gets your uid back, then the syscall filters are loaded (with
# libseccomp, through python3), then it runs. The mounts belong to the
# view's user namespace, which the command is no longer root of: it can
# neither undo them nor, in a namespace of its own, uncover what they hide.
#
# Run on its own it makes a user and mount namespace of its own first.
#
# SUDO_LESS_SANDBOX=off in the environment ignores every directive (a
# drop-in's Environment= can set it for one service); any other value is
# more DIRECTIVE=VALUE words, applied after the -p ones.
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

ROOT= CHECK= opts=()
while [ $# -gt 0 ]; do
  case $1 in
    -p) [ $# -ge 2 ] || usage; opts+=("$2"); shift 2 ;;
    -p*) opts+=("${1#-p}"); shift ;;
    --property=*) opts+=("${1#*=}"); shift ;;
    --check) CHECK=1; shift ;;
    --as-root) [ $# -ge 3 ] || usage; ROOT="$2 $3"; shift 3 ;;   # from prefix-view
    --) shift; break ;;
    -*) usage ;;
    *) break ;;
  esac
done
[ $# -gt 0 ] || [ -n "$CHECK" ] || usage

given=(${opts[@]+"${opts[@]}"})
case ${SUDO_LESS_SANDBOX:-} in
  off) opts=() ;;
  '') ;;
  *) set -f; opts+=($SUDO_LESS_SANDBOX); set +f ;;
esac
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
  case $p in /var/lib/*|/var/cache/*|/var/log/*|/run/*) mkdir -p "$p" 2>/dev/null || :;; esac
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
for p in "${!HOLE[@]}"; do
  [ -n "${HOLE[$p]}" ] && under_empty "$p" || continue
  put "$p" "${HOLE[$p]}" || warn "cannot keep $p visible"
done
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
export SUDO_LESS_SECCOMP=$SECCOMP
exec unshare -U --map-user="$uid" --map-group="$gid" -- /usr/bin/python3 -c '
# Load the syscall filters and exec argv: systemd.exec(5) SystemCallFilter=,
# SystemCallErrorNumber=, SystemCallArchitectures=, RestrictNamespaces=.
import ctypes, errno, os, platform, subprocess, sys
C = ctypes
lib = C.CDLL("libseccomp.so.2", use_errno=True)
lib.seccomp_init.restype = C.c_void_p
lib.seccomp_init.argtypes = [C.c_uint32]
lib.seccomp_rule_add_array.argtypes = [C.c_void_p, C.c_uint32, C.c_int, C.c_uint, C.c_void_p]
lib.seccomp_syscall_resolve_name.argtypes = [C.c_char_p]
lib.seccomp_arch_resolve_name.argtypes = [C.c_char_p]
lib.seccomp_arch_resolve_name.restype = C.c_uint32
lib.seccomp_arch_add.argtypes = [C.c_void_p, C.c_uint32]
lib.seccomp_load.argtypes = [C.c_void_p]

class Cmp(C.Structure):
    _fields_ = [("arg", C.c_uint), ("op", C.c_int), ("a", C.c_uint64), ("b", C.c_uint64)]
MASKED_EQ, EQ = 7, 4
ALLOW, KILL = 0x7FFF0000, 0x80000000
def ERRNO(e): return 0x00050000 | (e & 0xFFFF)
def fail(m): sys.exit("prefix-sandbox: " + m)

conf = {}
for l in os.environ.pop("SUDO_LESS_SECCOMP", "").splitlines():
    k, _, v = l.partition("=")
    conf.setdefault(k, []).append(v.strip())

def errnum(s):
    if s.isdigit(): return int(s)
    if s == "kill": return None
    return getattr(errno, s, None) or fail("unknown errno " + s)

def ctx(default):
    c = lib.seccomp_init(default)
    if not c: fail("seccomp_init failed")
    arches = conf.get("SystemCallArchitectures", [])
    names = " ".join(arches).split()
    if not names:   # no restriction: the other ABIs of this machine too
        names = {"x86_64": ["x86", "x32"], "aarch64": ["arm"]}.get(platform.machine(), [])
    alias = {"x86-64": "x86_64", "arm64": "aarch64"}
    for a in names:
        if a == "native": continue
        n = lib.seccomp_arch_resolve_name(alias.get(a, a).encode())
        if n: lib.seccomp_arch_add(c, n)
    return c

def rule(c, action, name, *cmps):
    nr = lib.seccomp_syscall_resolve_name(name.encode())
    if nr < 0: return
    arr = (Cmp * max(len(cmps), 1))(*[Cmp(*x) for x in cmps])
    lib.seccomp_rule_add_array(c, action, nr, len(cmps), arr)

filters = []

# SystemCallFilter=: the first line sets allow- or deny-listing, later lines
# add to the set or take out of it; "" resets.
lines = conf.get("SystemCallFilter", [])
if lines:
    groups, cur = {}, None
    out = subprocess.run(["systemd-analyze", "syscall-filter", "--no-pager"],
                         capture_output=True, text=True).stdout
    for l in out.splitlines():
        if l.startswith("@"): cur = groups.setdefault(l.strip(), [])
        elif l.strip() and not l.strip().startswith("#") and cur is not None: cur.append(l.strip())
    def expand(n, seen=None):
        seen = seen or set()
        if not n.startswith("@"): return {n}
        if n in seen: return set()
        seen.add(n)
        if n not in groups: fail("unknown syscall group " + n)
        r = set()
        for m in groups[n]: r |= expand(m, seen)
        return r
    allow, chosen = None, {}
    for v in lines:
        if v == "": allow, chosen = None, {}; continue
        inv = v.startswith("~")
        if inv: v = v[1:]
        if allow is None: allow = not inv
        for item in v.split():
            n, _, e = item.partition(":")
            for s in expand(n):
                if allow != inv: chosen[s] = e
                else: chosen.pop(s, None)
    e = conf.get("SystemCallErrorNumber", [""])[-1]
    default = KILL if not e or errnum(e) is None else ERRNO(errnum(e))
    if allow:
        c = ctx(default)
        for s in set(chosen) | expand("@default"): rule(c, ALLOW, s)
    else:
        c = ctx(ALLOW)
        for s, e in chosen.items():
            rule(c, KILL if (e and errnum(e) is None) else ERRNO(errnum(e)) if e else default, s)
    filters.append(c)

# RestrictNamespaces=: which namespace types unshare(), clone() and setns()
# may still make or join.
FLAGS = {"cgroup": 0x02000000, "ipc": 0x08000000, "net": 0x40000000, "mnt": 0x00020000,
         "pid": 0x20000000, "user": 0x10000000, "uts": 0x04000000, "time": 0x00000080}
allowed = None
for v in conf.get("RestrictNamespaces", []):
    if v.lower() in ("", "no", "false", "off", "0"): allowed = set(FLAGS)
    elif v.lower() in ("yes", "true", "on", "1"): allowed = set()
    elif v.startswith("~"): allowed = (set(FLAGS) if allowed is None else allowed) - set(v[1:].split())
    else: allowed = (set() if allowed is None else allowed) | set(v.split())
blocked = set(FLAGS) - (set(FLAGS) if allowed is None else allowed)
if blocked:
    c = ctx(ALLOW)
    eperm = ERRNO(errno.EPERM)
    for t in blocked:
        f = FLAGS[t]
        rule(c, eperm, "unshare", (0, MASKED_EQ, f, f))
        rule(c, eperm, "clone", (0, MASKED_EQ, f, f))
        rule(c, eperm, "setns", (1, MASKED_EQ, f, f))
    rule(c, eperm, "setns", (1, EQ, 0, 0))
    rule(c, ERRNO(errno.ENOSYS), "clone3")   # its flags are behind a pointer; libc falls back to clone()
    filters.append(c)

if filters:
    if C.CDLL(None, use_errno=True).prctl(38, 1, 0, 0, 0) != 0:   # PR_SET_NO_NEW_PRIVS
        fail("cannot set no_new_privs")
    for c in filters:
        r = lib.seccomp_load(c)
        if r != 0: fail("seccomp_load: " + os.strerror(-r))
argv = sys.argv[1:]
try:
    os.execvp(argv[0], argv)
except OSError as e:
    fail("%s: %s" % (argv[0], e.strerror))
' "$@"
