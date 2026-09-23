#!/bin/bash
# enable-userspace.sh
# Run as the `mobian` user (the only sudo-capable account), once:
#     sudo bash ~/sudo-less/admin/native/enable-userspace.sh [USER]
#
# One-time enablement so USER (default: master) can run software in userspace
# WITHOUT sudo, using base-system tools only (sysctl, usermod, install) — no
# packages are installed. Admin steps here only enable userspace; they never
# run the user's software as root.
#   - unprivileged user namespaces (unshare -Ur, overlayfs in a userns >= 5.11):
#     enough for `tools/prefix-run.sh --mode overlay-native`
#   - subuid/subgid for USER (rootless containers, mmdebstrap --mode=unshare)
#   - ~/.local/bin on PATH for all users
#   - USER's userspace dirs
#
# Extra tools (bwrap, uidmap, mmdebstrap, proot, podman) are separate:
# admin/third-party/install-tools.sh.

set -euo pipefail

U="${1:-master}"
id "$U" >/dev/null 2>&1 || { echo "no such user: $U" >&2; exit 1; }
H="$(getent passwd "$U" | cut -d: -f6)"

echo "==> sudo check"
sudo -v

echo "==> enabling unprivileged user namespaces"
sudo install -d /etc/sysctl.d
printf '%s\n' \
  'kernel.unprivileged_userns_clone = 1' \
  'user.max_user_namespaces = 14030' \
  | sudo tee /etc/sysctl.d/99-userns.conf >/dev/null
sudo sysctl --system >/dev/null 2>&1 || true

echo "==> ensuring subuid/subgid for $U"
grep -q "^$U:" /etc/subuid 2>/dev/null || sudo usermod --add-subuids 165536-231071 "$U"
grep -q "^$U:" /etc/subgid 2>/dev/null || sudo usermod --add-subgids 165536-231071 "$U"

echo "==> adding ~/.local/bin to PATH (all users, login shells)"
printf '%s\n' \
  'if [ -d "$HOME/.local/bin" ]; then' \
  '  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH";; esac' \
  'fi' \
  'export PATH' \
  | sudo tee /etc/profile.d/50-local-bin.sh >/dev/null
sudo chmod 644 /etc/profile.d/50-local-bin.sh

echo "==> preparing $U's userspace dirs"
sudo -u "$U" mkdir -p "$H/.local/bin" "$H/.local/lib" "$H/.local/share/rootfs"

echo
echo "==> DONE."
echo "subuid: $(grep "^$U:" /etc/subuid || echo none)"
echo "subgid: $(grep "^$U:" /etc/subgid || echo none)"
echo "userns: $(sudo -u "$U" unshare -Ur true 2>/dev/null && echo ok || echo FAILED)"
echo
echo "$U can now, WITHOUT sudo:"
echo "  - run packages from ~/.local with the prefix overlaid on /usr,/etc:"
echo "      tools/prefix-run.sh --mode overlay-native CMD"
echo "  - for bwrap, rootless containers and mmdebstrap, also run"
echo "      admin/third-party/install-tools.sh"
