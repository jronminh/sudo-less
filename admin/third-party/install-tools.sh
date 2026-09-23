#!/bin/bash
# install-tools.sh
# Run as the `mobian` user (the only sudo-capable account), once:
#     sudo bash ~/sudo-less/admin/third-party/install-tools.sh [--with-podman]
#
# One-time install of the extra packages `master` uses WITHOUT sudo:
#   - userspace toolchain (git/rg/jq/python venv/build tools)
#   - rootfs + sandbox tools (mmdebstrap, debootstrap, proot, bubblewrap)
#   - rootless container bits (uidmap, fuse-overlayfs, slirp4netns, fuse)
#
# Run admin/native/enable-userspace.sh first (user namespaces, subuid/subgid,
# PATH); most of these tools need it. Nothing here runs master's software as
# root: admin steps only enable userspace.

set -euo pipefail

WITH_PODMAN=0
[ "${1:-}" = "--with-podman" ] && WITH_PODMAN=1

echo "==> sudo check"
sudo -v

echo "==> apt update"
sudo apt-get update

PKGS="git curl wget ca-certificates unzip zip xz-utils zstd gpg \
ripgrep fd-find jq \
build-essential pkg-config \
python3 python3-venv python3-pip python3-dev \
mmdebstrap debootstrap proot \
uidmap fuse-overlayfs slirp4netns bubblewrap"

[ "$WITH_PODMAN" = 1 ] && PKGS="$PKGS podman distrobox"

echo "==> installing: $PKGS"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y $PKGS

echo "==> loading fuse at boot"
echo fuse | sudo tee /etc/modules-load.d/fuse.conf >/dev/null
sudo modprobe fuse 2>/dev/null || true

echo "==> linking fd -> fdfind for master"
FDFIND="$(command -v fdfind || true)"
if [ -n "$FDFIND" ]; then
  sudo -u master mkdir -p ~master/.local/bin
  sudo -u master ln -sf "$FDFIND" ~master/.local/bin/fd
fi

echo
echo "==> DONE. Summary:"
id master
getent group sudo
echo "subuid: $(grep '^master:' /etc/subuid || echo none)"
echo "subgid: $(grep '^master:' /etc/subgid || echo none)"
echo "-- tools:"
for t in git rg jq fdfind mmdebstrap debootstrap proot bwrap newuidmap newgidmap; do
  printf '   %-12s %s\n' "$t" "$(command -v "$t" || echo MISSING)"
done
echo
echo "master can now, WITHOUT sudo (with enable-userspace.sh done):"
echo "  - use git / rg / jq / python3 venvs / gcc / make"
echo "  - build a Debian rootfs:  mmdebstrap --mode=unshare ... ~/.local/share/rootfs"
echo "  - run rootless containers (if --with-podman was used)"
