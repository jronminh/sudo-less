#!/usr/bin/env bash
# prefix-run — run a command with the userspace prefix presented at "/", so
# absolute paths compiled into a package (/etc/..., /usr/share/...) resolve to
# the copies under $PREFIX instead of the host's.
#
#   tools/prefix-run.sh [--mode MODE] [--gui] [--print] [--explain] CMD [ARG...]
#
# Relocating a .deb does not rewrite paths baked into its binaries, so a package
# that reads /etc or /usr/share by absolute path will not see the copies under
# $PREFIX. This wraps the command so the prefix is overlaid (or made the root),
# whichever of the tiers below is available. See docs/paths.md.
#
# Modes (auto = first available):
#   overlay  bwrap overlay of $PREFIX/{usr,etc} on the host's /usr,/etc.
#            Needs bwrap + unprivileged userns + overlayfs (kernel >= 5.11).
#   overlay-native
#            the same overlay with no bwrap: unshare -Urm + mount -t overlay,
#            i.e. util-linux + the kernel only; a nested userns then maps you
#            back to your own uid (needs util-linux >= 2.38 for --map-user).
#            Unprivileged userns is enabled once by admin/native/enable-userspace.sh.
#   rootfs   run inside a complete rootfs ($ROOTFS, from scripts/env/make-buildroot.sh) as
#            "/", as namespace root — via bwrap, else rootfs-native, else proot -R.
#   rootfs-native
#            the same with no third-party runner: unshare -Urm + bind mounts +
#            chroot (util-linux + coreutils only). A userspace runner: no mode
#            here runs as real root.
#   env      no namespaces: export LD_LIBRARY_PATH/XDG_DATA_DIRS/PATH, exec.
#
#   --gui      for GUI apps: refuse clearly if no display/session is
#              detected (DISPLAY or WAYLAND_DISPLAY), incompatible with
#              --mode env, and explicitly binds/forwards the session
#              ($XDG_RUNTIME_DIR — Wayland + PipeWire/Pulse sockets — plus
#              DISPLAY/WAYLAND_DISPLAY/XDG_RUNTIME_DIR and Java's
#              _JAVA_AWT_WM_NONREPARENTING). overlay modes already see the
#              session anyway (the whole host / stays visible), so --gui
#              mainly matters for rootfs mode, which otherwise wouldn't.
#   --print    print the command that would run, and exit
#   --explain  say which mode was chosen and why (to stderr)
set -euo pipefail
source "$(dirname "$0")/../scripts/common.sh"

MODE=auto PRINT=0 EXPLAIN=0 GUI=0
ROOTFS="${ROOTFS:-$HOME/buildroot}"

usage() { sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -m|--mode)    MODE="${2:?--mode needs a value}"; shift 2 ;;
    -g|--gui)     GUI=1; shift ;;
    -p|--print)   PRINT=1; shift ;;
    -e|--explain) EXPLAIN=1; shift ;;
    -h|--help)    usage 0 ;;
    --)           shift; break ;;
    -*)           die "unknown option: $1" ;;
    *)            break ;;
  esac
done
[ $# -gt 0 ] || usage 2

# A session to pass through: DISPLAY with its X11 socket, or WAYLAND_DISPLAY
# with its socket under $XDG_RUNTIME_DIR (which also carries PipeWire/Pulse).
session_ok() {
  if [ -n "${DISPLAY:-}" ] && [ -S "/tmp/.X11-unix/X${DISPLAY#:}" ]; then
    return 0
  fi
  if [ -n "${WAYLAND_DISPLAY:-}" ] && [ -n "${XDG_RUNTIME_DIR:-}" ] \
     && [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]; then
    return 0
  fi
  return 1
}
if [ "$GUI" -eq 1 ]; then
  session_ok || die "no display/session detected (need DISPLAY+X11 socket, or WAYLAND_DISPLAY+\$XDG_RUNTIME_DIR socket) — --gui needs a live desktop session"
fi

# --- capability probes -------------------------------------------------------
have()      { command -v "$1" >/dev/null 2>&1; }
userns_ok() { unshare -Ur true >/dev/null 2>&1; }
rootfs_ok() { [ -x "$ROOTFS/bin/sh" ]; }
bwrap_ok()  { have bwrap && bwrap --ro-bind / / true >/dev/null 2>&1; }
proot_ok()  { have proot && proot -R / true >/dev/null 2>&1; }
# /usr/sbin is off a non-root PATH on Debian
CHROOT="$(PATH="$PATH:/usr/sbin:/sbin" command -v chroot || true)"
native_rootfs_ok() {
  [ "$(id -u)" -ne 0 ] && [ -n "$CHROOT" ] && have unshare || return 1
  unshare -Urm --propagation private "$CHROOT" / true >/dev/null 2>&1
}
# Inside a rootfs, only the rootfs's own tools: the host PATH would put
# ~/.local/bin (the userspace dpkg, apt, ...) ahead of the rootfs's.
ROOTFS_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# The environment a rootfs command starts from: an allowlist, not the host's.
# LD_PRELOAD, LD_LIBRARY_PATH, the host PATH and the like would otherwise act
# on the host-side runner and then leak into the rootfs. The runner itself is
# started through `env -i` with this list, by absolute path.
ROOTFS_ENV_KEEP="HOME USER LOGNAME TERM COLORTERM NO_COLOR LANG LANGUAGE TZ"
ROOTFS_GUI_KEEP="DISPLAY WAYLAND_DISPLAY XDG_RUNTIME_DIR XAUTHORITY DBUS_SESSION_BUS_ADDRESS"
rootfs_env() {
  local v keep="$ROOTFS_ENV_KEEP"
  if [ "$GUI" -eq 1 ]; then keep="$keep $ROOTFS_GUI_KEEP"; fi
  ENVV=(PATH="$ROOTFS_PATH")
  for v in $keep $(compgen -e | grep '^LC_' || true); do
    if [ -n "${!v+x}" ]; then ENVV+=("$v=${!v}"); fi
  done
  if [ "$GUI" -eq 1 ]; then ENVV+=(_JAVA_AWT_WM_NONREPARENTING=1); fi
}

# The rootfs runner: bwrap, else the native one, else proot.
rootfs_runner() {
  if bwrap_ok; then printf 'bwrap'
  elif native_rootfs_ok; then printf 'native'
  elif proot_ok; then printf 'proot'
  else return 1; fi
}

# A live probe: overlayfs usable from an unprivileged user namespace. bwrap's
# --overlay-src/--tmp-overlay need >= 0.9.0; the kernel needs >= 5.11.
overlay_ok() {
  have bwrap || return 1
  userns_ok  || return 1
  bwrap --ro-bind / / --overlay-src /usr --tmp-overlay /usr true >/dev/null 2>&1
}

# The same, with no bwrap: a throwaway overlay (lowerdir /usr) mounted in an
# unprivileged user + mount namespace, and --map-user for the nested userns
# that hands the command back its own uid. A userspace runner: not as root.
native_overlay_ok() {
  [ "$(id -u)" -ne 0 ] || return 1
  have unshare || return 1
  unshare --help 2>/dev/null | grep -q -- --map-user || return 1
  unshare -Urm --propagation private sh -c 'd=$(mktemp -d) && mount -t tmpfs tmpfs "$d" &&
    mkdir "$d/u" "$d/w" "$d/m" &&
    mount -t overlay overlay -o "lowerdir=/usr,upperdir=$d/u,workdir=$d/w" "$d/m"' \
    >/dev/null 2>&1
}

# overlayfs splits lowerdir on ':' and options on ','; and a layer may not be
# an ancestor of the mount point.
native_prefix_ok() {
  case "$PREFIX" in
    *:*|*,*)     die "overlay-native: PREFIX may not contain ':' or ',' ($PREFIX)" ;;
    /usr|/usr/*|/etc|/etc/*) die "overlay-native: PREFIX may not be under /usr or /etc ($PREFIX)" ;;
  esac
}

pick_mode() {
  case "$MODE" in
    auto)
      if [ -d "$PREFIX/usr" ] && overlay_ok; then printf 'overlay'
      elif [ -d "$PREFIX/usr" ] && native_overlay_ok; then printf 'overlay-native'
      elif [ "$(id -u)" -ne 0 ] && rootfs_ok && RUNNER="$(rootfs_runner)"; then
        if [ "$RUNNER" = native ]; then printf 'rootfs-native'; else printf 'rootfs'; fi
      else printf 'env'; fi ;;
    overlay) [ -d "$PREFIX/usr" ] || die "overlay mode needs $PREFIX/usr (install a package first)"; overlay_ok || die "overlay unavailable: need bwrap + userns + overlayfs (kernel >= 5.11)"; printf 'overlay' ;;
    overlay-native) [ -d "$PREFIX/usr" ] || die "overlay-native mode needs $PREFIX/usr (install a package first)"; [ "$(id -u)" -ne 0 ] || die "overlay-native is a userspace runner; run it as the unprivileged user, not root"; native_overlay_ok || die "overlay-native unavailable: need unshare (util-linux >= 2.38) + unprivileged userns (admin/native/enable-userspace.sh) + overlayfs (kernel >= 5.11)"; printf 'overlay-native' ;;
    rootfs|rootfs-native)
      [ "$(id -u)" -ne 0 ] || die "$MODE is a userspace runner; run it as the unprivileged user, not root"
      rootfs_ok || die "no rootfs at $ROOTFS (run scripts/env/make-buildroot.sh)"
      if [ "$MODE" = rootfs-native ]; then
        native_rootfs_ok || die "rootfs-native unavailable: need unshare + chroot + unprivileged userns (admin/native/enable-userspace.sh)"
      else
        rootfs_runner >/dev/null || die "rootfs mode needs a runner: bwrap, unshare + chroot (unprivileged userns), or proot"
      fi
      printf '%s' "$MODE" ;;
    env)     printf 'env' ;;
    *)       die "unknown mode: $MODE (auto|overlay|overlay-native|rootfs|rootfs-native|env)" ;;
  esac
}

print_cmd() { printf '%q ' "$@"; printf '\n'; }

# --gui binds/env, appended to CMD after the mode-specific bwrap invocation
# is built (both overlay and rootfs use bwrap, so this is shared). Explicit
# even for overlay mode, whose base --ro-bind / / already exposes the
# session by accident — rootfs mode replaces / entirely and needs this for
# real.
gui_cmd() {
  if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ]; then
    CMD+=(--bind "$XDG_RUNTIME_DIR" "$XDG_RUNTIME_DIR" --setenv XDG_RUNTIME_DIR "$XDG_RUNTIME_DIR")
  fi
  if [ -n "${DISPLAY:-}" ]; then CMD+=(--setenv DISPLAY "$DISPLAY"); fi
  if [ -n "${WAYLAND_DISPLAY:-}" ]; then CMD+=(--setenv WAYLAND_DISPLAY "$WAYLAND_DISPLAY"); fi
  CMD+=(--setenv _JAVA_AWT_WM_NONREPARENTING 1)
}

# Builds the global CMD array (the runner, without the user command).
build_cmd() {
  CMD=()
  case "$1" in
    overlay)
      CMD=(bwrap --ro-bind / /)
      if [ -d "$PREFIX/usr" ]; then
        CMD+=(--overlay-src /usr --overlay-src "$PREFIX/usr" --tmp-overlay /usr)
      fi
      if [ -d "$PREFIX/etc" ]; then
        CMD+=(--overlay-src /etc --overlay-src "$PREFIX/etc" --tmp-overlay /etc)
      fi
      CMD+=(--dev-bind /dev /dev --proc /proc --bind /tmp /tmp
            --bind "$HOME" "$HOME" --chdir "$PWD"
            --setenv HOME "$HOME"
            --setenv PATH "$PREFIX/sbin:$PREFIX/bin:$PREFIX/usr/bin:$PATH"
            --setenv XDG_DATA_DIRS "$PREFIX/usr/share:$PREFIX/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}")
      if [ "$GUI" -eq 1 ]; then gui_cmd; fi
      ;;
    overlay-native)
      # The mounts run inside the namespace, before the user command. Each
      # upper/work pair lives on a private tmpfs, so writes are ephemeral and
      # land neither in the prefix nor on the host (bwrap's --tmp-overlay).
      # lowerdir is leftmost-wins, so the prefix comes first (the reverse of
      # bwrap's --overlay-src order).
      local script='
set -e
ovl="$(mktemp -d)"
mount -t tmpfs -o mode=0700 tmpfs "$ovl"
for d in usr etc; do
  [ -d "$PREFIX/$d" ] || continue
  mkdir "$ovl/up-$d" "$ovl/wk-$d"
  mount -t overlay overlay \
    -o "lowerdir=$PREFIX/$d:/$d,upperdir=$ovl/up-$d,workdir=$ovl/wk-$d" "/$d"
done
cd "$SL_PWD"
export PATH="$PREFIX/sbin:$PREFIX/bin:$PREFIX/usr/bin:$PATH"
export XDG_DATA_DIRS="$PREFIX/usr/share:$PREFIX/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
exec unshare -U --map-user="$SL_UID" --map-group="$SL_GID" -- "$@"'
      native_prefix_ok
      CMD=(env PREFIX="$PREFIX" SL_PWD="$PWD" SL_UID="$(id -u)" SL_GID="$(id -g)")
      if [ "$GUI" -eq 1 ]; then CMD+=(_JAVA_AWT_WM_NONREPARENTING=1); fi
      CMD+=(unshare -Urm --propagation private bash -c "$script" prefix-run)
      ;;
    rootfs)
      case "$(rootfs_runner)" in
        bwrap)
          rootfs_env
          CMD=(env -i "${ENVV[@]}" "$(command -v bwrap)"
               --bind "$ROOTFS" / --dev-bind /dev /dev --proc /proc
               --ro-bind /sys /sys --bind /tmp /tmp --bind "$HOME" "$HOME"
               --ro-bind-try /etc/resolv.conf /etc/resolv.conf
               --ro-bind-try /etc/hosts /etc/hosts
               --unshare-user --uid 0 --gid 0 --chdir "$PWD")
          if [ "$GUI" -eq 1 ]; then gui_cmd; fi
          ;;
        native) build_cmd rootfs-native ;;
        proot)
          if [ "$GUI" -eq 1 ]; then die "--gui needs bwrap or rootfs-native for the session bind (proot can't)"; fi
          # -R binds /dev, /proc, /sys, /tmp, $HOME, resolv.conf and hosts itself
          rootfs_env
          CMD=(env -i "${ENVV[@]}" "$(command -v proot)" -0 -R "$ROOTFS" -w "$PWD")
          ;;
      esac
      ;;
    rootfs-native)
      # No fork anywhere: unshare, bash and chroot each exec the next, so the
      # command keeps prefix-run's pid, process group and session. Ctrl-C and
      # SIGTERM reach it directly, the exit status is its own, and nothing is
      # left behind to reap. /proc is the host's, bound (as in the overlay
      # modes), so no pid namespace and no PID 1 to emulate. The mounts live in
      # a private mount namespace and vanish with it.
      # $HOME is bound non-recursively: a rootfs under $HOME would otherwise
      # appear inside itself with its own /dev, /proc, ... mounts. /dev/shm
      # comes with /dev. resolv.conf and hosts are the host's, read-only, so
      # DNS follows the host; a symlink there is skipped, since it would be
      # resolved on the host side.
      local script='
set -e
R="$SL_ROOTFS"
mkdir -p "$R$HOME"
mount --bind "$HOME" "$R$HOME" 2>/dev/null || mount --rbind "$HOME" "$R$HOME"
mount --rbind /dev "$R/dev"
mount --rbind /proc "$R/proc"
mount --rbind /sys "$R/sys"
mount -o remount,bind,ro "$R/sys" 2>/dev/null || true
mount --rbind /tmp "$R/tmp"
for f in resolv.conf hosts; do
  [ -e "/etc/$f" ] && [ ! -L "$R/etc/$f" ] || continue
  [ -e "$R/etc/$f" ] || : > "$R/etc/$f"
  mount -o bind,ro "/etc/$f" "$R/etc/$f"
done
if [ -n "${SL_RUNDIR:-}" ]; then
  mkdir -p "$R$SL_RUNDIR"
  mount --rbind "$SL_RUNDIR" "$R$SL_RUNDIR"
fi
c="$SL_CHROOT" p="$SL_PWD"
unset SL_ROOTFS SL_CHROOT SL_PWD SL_RUNDIR
exec "$c" "$R" /bin/sh -c '"'"'cd "$0" && exec "$@"'"'"' "$p" "$@"'
      rootfs_env
      CMD=(env -i "${ENVV[@]}" SL_ROOTFS="$ROOTFS" SL_CHROOT="$CHROOT" SL_PWD="$PWD")
      if [ "$GUI" -eq 1 ] && [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ]; then
        CMD+=(SL_RUNDIR="$XDG_RUNTIME_DIR")
      fi
      CMD+=("$(command -v unshare)" -Urm --propagation private "$(command -v bash)" -c "$script" prefix-run)
      ;;
  esac
}

MODE_RESOLVED="$(pick_mode)"
if [ "$GUI" -eq 1 ] && [ "$MODE_RESOLVED" = env ]; then
  die "--gui is incompatible with mode=env (no overlay/rootfs means the GUI app's own /usr/lib paths won't resolve either) — need an overlay (bwrap or unshare) + userns + overlayfs, or a rootfs"
fi
if [ "$EXPLAIN" -eq 1 ]; then
  RUNNER_NOTE=""
  if [ "$MODE_RESOLVED" = rootfs ]; then RUNNER_NOTE=" runner=$(rootfs_runner)"; fi
  printf 'prefix-run: mode=%s%s PREFIX=%s ROOTFS=%s\n' \
    "$MODE_RESOLVED" "$RUNNER_NOTE" "$PREFIX" "$ROOTFS" >&2
fi

case "$MODE_RESOLVED" in
  env)
    export LD_LIBRARY_PATH="$PREFIX/usr/lib:$PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export XDG_DATA_DIRS="$PREFIX/usr/share:$PREFIX/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
    export PATH="$PREFIX/sbin:$PREFIX/bin:$PREFIX/usr/bin:$PATH"
    export PKG_CONFIG_PATH="$PREFIX/usr/lib/pkgconfig:$PREFIX/usr/share/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    if [ "$PRINT" -eq 1 ]; then
      print_cmd env "PATH=$PREFIX/usr/bin:$PATH" "XDG_DATA_DIRS=$XDG_DATA_DIRS" "$@"
      exit 0
    fi
    exec "$@"
    ;;
  overlay|overlay-native|rootfs|rootfs-native)
    build_cmd "$MODE_RESOLVED"
    if [ "$PRINT" -eq 1 ]; then print_cmd "${CMD[@]}" "$@"; exit 0; fi
    exec "${CMD[@]}" "$@"
    ;;
esac
