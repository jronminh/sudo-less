#!/usr/bin/env bash
# Build apt + dpkg inside a real rootfs created by make-buildroot.sh, with no
# root and no podman.
#
#   ./scripts/build-in-rootfs.sh
#   ROOTFS=~/buildroot PREFIX=~/.local ./scripts/build-in-rootfs.sh
#
# How it works
# ------------
# bubblewrap (bwrap) makes $ROOTFS the filesystem root using unprivileged user
# namespaces, and bind-mounts the host's $HOME back in so the source tree and
# $PREFIX stay on the host filesystem.
#
# Why not proot: proot needs ptrace, and this host sets
# kernel.yama.ptrace_scope=2 (ptrace restricted to CAP_SYS_PTRACE), so
# ptrace(PTRACE_TRACEME) fails with EPERM. bwrap uses clone/unshare instead,
# which is permitted. (`unshare -Ur -m chroot $ROOTFS` is an equivalent
# alternative, but bwrap handles /proc, /dev and /sys for us.)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOTFS="${ROOTFS:-$HOME/buildroot}"
PREFIX="${PREFIX:-$HOME/.local}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

[ -x "$ROOTFS/bin/sh" ] || { echo "no rootfs at $ROOTFS (run make-buildroot.sh)" >&2; exit 1; }
command -v bwrap >/dev/null || { echo "bwrap not found" >&2; exit 1; }

run_in_rootfs() {
  bwrap \
    --bind "$ROOTFS" / \
    --dev-bind /dev /dev \
    --proc /proc \
    --ro-bind /sys /sys \
    --bind /tmp /tmp \
    --bind "$HOME" "$HOME" \
    --chdir "$HOME" \
    --setenv HOME "$HOME" \
    --setenv PREFIX "$PREFIX" \
    --setenv REPO "$REPO" \
    "$@"
}

# fetch sources on the host so the rootfs needs no curl/wget
"$REPO/scripts/fetch-sources.sh"

log "smoke test: $ROOTFS as /"
run_in_rootfs /bin/sh -c 'echo "rootfs uid=$(id -u) cmake=$(command -v cmake) gcc=$(command -v gcc)"'

log "building apt inside $ROOTFS"
run_in_rootfs bash "$REPO/scripts/build-apt.sh"

log "building dpkg inside $ROOTFS"
run_in_rootfs bash "$REPO/scripts/build-dpkg.sh"

log "installing runtime config into $PREFIX"
PREFIX="$PREFIX" "$REPO/scripts/install-config.sh"

log "done."
