#!/bin/bash
# enable-userspace.sh
# Run once, as an account that has sudo:
#     bash admin/enable-userspace.sh USER
#
# One-time enablement so USER can run software in userspace
# WITHOUT sudo, using base-system tools only (sysctl, usermod, install) — no
# packages are installed. Admin steps here only enable userspace; they never
# run the user's software as root.
#   - unprivileged user namespaces (unshare -Ur, overlayfs in a userns >= 5.11):
#     enough for `tools/prefix-run.sh --mode overlay-native`
#   - ~/.local/bin on PATH for all users
#   - USER's userspace dirs
#
# Nothing else is installed: unprivileged tools (bwrap, ...) the user
# installs with the userspace apt.

set -euo pipefail

U="${1:?usage: enable-userspace.sh USER}"
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

echo "==> adding ~/.local/bin to PATH (all users, login shells)"
printf '%s\n' \
  'if [ -d "$HOME/.local/bin" ]; then' \
  '  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH";; esac' \
  'fi' \
  'export PATH' \
  | sudo tee /etc/profile.d/50-local-bin.sh >/dev/null
sudo chmod 644 /etc/profile.d/50-local-bin.sh

echo "==> preparing $U's userspace dirs"
sudo -u "$U" mkdir -p "$H/.local/bin" "$H/.local/lib"

echo
echo "==> DONE."
echo "userns: $(sudo -u "$U" unshare -Ur true 2>/dev/null && echo ok || echo FAILED)"
echo
echo "$U can now, WITHOUT sudo:"
echo "  - run packages from ~/.local with the prefix overlaid on /usr,/etc:"
echo "      tools/prefix-run.sh --mode overlay-native CMD"
echo "  - install bwrap, ... with the userspace apt (apt-get install ...)"
