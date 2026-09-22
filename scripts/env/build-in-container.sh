#!/usr/bin/env bash
# End-to-end: create the build rootfs (rootless podman container), install the
# build tools, build apt + dpkg, then install the runtime config on the host.
#
#   ./scripts/env/build-in-container.sh
#
# Overridable: CONTAINER, IMAGE, PREFIX, APT_VER, DPKG_VER.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONTAINER="${CONTAINER:-aptbuild}"
IMAGE="${IMAGE:-debian:sid}"
PREFIX="${PREFIX:-$HOME/.local}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

command -v podman >/dev/null || { echo "podman not found" >&2; exit 1; }

if podman container exists "$CONTAINER"; then
  log "container '$CONTAINER' exists; starting it"
  podman start "$CONTAINER" >/dev/null
else
  log "creating build rootfs '$CONTAINER' from $IMAGE"
  # Bind-mount the home so build scripts and $PREFIX are shared with the host.
  podman run -d --name "$CONTAINER" -v "$HOME:$HOME:rw" "$IMAGE" sleep infinity >/dev/null
fi

# Make sure it is running (a previous exec may have stopped it).
podman start "$CONTAINER" >/dev/null 2>&1 || true

log "installing build tools into the rootfs"
podman exec -e DEBIAN_FRONTEND=noninteractive "$CONTAINER" \
  bash "$REPO/scripts/bootstrap/install-build-deps.sh"

# fetch sources on the host so the container needs no curl/wget
"$REPO/scripts/bootstrap/fetch-sources.sh"

# Build as the host user's HOME/PREFIX: podman exec defaults to root with
# HOME=/root, which would install into /root/.local instead of $HOME/.local.
build_env=(-e HOME="$HOME" -e PREFIX="$PREFIX" -e REPO="$REPO")

log "building apt"
podman exec "${build_env[@]}" "$CONTAINER" bash "$REPO/scripts/bootstrap/build-apt.sh"

log "building dpkg"
podman exec "${build_env[@]}" "$CONTAINER" bash "$REPO/scripts/bootstrap/build-dpkg.sh"

log "installing runtime config into $PREFIX"
PREFIX="$PREFIX" "$REPO/scripts/setup/install-config.sh"

log "all done."
log "  export PATH=\"$PREFIX/sbin:$PREFIX/bin:$PREFIX/usr/bin:\$PATH\""
log "  $PREFIX/bin/apt-get update && $PREFIX/bin/apt-get install -y <pkg>"
