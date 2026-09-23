#!/usr/bin/env bash
# Install the build toolchain + dev libraries needed to build apt and dpkg.
# Run this FIRST, as root, inside a build environment (podman container or a
# mmdebstrap rootfs). Idempotent.
#
#   podman exec -e DEBIAN_FRONTEND=noninteractive aptbuild \
#     bash ~/sudo-less/scripts/bootstrap/install-build-deps.sh
#
# The package list lives in build-deps.list so the container build, the
# mmdebstrap rootfs, and the docs all agree.
#
# Notes:
#   * libselinux1-dev is intentionally omitted: apt/dpkg are built
#     --without-libselinux, and it is mid-transition in sid.
#   * gpgv is a *runtime* dep (apt-key verification), not a build dep; see
#     install-config.sh / the gpgv note in README.md.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
source "$(dirname "$0")/../common.sh"

log "apt-get update"
apt-get update -qq

log "installing build dependencies"
# shellcheck disable=SC2046
apt-get install -y -qq $(build_pkgs)

log "build deps ready:"
cmake --version | head -1
gcc --version | head -1
