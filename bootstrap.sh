#!/usr/bin/env bash
# bootstrap.sh — the default, supported route: fetch the prebuilt patched
# apt/dpkg for your architecture, verify it, unpack it into $PREFIX and set up
# a userspace package manager in ~/.local. No root, no build, no namespaces.
#
#   ./bootstrap.sh                 # fetch + verify + unpack + configure
#   ./bootstrap.sh --dry-run       # print what it would do, change nothing
#   ./bootstrap.sh --verify-only   # download and check the hash, then stop
#   ./bootstrap.sh --version TAG   # a specific release tag (default: latest)
#
# Overrides (env): PREFIX, REPO_SLUG, BASE_URL, APT_VER, DPKG_VER.
# Requires: bash, curl or wget, tar, sha256sum. Nothing else.
#
# This is the supported path (docs/standard.md): mechanisms none and env, reached with
# no capability beyond curl + tar + a writable $PREFIX. Building from source,
# the overlay and GUI apps, are experimental.
set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
REPO_SLUG="${REPO_SLUG:-jronminh/sudo-less}"
VERSION="${VERSION:-}"                       # empty = the latest release
BASE_URL="${BASE_URL:-}"                     # override the whole release base
APT_VER="${APT_VER:-3.3.3}"
DPKG_VER="${DPKG_VER:-1.23.11}"

DRY=0
VERIFY_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)     DRY=1 ;;
    --verify-only) VERIFY_ONLY=1 ;;
    --version)     VERSION="${2:?--version needs a tag}"; shift ;;
    -h|--help)     sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)             echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- architecture (no dpkg dependency: a locked-down box may not have one) ----
case "$(uname -m)" in
  x86_64)          ARCH=amd64 ;;
  aarch64|arm64)   ARCH=arm64 ;;
  armv7l)          ARCH=armhf ;;
  riscv64)         ARCH=riscv64 ;;
  *)               ARCH="$(uname -m)" ;;
esac

ASSET="sudo-less-apt-dpkg-${APT_VER}-${DPKG_VER}-${ARCH}.tar.gz"
if [ -n "$BASE_URL" ]; then
  URL="${BASE_URL%/}"
elif [ -n "$VERSION" ]; then
  URL="https://github.com/${REPO_SLUG}/releases/download/${VERSION}"
else
  URL="https://github.com/${REPO_SLUG}/releases/latest/download"
fi

log "prefix:  $PREFIX"
log "arch:    $ARCH"
log "asset:   $ASSET"
log "from:    $URL"

if [ "$DRY" = 1 ]; then
  log "dry run — would fetch, verify sha256, unpack into $PREFIX, then run:"
  printf '    %s/share/sudo-less/scripts/setup/install-config.sh\n' "$PREFIX"
  exit 0
fi

# --- downloader --------------------------------------------------------------
if command -v curl >/dev/null; then
  fetch() { curl -fL --retry 3 -o "$2" "$1"; }
elif command -v wget >/dev/null; then
  fetch() { wget -O "$2" "$1"; }
else
  die "need curl or wget"
fi
command -v sha256sum >/dev/null || die "need sha256sum"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log "downloading $ASSET"
fetch "$URL/$ASSET" "$TMP/$ASSET" || die "download failed: $URL/$ASSET"
fetch "$URL/$ASSET.sha256" "$TMP/$ASSET.sha256" \
  || die "download failed: $URL/$ASSET.sha256 (missing checksum — refusing to continue)"

log "verifying sha256"
( cd "$TMP" && sha256sum -c "$ASSET.sha256" ) || die "checksum mismatch — refusing to unpack"

if [ "$VERIFY_ONLY" = 1 ]; then
  log "verified OK ($ASSET)"
  exit 0
fi

log "unpacking into $PREFIX"
mkdir -p "$PREFIX"
tar -C "$PREFIX" -xzf "$TMP/$ASSET"

SETUP="$PREFIX/share/sudo-less/scripts/setup/install-config.sh"
[ -x "$SETUP" ] || die "unpacked tree is missing $SETUP (bad artifact?)"

log "configuring"
PREFIX="$PREFIX" bash "$SETUP"

cat <<EOF

$(log "done.")
Next, in a new shell:
    apt-get update
    apt-get install -y ripgrep htop jq
    dpkg -l
EOF
