#!/usr/bin/env bash
# Install the build toolchain + dev libraries needed to build apt and dpkg.
# Run this FIRST, as root, inside a build environment (podman container or a
# mmdebstrap rootfs). Idempotent.
#
#   podman exec -e DEBIAN_FRONTEND=noninteractive aptbuild \
#     bash /home/master/apt-home/scripts/install-build-deps.sh
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
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

pkgs() { grep -vE '^\s*(#|$)' "$REPO/scripts/build-deps.list"; }

# deb-src is not required for this explicit list, but harmless to have.
if [ ! -e /etc/apt/sources.list.d/src.sources ]; then
  cat > /etc/apt/sources.list.d/src.sources <<'EOF'
Types: deb-src
URIs: http://deb.debian.org/debian
Suites: sid
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.pgp
EOF
fi

log "apt-get update"
apt-get update -qq

log "installing build dependencies"
# shellcheck disable=SC2046
apt-get install -y -qq $(pkgs)

log "build deps ready:"
cmake --version | head -1
gcc --version | head -1
