#!/usr/bin/env bash
# Shared settings for the userspace apt/dpkg build.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
SRC="${SRC:-$REPO/src}"

APT_VER="${APT_VER:-2.8.1}"
DPKG_VER="${DPKG_VER:-1.22.6}"

# Where to fetch sources. salsa.debian.org is often blocked (403/Varnish PoW),
# so use the upstream mirrors that publish the same release tags.
APT_URL="${APT_URL:-https://github.com/Debian/apt/archive/refs/tags/$APT_VER.tar.gz}"
DPKG_URL="${DPKG_URL:-https://github.com/guillemj/dpkg/archive/refs/tags/$DPKG_VER.tar.gz}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

fetch() { # fetch URL FILE
  local url="$1" file="$2"
  mkdir -p "$SRC"
  if [ -s "$SRC/$file" ]; then
    log "cached $file"
  else
    log "downloading $file"
    curl -fL -o "$SRC/$file" "$url"
  fi
}

# The build dependency package list (one per line, comments/blank ignored).
build_pkgs() { grep -vE '^\s*(#|$)' "$REPO/scripts/build-deps.list"; }

apply_patches() { # apply_patches DIR
  local dir="$1" p
  shopt -s nullglob
  for p in "$dir"/*.patch; do
    log "patch $(basename "$p")"
    patch -p1 -f --no-backup-if-mismatch < "$p"
  done
  shopt -u nullglob
}
