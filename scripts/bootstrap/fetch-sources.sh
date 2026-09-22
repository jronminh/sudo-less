#!/usr/bin/env bash
# Pre-download the source tarballs on the HOST, so the build sandbox (rootfs or
# container) does not need a downloader such as curl/wget inside it.
#
# Caches into $SRC; the build scripts' fetch() then finds them and never calls
# out. Run this before build-in-rootfs.sh / build-in-container.sh (they do).
source "$(dirname "$0")/../common.sh"

fetch "$APT_URL"  "apt-$APT_VER.tar.gz"
fetch "$DPKG_URL" "dpkg-$DPKG_VER.tar.gz"
log "sources cached in $SRC"
