#!/usr/bin/env bash
# Add the userspace apt/dpkg prefix dirs to the shell PATH, idempotently, so
# packages installed into $PREFIX/usr/bin are runnable in new shells.
#
#   ./scripts/setup/install-shell-path.sh
#
# Without this, `apt-get install foo` puts the binary in $PREFIX/usr/bin but a
# fresh terminal can't find it. The block is guarded and marked, so re-running
# is a no-op. Called automatically by install-config.sh (skip with --no-shell).
set -euo pipefail
source "$(dirname "$0")/../common.sh"

MARK="# >>> sudo-less PATH >>>"
END="# <<< sudo-less PATH <<<"

read -r -d '' BLOCK <<EOF || true
$MARK
# userspace apt/dpkg prefix (installed by $REPO)
if [ -d "$PREFIX/bin" ] || [ -d "$PREFIX/usr/bin" ]; then
    case ":\$PATH:" in
        *":$PREFIX/usr/bin:"*) ;;
        *) PATH="$PREFIX/sbin:$PREFIX/bin:$PREFIX/usr/bin:\$PATH" ;;
    esac
fi
export PATH
# point apt at the prefix's own config (keeps a built prefix relocatable)
if [ -f "$PREFIX/etc/apt/apt.conf.d/00local-prefix" ]; then
    APT_CONFIG="$PREFIX/etc/apt/apt.conf.d/00local-prefix"
    export APT_CONFIG
fi
$END
EOF

# an account created without /etc/skel has neither file: create ~/.profile,
# or nothing would put the prefix on PATH (and nothing would say so)
[ -e "$HOME/.bashrc" ] || [ -e "$HOME/.profile" ] || : > "$HOME/.profile"

updated=0
for rc in "$HOME/.bashrc" "$HOME/.profile"; do
  [ -e "$rc" ] || continue
  if grep -qF "$MARK" "$rc"; then
    sed -i "\|$MARK|,\|$END|d" "$rc"   # drop the old block, then re-add
    printf '\n%s\n' "$BLOCK" >> "$rc"
    log "refreshed $rc"
  else
    printf '\n%s\n' "$BLOCK" >> "$rc"
    log "updated $rc"
  fi
  updated=$((updated + 1))
done

[ "$updated" -gt 0 ] && log "open a new login shell (or source the file above) to pick it up"
log "prefix dirs: $PREFIX/sbin, $PREFIX/bin, $PREFIX/usr/bin"
