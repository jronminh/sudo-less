#!/usr/bin/env bash
# package-prebuilt.sh — turn a built prefix into the release tarball that
# bootstrap.sh fetches. Run after a build (scripts/env/build-on-host.sh, etc.)
# from a CLEAN prefix, so only the apt/dpkg artifacts are packaged.
#
#   ./scripts/bootstrap/package-prebuilt.sh                 # -> dist/<asset>
#   PREFIX=~/build-prefix OUT=~/dist ./scripts/bootstrap/package-prebuilt.sh
#
# The tarball unpacks at $PREFIX and is relocatable: apt follows the config
# install-config.sh regenerates (config/apt.conf.d/00local-prefix), so it works
# under a different user/prefix than the one that built it — see
# docs/apt-dpkg-port.md and docs/release.md.
set -euo pipefail
source "$(dirname "$0")/../common.sh"

OUT="${OUT:-$REPO/dist}"
ASSET="sudo-less-apt-dpkg-${APT_VER}-${DPKG_VER}-${DEB_ARCH}.tar.gz"

log "packaging $PREFIX -> $OUT/$ASSET"
for d in bin sbin lib; do
  [ -d "$PREFIX/$d" ] || die "$PREFIX/$d missing — build apt/dpkg first"
done

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# 1. the built apt/dpkg runtime
for d in bin sbin lib; do
  cp -a "$PREFIX/$d" "$STAGE/$d"
done

# 2. the in-repo runtime files install-config.sh needs to configure it
mkdir -p "$STAGE/share/sudo-less"
for d in apt-dpkg config shims python; do
  cp -a "$REPO/$d" "$STAGE/share/sudo-less/$d"
done
mkdir -p "$STAGE/share/sudo-less/scripts"
cp -a "$REPO/scripts/common.sh" "$STAGE/share/sudo-less/scripts/common.sh"
cp -a "$REPO/scripts/setup"     "$STAGE/share/sudo-less/scripts/setup"

# 3. never ship generated state: bootstrap regenerates the config and re-seeds
#    the dpkg db from the *target* system, so a stale status would be wrong.
rm -rf "${STAGE:?}/var" "${STAGE:?}/etc"

mkdir -p "$OUT"
tar -C "$STAGE" -czf "$OUT/$ASSET" .
( cd "$OUT" && sha256sum "$ASSET" > "$ASSET.sha256" )

log "wrote:"
ls -l "$OUT/$ASSET" "$OUT/$ASSET.sha256"
log "attach BOTH to a GitHub Release; bootstrap.sh fetches them by name."
