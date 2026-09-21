#!/usr/bin/env bash
# Build apt + dpkg inside a real rootfs created by make-buildroot.sh, using
# `proot` so no root and no podman are involved.
#
#   ./scripts/build-in-rootfs.sh
#   ROOTFS=~/buildroot PREFIX=~/.local ./scripts/build-in-rootfs.sh
#
# How it works: `proot -r ROOTFS` makes ROOTFS the filesystem root for the
# process tree using ptrace (no privileges needed), and `-0` fakes uid 0 so
# tools that check for root are satisfied. Host paths are bind-mounted back in
# with -b, so the source tree and $PREFIX stay on the host filesystem.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOTFS="${ROOTFS:-$HOME/buildroot}"
PREFIX="${PREFIX:-$HOME/.local}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

[ -x "$ROOTFS/bin/sh" ] || { echo "no rootfs at $ROOTFS (run make-buildroot.sh)" >&2; exit 1; }
command -v proot >/dev/null || { echo "proot not found" >&2; exit 1; }

# On recent kernels proot's seccomp accelerator fails ("can't chmod
# /tmp/proot-*"); disabling it falls back to the portable ptrace path.
export PROOT_NO_SECCOMP=1

run_in_rootfs() {
  proot -0 -r "$ROOTFS" \
    -b /proc -b /dev -b /sys -b /tmp \
    -b "$HOME:$HOME" \
    -w "$HOME" \
    /usr/bin/env HOME="$HOME" PREFIX="$PREFIX" REPO="$REPO" "$@"
}

log "building apt inside $ROOTFS"
run_in_rootfs bash "$REPO/scripts/build-apt.sh"

log "building dpkg inside $ROOTFS"
run_in_rootfs bash "$REPO/scripts/build-dpkg.sh"

log "installing runtime config into $PREFIX"
PREFIX="$PREFIX" "$REPO/scripts/install-config.sh"

log "done."
