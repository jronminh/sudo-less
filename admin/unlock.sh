#!/bin/bash
# unlock.sh
# Run as ROOT from a GRUB recovery / single-user shell to regain access
# to the `mobian` admin account (or run the toolchain prep) without a login.
#
# Usage:  bash ~/sudo-less/admin/unlock.sh [status|passwd|unlock|prep|addmaster|shell]

set -uo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

if [ "$(id -u)" -ne 0 ]; then
  echo "!! Must run as root. Boot via GRUB (init=/bin/bash) first." >&2
  exit 1
fi

echo "[*] mounting pseudo-filesystems (ignore errors if already mounted)"
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sys /sys 2>/dev/null || true
mount -t devtmpfs dev /dev 2>/dev/null || true
echo "[*] remounting / read-write"
mount -o remount,rw / 2>/dev/null || true

ACTION="${1:-status}"

show_status() {
  echo
  echo "===== STATUS ====="
  echo "-- passwd -S mobian:"; passwd -S mobian 2>&1 || true
  echo "-- id mobian:";       id mobian 2>&1 || true
  echo "-- sudo group:";      getent group sudo 2>&1 || true
  echo "-- adm group:";       getent group adm 2>&1 || true
  echo "-- /etc/sudoers.d:";  ls -la /etc/sudoers.d/ 2>&1 || true
  echo "-- sshd hardening:";  cat /etc/ssh/sshd_config.d/99-hardening.conf 2>&1 || true
  echo "-- authorized_keys (mobian):"
  ls -la /home/mobian/.ssh/ 2>&1 || true
  echo "=================="
  echo
}

case "$ACTION" in
  status)
    show_status
    ;;

  unlock)
    show_status
    echo "[*] unlocking mobian account (clearing '!' lock, keeping password)"
    passwd -u mobian 2>&1 || usermod -U mobian 2>&1 || true
    passwd -S mobian 2>&1 || true
    ;;

  passwd)
    show_status
    echo "[*] Resetting password for 'mobian' (type the NEW password twice):"
    passwd mobian
    echo "[*] ensuring account is unlocked"
    passwd -u mobian 2>&1 || usermod -U mobian 2>&1 || true
    echo "[*] ensuring mobian is in sudo group"
    usermod -aG sudo mobian 2>&1 || true
    echo "[*] new state:"; passwd -S mobian 2>&1 || true
    id mobian 2>&1 || true
    ;;

  addmaster)
    echo "[*] WARNING: this gives the 'master' user sudo (weakens hardening)"
    read -r -p "type YES to continue: " ok
    [ "$ok" = "YES" ] || { echo "aborted"; exit 1; }
    usermod -aG sudo master
    id master
    ;;

  prep)
    echo "[*] Installing toolchain prep packages (needs network)."
    echo "[*] NOTE: from a recovery shell networking is usually DOWN."
    echo "[*] If apt fails, reboot normally and run this as mobian instead."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      git ripgrep jq unzip \
      build-essential python3-venv python3-pip \
      mmdebstrap debootstrap proot \
      uidmap fuse-overlayfs slirp4netns
    ;;

  shell)
    echo "[*] dropping to root shell"; exec /bin/bash
    ;;

  *)
    echo "usage: $0 {status|passwd|unlock|prep|addmaster|shell}" >&2
    exit 2
    ;;
esac

echo
echo "[*] done."
echo "[*] Continue booting normally with:   exec /sbin/init"
echo "[*] or hard reboot with:              reboot -f"
