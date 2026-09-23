#!/usr/bin/env bash
# Shared settings for the userspace apt/dpkg build.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
SRC="${SRC:-$REPO/src}"

APT_VER="${APT_VER:-3.3.3}"
DPKG_VER="${DPKG_VER:-1.23.11}"
# The apt source tarball's SHA-1, which is also its snapshot.debian.org name.
APT_SHA1="${APT_SHA1:-f4f5406a434df5f18c885871d77197e682b20447}"

# Where to fetch sources. salsa.debian.org is often blocked (403/Varnish PoW),
# and the GitHub mirror of apt stopped at 3.1.x, so apt comes from
# snapshot.debian.org, whose file URLs are permanent; dpkg from its
# maintainer's GitHub mirror, which publishes the release tags.
APT_URL="${APT_URL:-https://snapshot.debian.org/file/$APT_SHA1}"
DPKG_URL="${DPKG_URL:-https://github.com/guillemj/dpkg/archive/refs/tags/$DPKG_VER.tar.gz}"

# Architecture (no hardcoding): prefer dpkg's answer, else map uname -m.
# DEB_ARCH is apt's COMMON_ARCH / dpkg's DEB_HOST_ARCH; DEB_CPU is the CPU tuple.
detect_deb_arch() {
  if command -v dpkg >/dev/null 2>&1; then
    dpkg --print-architecture && return
  fi
  case "$(uname -m)" in
    x86_64) echo amd64 ;; aarch64) echo arm64 ;; armv7l) echo armhf ;;
    armv6l) echo armel ;; i686|i386) echo i386 ;; riscv64) echo riscv64 ;;
    ppc64le) echo ppc64el ;; s390x) echo s390x ;; *) echo "$(uname -m)" ;;
  esac
}
DEB_ARCH="${DEB_ARCH:-$(detect_deb_arch)}"
case "$DEB_ARCH" in
  amd64)   DEB_CPU=x86_64 ;;
  arm64)   DEB_CPU=aarch64 ;;
  armhf|armel) DEB_CPU=arm ;;
  ppc64el) DEB_CPU=powerpc64le ;;
  *)       DEB_CPU="$DEB_ARCH" ;;
esac

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

apply_series() { # apply_series DIR: the patches listed in DIR/series, in order
  local dir="$1" p
  [ -f "$dir/series" ] || die "no series file in $dir"
  while read -r p; do
    case "$p" in ''|'#'*) continue ;; esac
    log "patch $p"
    patch -p1 -f --no-backup-if-mismatch < "$dir/$p"
  done < "$dir/series"
}
