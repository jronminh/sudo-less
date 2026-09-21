#!/usr/bin/env bash
# Minimal-dependency reproduction: build apt + dpkg directly on the host.
#
# Use this when you have root (or sudo) on a Debian/Ubuntu system. It needs NO
# sandbox at all — no user namespaces, no subuid, no podman, no mmdebstrap, no
# bwrap. The only dependencies are the build packages, installed with apt.
#
#   ./scripts/build-on-host.sh
#
# Steps: install build deps (as root) -> fetch sources (host) -> build apt and
# dpkg (as you, so $PREFIX stays user-owned) -> write runtime config.
#
# This is the shortest path from a fresh Debian install to a working userspace
# apt/dpkg. The rootfs/container paths (make-buildroot.sh / build-in-container.sh)
# exist only for the case where you do NOT have root.
set -euo pipefail
source "$(dirname "$0")/common.sh"

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
elif command -v sudo >/dev/null; then
  SUDO="sudo"
else
  die "no root and no sudo: use scripts/make-buildroot.sh + build-in-rootfs.sh instead"
fi

log "installing build dependencies (as ${SUDO:-root})"
$SUDO bash "$REPO/scripts/install-build-deps.sh"

"$REPO/scripts/fetch-sources.sh"

log "building apt"
bash "$REPO/scripts/build-apt.sh"

log "building dpkg"
bash "$REPO/scripts/build-dpkg.sh"

log "installing runtime config into $PREFIX"
PREFIX="$PREFIX" "$REPO/scripts/install-config.sh"

log "done."
log "  export PATH=\"$PREFIX/sbin:$PREFIX/bin:$PREFIX/usr/bin:\$PATH\""
log "  $PREFIX/bin/apt-get update && $PREFIX/bin/apt-get install -y <pkg>"
