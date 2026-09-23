#!/bin/bash
# fetch-old-mesa.sh - (re)create the isolated old Mesa set used by
# bin/waydroid-oldmesa, from Debian 13 (trixie) archives.
#
# Extracts into /opt/waydroid-work/old-mesa. Nothing is installed on the
# system. Run as root (needs to write under /opt). Idempotent.
set -eu

DEST=/opt/waydroid-work
DEBS=$DEST/debs
OUT=$DEST/old-mesa
mkdir -p "$DEBS" "$OUT"

get() { # get <url> <local filename>
  [ -s "$DEBS/$2" ] || curl -sL --max-time 900 -o "$DEBS/$2" "$1"
}

M=https://deb.debian.org/debian/pool/main/m/mesa
get "$M/libegl-mesa0_25.0.7-2+deb13u1_amd64.deb"   libegl-mesa0_25.0.7-2+deb13u1_amd64.deb
get "$M/libglx-mesa0_25.0.7-2+deb13u1_amd64.deb"   libglx-mesa0_25.0.7-2+deb13u1_amd64.deb
get "$M/libgbm1_25.0.7-2+deb13u1_amd64.deb"        libgbm1_25.0.7-2+deb13u1_amd64.deb
get "$M/libgl1-mesa-dri_25.0.7-2+deb13u1_amd64.deb" libgl1-mesa-dri_25.0.7-2+deb13u1_amd64.deb
get "$M/mesa-libgallium_25.0.7-2+deb13u1_amd64.deb" mesa-libgallium_25.0.7-2+deb13u1_amd64.deb
# extra runtime deps the trixie Mesa needs but forky/sid renamed:
get "https://deb.debian.org/debian/pool/main/l/llvm-toolchain-19/libllvm19_19.1.7-3+b1_amd64.deb" libllvm19.deb
get "https://deb.debian.org/debian/pool/main/libx/libxml2/libxml2_2.12.7+dfsg+really2.9.14-2.1+deb13u3_amd64.deb" libxml2.deb

for f in "$DEBS"/*.deb; do dpkg -x "$f" "$OUT"; done
echo "old Mesa extracted to $OUT"
