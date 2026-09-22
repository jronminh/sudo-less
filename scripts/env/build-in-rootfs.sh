#!/usr/bin/env bash
# Build apt + dpkg inside a real rootfs created by make-buildroot.sh, with no
# root and no podman.
#
#   ./scripts/env/build-in-rootfs.sh
#   ROOTFS=~/buildroot PREFIX=~/.local ./scripts/env/build-in-rootfs.sh
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
source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"

ROOTFS="${ROOTFS:-$HOME/buildroot}"

[ -x "$ROOTFS/bin/sh" ] || die "no rootfs at $ROOTFS (run scripts/env/make-buildroot.sh)"
command -v bwrap >/dev/null || die "bwrap not found"

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
"$REPO/scripts/bootstrap/fetch-sources.sh"

log "smoke test: $ROOTFS as /"
run_in_rootfs /bin/sh -c 'echo "rootfs uid=$(id -u) cmake=$(command -v cmake) gcc=$(command -v gcc)"'

log "building apt inside $ROOTFS"
run_in_rootfs bash "$REPO/scripts/bootstrap/build-apt.sh"

log "building dpkg inside $ROOTFS"
run_in_rootfs bash "$REPO/scripts/bootstrap/build-dpkg.sh"

log "installing runtime config into $PREFIX"
PREFIX="$PREFIX" "$REPO/scripts/setup/install-config.sh"

log "done."
