#!/usr/bin/env bash
# Smoke-test Debian packages against the userspace apt/dpkg.
#
#   ./scripts/test-packages.sh [PKG...]      # default: a curated list below
#
# Installs the batch in one transaction (apt parallelises the downloads) and
# reports per-package status from the prefix dpkg database. Packages already
# present system-wide are reported as "already installed" (the seeded db means
# apt will not duplicate them into the prefix).
set -uo pipefail
source "$(dirname "$0")/common.sh"
set +e  # common.sh enables errexit; keep going so per-package status is reported

export PATH="$PREFIX/sbin:$PREFIX/bin:$PREFIX/usr/bin:$PATH"
APT="$PREFIX/bin/apt-get"
DPKGQ="$PREFIX/bin/dpkg-query"

DEFAULT=(
  bat fd-find ripgrep fzf htop ncdu tree jq duf procs bottom hyperfine
  shellcheck shfmt neovim tmux screen ranger sqlite3 patchelf strace ltrace
  unzip zip file
)
PKGS=("$@"); [ "${#PKGS[@]}" -gt 0 ] || PKGS=("${DEFAULT[@]}")

# drop names that do not exist in the configured repos (else the whole
# transaction aborts with "Unable to locate package")
AVAIL=()
for p in "${PKGS[@]}"; do
  if "$PREFIX/bin/apt-cache" show "$p" >/dev/null 2>&1; then
    AVAIL+=("$p")
  else
    log "skip (not in repo): $p"
  fi
done
PKGS=("${AVAIL[@]}")

log "batch: ${#PKGS[@]} packages"
# keep going even if one package fails, so we still report per-package status
"$APT" install -y --no-install-recommends "${PKGS[@]}" 2>&1 | tail -40 || true

echo
echo "== per-package status (prefix db) =="
for p in "${PKGS[@]}"; do
  st="$("$DPKGQ" -f '${Status}' -W "$p" 2>/dev/null)"
  case "$st" in
    "install ok installed") printf '  %-12s %s\n' "$p" "installed" ;;
    *)                      printf '  %-12s %s\n' "$p" "${st:-not in prefix db}" ;;
  esac
done

echo
echo "== binaries present in $PREFIX/usr/bin =="
for p in "${PKGS[@]}"; do
  b="${p%%-*}"
  [ -x "$PREFIX/usr/bin/$b" ] && echo "  $b"
done
