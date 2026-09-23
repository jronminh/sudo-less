#!/usr/bin/env bash
# Build apt + dpkg inside a real rootfs created by make-buildroot.sh, with no
# root and no podman.
#
#   ./scripts/env/build-in-rootfs.sh
#   ROOTFS=~/buildroot PREFIX=~/.local ./scripts/env/build-in-rootfs.sh
#   ROOTFS_MODE=rootfs-native ./scripts/env/build-in-rootfs.sh   # force the runner
#
# How it works
# ------------
# tools/prefix-run.sh --mode rootfs makes $ROOTFS the filesystem root in an
# unprivileged user namespace (as namespace root) and binds the host's $HOME
# back in, so the source tree and $PREFIX stay on the host filesystem. The
# runner is bwrap when it works, else the native one (unshare + chroot,
# util-linux + coreutils only), else proot.
#
# proot is last: it needs ptrace, and hosts with kernel.yama.ptrace_scope=2
# (ptrace restricted to CAP_SYS_PTRACE) make ptrace(PTRACE_TRACEME) fail with
# EPERM. bwrap and the native runner use unshare instead, which is permitted.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../common.sh"

ROOTFS="${ROOTFS:-$HOME/buildroot}"

[ -x "$ROOTFS/bin/sh" ] || die "no rootfs at $ROOTFS (run scripts/env/make-buildroot.sh)"

run_in_rootfs() {
  # prefix-run starts the rootfs from a clean environment; pass what the
  # build scripts need explicitly, via the rootfs's own env(1).
  (cd "$HOME" && export ROOTFS &&
    "$REPO/tools/prefix-run.sh" --mode "${ROOTFS_MODE:-rootfs}" \
      env PREFIX="$PREFIX" REPO="$REPO" "$@")
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
