#!/bin/bash
# install-tools.sh
# Run as the `mobian` user (the only sudo-capable account), once:
#     sudo bash ~/sudo-less/third-party/install-tools.sh [--with-podman]
#
# Installs ONLY what `master` cannot install for themselves. A package belongs
# here when it needs root to work, not merely to be installed:
#   - uidmap: setuid newuidmap/newgidmap, which map the subuid/subgid ranges
#     (rootless podman)
#   - fuse3 + the fuse module at boot: setuid fusermount3 and /dev/fuse
#     (AppImages, sshfs, fuse-overlayfs outside a userns)
#   - --with-podman: podman + distrobox (system config under /etc/containers,
#     conmon/runc/netavark helpers); optional
#
# Everything else (bubblewrap, slirp4netns,
# fuse-overlayfs, git, rg, jq, ...) is ordinary unprivileged software: master
# installs it with the userspace apt into ~/.local.
#
# Run admin/enable-userspace.sh first (user namespaces, subuid/subgid,
# PATH). Nothing here runs master's software as root: admin steps only enable
# userspace.

set -euo pipefail

WITH_PODMAN=0
[ "${1:-}" = "--with-podman" ] && WITH_PODMAN=1

echo "==> sudo check"
sudo -v

echo "==> apt update"
sudo apt-get update

PKGS="uidmap fuse3"
[ "$WITH_PODMAN" = 1 ] && PKGS="$PKGS podman distrobox"

echo "==> installing: $PKGS"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y $PKGS

echo "==> loading fuse at boot"
echo fuse | sudo tee /etc/modules-load.d/fuse.conf >/dev/null
sudo modprobe fuse 2>/dev/null || true

echo
echo "==> DONE. Summary:"
echo "subuid: $(grep '^master:' /etc/subuid || echo none)"
echo "subgid: $(grep '^master:' /etc/subgid || echo none)"
for t in newuidmap newgidmap fusermount3; do
  p="$(command -v "$t" || true)"
  printf '   %-12s %s\n' "$t" "${p:-MISSING}$( [ -n "$p" ] && [ -u "$p" ] && echo ' (setuid)')"
done
printf '   %-12s %s\n' /dev/fuse "$( [ -c /dev/fuse ] && echo ok || echo MISSING)"
[ "$WITH_PODMAN" = 1 ] && printf '   %-12s %s\n' podman "$(command -v podman || echo MISSING)"
echo
echo "master now installs the rest WITHOUT sudo, e.g.:"
echo "  apt-get install bubblewrap slirp4netns fuse-overlayfs"
