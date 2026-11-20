#!/usr/bin/env bash
# Install runtime configuration for the userspace apt/dpkg (apt-dpkg/install.sh).
# This is the stable entrypoint other scripts call.
#
# Re-running is safe. Options:
#   --reseed      refresh the seeded status from the system
#   --no-shell    do not touch ~/.bashrc / ~/.profile
source "$(dirname "$0")/../common.sh"

bash "$REPO/apt-dpkg/install.sh" "$@"

log "done."
