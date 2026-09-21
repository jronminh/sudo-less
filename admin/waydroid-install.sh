#!/bin/bash
# waydroid-install.sh
# Run as the `mobian` user (the only sudo-capable account):
#     sudo bash ~/sudo-less/admin/waydroid-install.sh
#
# Installs waydroid from the official Debian repo, loads the binder
# module, initializes the Android images, and enables the container
# service.
#
#   1. apt-get update + install waydroid (pulls lxc, pkexec,
#      python3-gbinder, nftables).
#   2. Load binder_linux module; report binderfs vs legacy fallback.
#   3. waydroid init (downloads system+vendor images from ota.waydro.id).
#   4. Enable systemd waydroid-container service.
#
# Root is needed throughout. Run with sudo as the mobian user.

set -euo pipefail

log()  { printf '==> %s\n' "$*"; }
warn() { printf '!!! %s\n' "$*" >&2; }

sudo -v

# --------------------------------------------------------- 1. root check --
if [ "$(id -u)" -ne 0 ]; then
  warn "this script must be run as root. Use: sudo bash ~/sudo-less/admin/waydroid-install.sh"
  exit 1
fi

# ------------------------------------------------------- 2. apt update ----
log "apt-get update"
apt-get update

# ------------------------------------------------------- 3. install ------
log "install waydroid (pulls lxc, pkexec, python3-gbinder, nftables)"
DEBIAN_FRONTEND=noninteractive apt-get install -y waydroid

# --------------------------------------------------- 4. binder module -----
log "load binder_linux module"
modprobe binder_linux devices="anbox-binder,anbox-vndbinder,anbox-hwbinder" || warn "modprobe binder_linux failed; continuing"

if grep -qw binder /proc/filesystems 2>/dev/null; then
  log "binderfs is available (/proc/filesystems contains binder)"
else
  warn "binderfs NOT set in /proc/filesystems — Waydroid will use the legacy /dev/binder fallback (needs runtime test)"
fi

log "binder nodes:"
ls -l /dev/*binder* 2>/dev/null || warn "no /dev/*binder* nodes found"

# ------------------------------------------------------- 5. init ---------
log "waydroid init (downloads system+vendor images from https://ota.waydro.id/system and /vendor)"
waydroid init

# ------------------------------------------------------- 6. service ------
log "enable waydroid-container service"
systemctl enable --now waydroid-container

# ------------------------------------------------------- 7. next steps ----
echo
log "install complete."
echo "    Start the session WITHOUT sudo as the desktop user:"
echo "      waydroid session start"
echo "    Then launch full UI:"
echo "      waydroid show-full-ui"
echo ""
echo "    !!! RAM WARNING: this box has ~3.6 GB total / ~540 MB free at idle"
echo "       (+ ~1.6 GB swap). Android will be slow. Close other apps first."
