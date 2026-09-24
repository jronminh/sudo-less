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

# the suite this build was produced against (the compatibility baseline)
suite_name() {
  if [ -n "${SUITE:-}" ]; then printf '%s' "$SUITE"; return; fi
  sed -n 's/^VERSION_CODENAME=//p' /etc/os-release 2>/dev/null | tr -d '"'
}

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
# tools/: prefix-view.sh, prefix-wrap.sh and prefix-check.sh (installed into lib/sudo-less by
# apt-dpkg/install.sh), prefix-run.sh and deb2home.sh (for packages apt
# cannot install)
for d in apt-dpkg config tools; do
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

# record what this was built from, so the baseline is stated, not assumed
BUILDINFO="$OUT/$ASSET.buildinfo"
{
  printf 'asset  %s\n' "$ASSET"
  printf 'apt    %s\n' "$APT_VER"
  printf 'dpkg   %s\n' "$DPKG_VER"
  printf 'arch   %s\n' "$DEB_ARCH"
  printf 'suite  %s\n' "$(suite_name)"
  printf 'built  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$BUILDINFO"

log "wrote:"
ls -l "$OUT/$ASSET" "$OUT/$ASSET.sha256" "$BUILDINFO"
log "attach ALL THREE to a GitHub Release; bootstrap.sh fetches the first two."
