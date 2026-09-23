#!/usr/bin/env bash
# Pre-download the source tarballs, so a build sandbox does not need a
# downloader such as curl/wget inside it.
#
# Caches into $SRC; the build scripts' fetch() then finds them and never calls
# out. build-on-host.sh runs it.
source "$(dirname "$0")/../common.sh"

fetch "$APT_URL"  "apt-$APT_VER.tar.xz"
fetch "$DPKG_URL" "dpkg-$DPKG_VER.tar.gz"
log "sources cached in $SRC"
