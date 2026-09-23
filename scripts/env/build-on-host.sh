#!/usr/bin/env bash
# Minimal-dependency reproduction: build apt + dpkg directly on the host.
#
# Use this when you have root (or sudo) on a Debian/Ubuntu system. It needs NO
# sandbox at all — no user namespaces, no subuid, no podman, no
# bwrap. The only dependencies are the build packages, installed with apt.
#
#   ./scripts/env/build-on-host.sh
#
# Steps: install build deps (as root) -> fetch sources (host) -> build apt and
# dpkg (as you, so $PREFIX stays user-owned) -> write runtime config.
#
# This is the shortest path from a fresh Debian install to a working userspace
# apt/dpkg. The container path (env/build-in-container.sh, rootless podman)
# exists only for the case where you do NOT have root.
set -euo pipefail
source "$(dirname "$0")/../common.sh"

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
elif command -v sudo >/dev/null; then
  SUDO="sudo"
else
  die "no root and no sudo: use scripts/env/build-in-container.sh (rootless podman) instead"
fi

log "installing build dependencies (as ${SUDO:-root})"
$SUDO bash "$REPO/scripts/bootstrap/install-build-deps.sh"

"$REPO/scripts/bootstrap/fetch-sources.sh"

log "building apt"
bash "$REPO/scripts/bootstrap/build-apt.sh"

log "building dpkg"
bash "$REPO/scripts/bootstrap/build-dpkg.sh"

log "installing runtime config into $PREFIX"
PREFIX="$PREFIX" "$REPO/scripts/setup/install-config.sh"

log "done."
log "  export PATH=\"$PREFIX/sbin:$PREFIX/bin:$PREFIX/usr/bin:\$PATH\""
log "  $PREFIX/bin/apt-get update && $PREFIX/bin/apt-get install -y <pkg>"
