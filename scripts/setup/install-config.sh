#!/usr/bin/env bash
# Install runtime configuration for the userspace apt/dpkg, then run each
# ecosystem's own install hook (apt-dpkg/, ecosystems/*/, ...). This is the stable
# entrypoint other scripts call — the per-ecosystem logic lives in its own
# top-level folder so it doesn't all pile up in one script as more
# ecosystems (#7: Perl, Ruby, Java) grow their own install-time needs.
#
# Re-running is safe. Options:
#   --reseed      refresh the seeded status from the system
#   --no-shell    do not touch ~/.bashrc / ~/.profile
source "$(dirname "$0")/../common.sh"

bash "$REPO/apt-dpkg/install.sh" "$@"
for hook in "$REPO"/ecosystems/*/install.sh; do
  [ -f "$hook" ] && bash "$hook"
done

log "done."
