#!/usr/bin/env bash
# Put apt-installed modules under $PREFIX/usr/lib/python3/dist-packages on
# sys.path automatically, via a .pth file in the system python3's user site
# — so a package relocated there (e.g. ranger) imports without needing
# PYTHONPATH in its own recipe. See #5, docs/mechanisms.md.
#
# Called by scripts/setup/install-config.sh; not usually run directly. Re-running
# is safe (overwrites the same file).
source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/common.sh"

if command -v python3 >/dev/null 2>&1; then
  USER_SITE="$(python3 -m site --user-site 2>/dev/null || true)"
  if [ -n "$USER_SITE" ]; then
    mkdir -p "$USER_SITE"
    printf '%s\n' "$PREFIX/usr/lib/python3/dist-packages" \
      > "$USER_SITE/00-sudo-less.pth"
    log "python: sys.path += $PREFIX/usr/lib/python3/dist-packages ($USER_SITE/00-sudo-less.pth)"
  fi
fi
