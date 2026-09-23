#!/bin/bash
# overlay-run.sh — the "native" overlay tier (#26): run a user's command with
# their userspace prefix overlaid on /usr and /etc, using only util-linux and
# the kernel (no bwrap, no user namespaces). Needs root; the command itself
# runs as the user.
#
# Run as the `mobian` admin (the only sudo-capable account):
#     sudo bash ~/sudo-less/admin/native/overlay-run.sh [-u USER] [-p PREFIX] CMD [ARG...]
#
#   -u USER    whose command this is (default: $SUDO_USER)
#   -p PREFIX  the prefix to overlay (default: USER's ~/.local)
#
# How: a private mount namespace is pinned to a file under /run; mount -N
# overlays $PREFIX/{usr,etc} on /usr,/etc inside it (lowerdir is leftmost-wins,
# so the prefix shadows the host only where it has a file); nsenter -S/-G
# enters it as USER and execs CMD. Writes land in a throwaway upper dir under
# /run, removed on exit. The host's /usr and /etc are never touched.
#
# Why this shape: once /usr is overlaid with a user-owned tree, anything root
# execs inside that namespace (mount helpers, setpriv, even ld.so and libc)
# could be the user's file. So root never execs there: mount -N and nsenter
# are loaded from the host and enter the namespace only for the mount(2) call,
# or after dropping to USER. mount -i skips /sbin/mount.<type> helpers.
#
# The no-root equivalent (needs unprivileged userns, enabled by
# admin/third-party/admin-prep.sh): tools/prefix-run.sh --mode overlay-native.
#
# Limits: nsenter --setuid clears supplementary groups (video, render, audio),
# so GUI/GPU apps may lose device access; use prefix-run.sh for those.
set -euo pipefail

die() { printf 'overlay-run: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root. Use: sudo bash ~/sudo-less/admin/native/overlay-run.sh CMD..."

RUN_USER="${SUDO_USER:-}" PREFIX=""
while [ $# -gt 0 ]; do
  case "$1" in
    -u) RUN_USER="${2:?-u needs a user}"; shift 2 ;;
    -p) PREFIX="${2:?-p needs a path}"; shift 2 ;;
    --) shift; break ;;
    -*) die "unknown option: $1" ;;
    *)  break ;;
  esac
done
[ $# -gt 0 ] || die "no command given"
[ -n "$RUN_USER" ] || die "no user: pass -u USER (SUDO_USER is unset)"

pw="$(getent passwd "$RUN_USER")" || die "no such user: $RUN_USER"
IFS=: read -r _ _ uid gid _ home _ <<<"$pw"
[ "$uid" -ne 0 ] || die "refusing to run the command as uid 0"
PREFIX="${PREFIX:-$home/.local}"

# Resolve each layer (a symlink could point anywhere) and insist the user owns
# it: root mounts it, so it must not become a way to expose someone else's tree.
# overlayfs splits lowerdir on ':' and options on ','; a layer may not be an
# ancestor of the mount point.
declare -A LOWER=()
for d in usr etc; do
  [ -e "$PREFIX/$d" ] || continue
  l="$(realpath -e "$PREFIX/$d")"
  [ -d "$l" ] || die "$PREFIX/$d is not a directory"
  [ "$(stat -c %u "$l")" = "$uid" ] || die "$l is not owned by $RUN_USER"
  case "$l" in
    *:*|*,*) die "layer path may not contain ':' or ',': $l" ;;
    /usr|/usr/*|/etc|/etc/*) die "layer may not live under /usr or /etc: $l" ;;
  esac
  LOWER[$d]="$l"
done
[ -n "${LOWER[usr]:-}" ] || die "nothing to overlay: $PREFIX/usr missing (install a package first)"

# A self-bind made private: unshare --mount=FILE refuses a shared parent mount.
st="$(mktemp -d /run/sudo-less-overlay.XXXXXX)"
cleanup() {
  umount "$st/mnt" 2>/dev/null || true
  umount "$st" 2>/dev/null || true
  rm -rf "$st"
}
trap cleanup EXIT
mount --bind "$st" "$st"
mount --make-private "$st"
touch "$st/mnt"
unshare --mount="$st/mnt" --propagation private true

for d in usr etc; do
  [ -n "${LOWER[$d]:-}" ] || continue
  mkdir "$st/up-$d" "$st/wk-$d"
  mount -i -N "$st/mnt" -t overlay overlay \
    -o "lowerdir=${LOWER[$d]}:/$d,upperdir=$st/up-$d,workdir=$st/wk-$d" "/$d"
done

set +e
nsenter --mount="$st/mnt" --setuid="$uid" --setgid="$gid" --wd="$PWD" -- \
  env HOME="$home" USER="$RUN_USER" LOGNAME="$RUN_USER" \
      PATH="$PREFIX/sbin:$PREFIX/bin:$PREFIX/usr/bin:/usr/local/bin:/usr/bin:/bin" \
      XDG_DATA_DIRS="$PREFIX/usr/share:$PREFIX/share:/usr/local/share:/usr/share" \
      "$@"
rc=$?
set -e
exit "$rc"
