#!/bin/bash
# admin-prep.sh
# Run as the `mobian` user (the only sudo-capable account):
#     sudo bash ~/sudo-less/admin/admin-prep.sh [--with-podman]
#
# One-shot root-level prep so `master` can do everything WITHOUT sudo:
#   - userspace toolchain (git/rg/jq/python venv/build tools)
#   - unprivileged user namespaces + subuid/subgid for master
#   - rootless container bits (uidmap, fuse-overlayfs, slirp4netns, fuse)
#   - ~/.local/bin on PATH for all users

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

echo "==> enabling unprivileged user namespaces"
sudo install -d /etc/sysctl.d
printf '%s\n' \
  'kernel.unprivileged_userns_clone = 1' \
  'user.max_user_namespaces = 14030' \
  | sudo tee /etc/sysctl.d/99-userns.conf >/dev/null
sudo sysctl --system >/dev/null 2>&1 || true

echo "==> ensuring subuid/subgid for master"
grep -q '^master:' /etc/subuid 2>/dev/null || sudo usermod --add-subuids 165536-231071 master
grep -q '^master:' /etc/subgid 2>/dev/null || sudo usermod --add-subgids 165536-231071 master

echo "==> loading fuse at boot"
echo fuse | sudo tee /etc/modules-load.d/fuse.conf >/dev/null
sudo modprobe fuse 2>/dev/null || true

echo "==> adding ~/.local/bin to PATH (all users, login shells)"
printf '%s\n' \
  'if [ -d "$HOME/.local/bin" ]; then' \
  '  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH";; esac' \
  'fi' \
  'export PATH' \
  | sudo tee /etc/profile.d/50-local-bin.sh >/dev/null
sudo chmod 644 /etc/profile.d/50-local-bin.sh

echo "==> preparing master's userspace dirs"
sudo -u master mkdir -p ~master/.local/bin ~master/.local/lib ~master/.local/share/rootfs

echo "==> linking fd -> fdfind for master"
FDFIND="$(command -v fdfind || true)"
if [ -n "$FDFIND" ]; then
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
echo "master can now, WITHOUT sudo:"
echo "  - use git / rg / jq / python3 venvs / gcc / make"
echo "  - build a Debian rootfs:  mmdebstrap --mode=unshare ... ~/.local/share/rootfs"
echo "  - run rootless containers (if --with-podman was used)"
