#!/bin/bash
# verify-privs.sh
# Verify the full "master" setup: polkit grants, groups, SMART, userland
# tools, and the rootless container/rootfs stack.
#
# polkit authorizes the CALLING user, so run this AS master:
#     sudo -u master bash ~/verify-master-privs.sh
# (or log in as master and run it directly)
set -u

me=$(id -un)
echo "=============================================="
echo " Privilege verification for user: $me"
echo "=============================================="
if [ "$me" != "master" ]; then
  echo "WARNING: you are '$me', not 'master' - results describe '$me'."
  echo
fi

ok=0; bad=0
p() { printf "  [ OK ] %s\n" "$1"; ok=$((ok+1)); }
x() { printf "  [FAIL] %s\n" "$1"; bad=$((bad+1)); }

echo
echo "--- polkit actions (pkcheck; run as the user) ---"
check() {
  if pkcheck --action-id "$1" --process $$ >/dev/null 2>&1; then p "$2"; else x "$2"; fi
}
# power
check org.freedesktop.login1.suspend                        "power: suspend"
check org.freedesktop.login1.suspend-multiple-sessions      "power: suspend (multi-session)"
check org.freedesktop.login1.reboot                         "power: reboot"
check org.freedesktop.login1.reboot-multiple-sessions       "power: reboot (multi-session)"
check org.freedesktop.login1.power-off                      "power: power-off"
check org.freedesktop.login1.power-off-multiple-sessions    "power: power-off (multi-session)"
# settings
check org.freedesktop.hostname1.set-hostname                "settings: hostname"
check org.freedesktop.hostname1.set-static-hostname         "settings: static hostname"
check org.freedesktop.hostname1.set-machine-info            "settings: machine-info"
check org.freedesktop.locale1.set-locale                    "settings: locale"
check org.freedesktop.locale1.set-keyboard                  "settings: keyboard"
check org.freedesktop.timedate1.set-time                    "settings: time"
check org.freedesktop.timedate1.set-timezone                "settings: timezone"
check org.freedesktop.timedate1.set-ntp                     "settings: ntp"
check org.freedesktop.timedate1.set-local-rtc               "settings: local rtc"
# network
check org.freedesktop.NetworkManager.network-control        "network: connect/disconnect"
check org.freedesktop.NetworkManager.settings.modify.system "network: edit system connections"
check org.freedesktop.NetworkManager.settings.modify.own    "network: edit own connections"
check org.freedesktop.NetworkManager.wifi.scan              "network: wifi scan"
# storage
check org.freedesktop.udisks2.filesystem-mount              "storage: mount removable"
check org.freedesktop.udisks2.filesystem-mount-system       "storage: mount internal"
check org.freedesktop.udisks2.filesystem-mount-other-seat   "storage: mount other seat"
check org.freedesktop.udisks2.filesystem-fstab              "storage: mount fstab"
check org.freedesktop.udisks2.filesystem-unmount-others     "storage: unmount others"
check org.freedesktop.udisks2.eject-media                   "storage: eject"

echo
echo "--- services (real systemctl; start on an active unit is a no-op) ---"
svc() {
  if systemctl is-active --quiet "$1"; then
    if systemctl --no-ask-password start "$1" >/dev/null 2>&1; then p "service control allowed: $1"; else x "service control allowed: $1"; fi
  else
    printf "  [SKIP] %s (not active; refusing to start it)\n" "$1"
  fi
}
for u in waydroid-container NetworkManager bluetooth systemd-timesyncd ssh docker; do
  svc "$u.service"
done

echo
echo "--- groups (bluetooth only; journal/input removed) ---"
if id -nG | tr ' ' '\n' | grep -qx bluetooth;       then p "group bluetooth"; else x "group bluetooth (needs re-login?)"; fi
if id -nG | tr ' ' '\n' | grep -qx systemd-journal; then x "still in systemd-journal (re-login required)"; else p "not in systemd-journal"; fi
if id -nG | tr ' ' '\n' | grep -qx input;           then x "still in input (re-login required)";           else p "not in input"; fi

echo
echo "--- SMART (unprivileged; bridge must be plugged in) ---"
smartbin="$(command -v smartctl 2>/dev/null || true)"
[ -n "$smartbin" ] || { [ -x /usr/sbin/smartctl ] && smartbin=/usr/sbin/smartctl; }
if [ -z "$smartbin" ]; then
  x "smartctl not found"
else
  getcapbin="$(command -v getcap 2>/dev/null || echo /usr/sbin/getcap)"
  smartreal="$(readlink -f "$smartbin" 2>/dev/null || echo "$smartbin")"
  if "$getcapbin" "$smartreal" 2>/dev/null | grep -q cap_sys_rawio; then p "smartctl has cap_sys_rawio"; else x "smartctl missing cap_sys_rawio"; fi
  dev=""
  for d in /dev/sda /dev/sdb /dev/sdc; do [ -b "$d" ] && dev="$d" && break; done
  if [ -n "$dev" ]; then
    if "$smartbin" -a "$dev" >/dev/null 2>&1; then p "smartctl reads $dev without root"; else x "smartctl cannot read $dev"; fi
  else
    printf "  [SKIP] no /dev/sdX attached (plug in the JMS583 bridge to test)\n"
  fi
fi

echo
echo "--- userland tools (no root) ---"
for t in bun grim slurp wtype wl-copy wl-paste rsync brightnessctl; do
  bin="$(command -v "$t" 2>/dev/null || true)"
  if [ -z "$bin" ]; then x "$t not found"; continue; fi
  miss=$(ldd "$bin" 2>/dev/null | grep -c "not found")
  if [ "$miss" -eq 0 ]; then p "$t present ($bin)"; else x "$t missing $miss lib(s)"; fi
done

echo
echo "--- rootless containers / rootfs ---"
if grep -q "^$me:" /etc/subuid 2>/dev/null && grep -q "^$me:" /etc/subgid 2>/dev/null; then
  p "subuid/subgid configured ($(grep "^$me:" /etc/subuid | cut -d: -f2-))"
else
  x "subuid/subgid missing"
fi
if unshare -Ur true 2>/dev/null; then p "unprivileged userns (unshare -Ur)"; else x "unshare -Ur failed"; fi
if command -v podman >/dev/null 2>&1; then
  info=$(cd "$HOME" && podman info --format '{{.Host.Security.Rootless}} driver={{.Store.GraphDriverName}}' 2>/dev/null)
  case "$info" in
    true*) p "rootless podman ($info)";;
    *)     x "podman not rootless ($info)";;
  esac
else
  x "podman not found"
fi
if command -v distrobox >/dev/null 2>&1; then
  p "distrobox present ($(distrobox --version 2>/dev/null | head -1))"
else
  x "distrobox not found"
fi

echo
echo "--- negative controls (these SHOULD be denied) ---"
neg() { if "$@" >/dev/null 2>&1; then x "NOT denied: $*"; else p "correctly denied: $*"; fi; }
neg systemctl --no-ask-password start systemd-journald.service
neg systemctl --no-ask-password kill bluetooth.service
neg doas id
neg journalctl --system -n 1 --no-pager
neg test -r /dev/input/event0
if pkcheck --action-id org.freedesktop.packagekit.package-install --process $$ >/dev/null 2>&1; then
  x "package-install NOT denied"
else
  p "correctly denied: package-install"
fi

echo
echo "=============================================="
printf " passed: %d   failed: %d\n" "$ok" "$bad"
echo "=============================================="
echo "Note: if group checks fail, log out and back in (groups apply on new login)."
