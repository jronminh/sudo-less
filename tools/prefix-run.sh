#!/usr/bin/env bash
# prefix-run — run a command with the userspace prefix presented at "/", so
# absolute paths compiled into a package (/etc/..., /usr/share/...) resolve to
# the copies under $PREFIX instead of the host's.
#
#   tools/prefix-run.sh [--mode MODE] [--print] [--explain] CMD [ARG...]
#
# Relocating a .deb does not rewrite paths baked into its binaries, so a package
# that reads /etc or /usr/share by absolute path will not see the copies under
# $PREFIX. This wraps the command so the prefix is overlaid (or made the root),
# whichever of the tiers below is available. See docs/paths.md.
#
# Modes (auto = first available):
#   overlay  bwrap overlay of $PREFIX/{usr,etc} on the host's /usr,/etc.
#            Needs bwrap + unprivileged userns + overlayfs (kernel >= 5.11).
#   rootfs   run inside a complete rootfs ($ROOTFS, from make-buildroot.sh) as
#            "/" — via bwrap --bind, else proot -R, else chroot when root.
#   env      no namespaces: export LD_LIBRARY_PATH/XDG_DATA_DIRS/PATH, exec.
#
#   --print    print the command that would run, and exit
#   --explain  say which mode was chosen and why (to stderr)
set -euo pipefail
source "$(dirname "$0")/../scripts/common.sh"

MODE=auto PRINT=0 EXPLAIN=0
ROOTFS="${ROOTFS:-$HOME/buildroot}"

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -m|--mode)    MODE="${2:?--mode needs a value}"; shift 2 ;;
    -p|--print)   PRINT=1; shift ;;
    -e|--explain) EXPLAIN=1; shift ;;
    -h|--help)    usage 0 ;;
    --)           shift; break ;;
    -*)           die "unknown option: $1" ;;
    *)            break ;;
  esac
done
[ $# -gt 0 ] || usage 2

# --- capability probes -------------------------------------------------------
have()      { command -v "$1" >/dev/null 2>&1; }
userns_ok() { unshare -Ur true >/dev/null 2>&1; }
rootfs_ok() { [ -x "$ROOTFS/bin/sh" ]; }

# A live probe: overlayfs usable from an unprivileged user namespace. bwrap's
# --overlay-src/--tmp-overlay need >= 0.9.0; the kernel needs >= 5.11.
overlay_ok() {
  have bwrap || return 1
  userns_ok  || return 1
  bwrap --ro-bind / / --overlay-src /usr --tmp-overlay /usr true >/dev/null 2>&1
}

pick_mode() {
  case "$MODE" in
    auto)
      if [ -d "$PREFIX/usr" ] && overlay_ok; then printf 'overlay'
      elif rootfs_ok; then printf 'rootfs'
      else printf 'env'; fi ;;
    overlay) [ -d "$PREFIX/usr" ] || die "overlay mode needs $PREFIX/usr (install a package first)"; overlay_ok || die "overlay unavailable: need bwrap + userns + overlayfs (kernel >= 5.11)"; printf 'overlay' ;;
    rootfs)  rootfs_ok  || die "no rootfs at $ROOTFS (run scripts/make-buildroot.sh)"; printf 'rootfs' ;;
    env)     printf 'env' ;;
    *)       die "unknown mode: $MODE (auto|overlay|rootfs|env)" ;;
  esac
}

print_cmd() { printf '%q ' "$@"; printf '\n'; }

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
      ;;
    rootfs)
      if have bwrap; then
        CMD=(bwrap --bind "$ROOTFS" / --dev-bind /dev /dev --proc /proc
             --ro-bind /sys /sys --bind /tmp /tmp --bind "$HOME" "$HOME"
             --chdir "$PWD" --setenv HOME "$HOME")
      elif have proot; then
        CMD=(proot -R "$ROOTFS" -w "$PWD")
      elif [ "$(id -u)" -eq 0 ]; then
        CMD=(chroot "$ROOTFS")
      else
        die "rootfs mode needs bwrap, proot, or root"
      fi
      ;;
  esac
}

MODE_RESOLVED="$(pick_mode)"
if [ "$EXPLAIN" -eq 1 ]; then
  printf 'prefix-run: mode=%s PREFIX=%s ROOTFS=%s\n' \
    "$MODE_RESOLVED" "$PREFIX" "$ROOTFS" >&2
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
  overlay|rootfs)
    build_cmd "$MODE_RESOLVED"
    if [ "$PRINT" -eq 1 ]; then print_cmd "${CMD[@]}" "$@"; exit 0; fi
    exec "${CMD[@]}" "$@"
    ;;
esac
