#!/usr/bin/env bash
# Create a REAL Debian rootfs (a directory holding a complete /usr, /etc, /var,
# ...) with all build dependencies, WITHOUT root and WITHOUT podman.
#
#   ./scripts/env/make-buildroot.sh            # -> ~/buildroot
#   ROOTFS=~/myroot ./scripts/env/make-buildroot.sh
#
# How it works
# ------------
# `mmdebstrap` bootstraps a Debian system using an unprivileged user namespace
# (--mode=unshare): inside the namespace it is uid 0 and can chown/mknod/chroot,
# while on the host nothing runs as root. The namespace's root maps to our
# /etc/subuid range (165536), NOT to our real uid, so it cannot write into
# $HOME (mode 0700). We therefore have mmdebstrap emit a *tarball to stdout*
# (written through an fd we opened, which bypasses path permissions) and extract
# it ourselves as the normal user. Device nodes can't be created unprivileged,
# so we skip ./dev and let proot bind-mount the host's /dev at build time.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOTFS="${ROOTFS:-$HOME/buildroot}"
TARBALL="${TARBALL:-$HOME/buildroot.tar}"
SUITE="${SUITE:-sid}"
MIRROR="${MIRROR:-http://deb.debian.org/debian}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

command -v mmdebstrap >/dev/null || { echo "mmdebstrap not found" >&2; exit 1; }

INCLUDE="$(grep -vE '^\s*(#|$)' "$REPO/scripts/build-deps.list" | paste -sd,)"
log "rootfs:  $ROOTFS"
log "suite:   $SUITE"
log "packages: $(echo "$INCLUDE" | tr ',' ' ' | wc -w)"

# tempdir must be world-traversable for the mapped root inside the namespace
export TMPDIR="${TMPDIR:-/tmp}"

log "bootstrapping to $TARBALL (unprivileged user namespace)"
mmdebstrap \
  --mode=unshare \
  --variant=apt \
  --format=tar \
  --components=main \
  --include="$INCLUDE" \
  "$SUITE" - "$MIRROR" > "$TARBALL"

log "extracting as $(id -un)"
rm -rf "$ROOTFS"; mkdir -p "$ROOTFS"
# device nodes are not creatable unprivileged; proot binds the host's /dev
tar -xf "$TARBALL" -C "$ROOTFS" --no-same-owner --exclude='./dev/*' 2>/dev/null || true

log "rootfs ready:"
du -sh "$ROOTFS"
ls "$ROOTFS/usr/bin/cmake" "$ROOTFS/usr/bin/gcc" "$ROOTFS/bin/sh"
