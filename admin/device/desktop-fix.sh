#!/bin/bash
# desktop-fix.sh
# Run as the `mobian` user (the only sudo-capable account):
#     sudo bash ~/sudo-less/admin/device/desktop-fix.sh
#
# No options: it just applies every desktop fix for this box
# (Phosh on phoc/wlroots, Intel GeminiLake UHD 600).
#
#   1. i915 kernel params (GRUB):
#        i915.enable_psr=0 i915.enable_fbc=0 i915.enable_dc=0
#      for: phoc "connector DSI-1: Atomic commit failed: Device or resource busy"
#   2. restore /etc/phosh/phoc.ini (packaged) + [output:DSI-1] scale = 2
#   3. audio: re-point the default sink to the built-in analog output
#      (the configured default was a removed USB AB13X device)
#   4. geolocation: enable org.gnome.system.location
#   5. install thunar + tumbler + thunar-volman + xdg-utils and make thunar
#      the default folder handler (replaces nautilus, which cannot run under
#      Phosh because it needs org.gnome.Mutter.ServiceChannel)
#
# Root is needed for 1, 2 and 5. Steps 3-4 run as master.
# Reboot for step 1; re-login (or reboot) for step 2.

set -euo pipefail

STAMP="$(date +%Y%m%d-%H%M%S)"
PARAMS="i915.enable_psr=0 i915.enable_fbc=0 i915.enable_dc=0"

log()  { printf '==> %s\n' "$*"; }
warn() { printf '!!! %s\n' "$*" >&2; }

sudo -v

# run a command in master's user session (wpctl/gsettings/xdg-mime).
# HOME must be set explicitly, otherwise sudo keeps HOME=/root and
# gsettings/xdg-mime write to root's dconf/mimeapps instead of master's.
MNAME="$(id -un master 2>/dev/null || echo master)"
MUID="$(id -u master 2>/dev/null || echo 1001)"
MHOME="$(getent passwd "$MNAME" 2>/dev/null | cut -d: -f6)"
[ -n "$MHOME" ] || MHOME="/home/$MNAME"
MRT="/run/user/$MUID"
as_master() {
  sudo -H -u "$MNAME" -- env "HOME=$MHOME" "XDG_RUNTIME_DIR=$MRT" \
    "DBUS_SESSION_BUS_ADDRESS=unix:path=$MRT/bus" "$@"
}

# ------------------------------------------------- 1. i915 kernel params ----
log "kernel cmdline: $PARAMS"
if [ ! -f /etc/default/grub ]; then
  warn "/etc/default/grub not found; skipping"
else
  cp -a /etc/default/grub "/etc/default/grub.bak.$STAMP"
  MISSING=""
  for p in $PARAMS; do
    grep -q "$p" /etc/default/grub || MISSING="$MISSING $p"
  done
  if [ -n "$MISSING" ]; then
    sed -i "s|^\(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\)\"|\1$MISSING\"|" /etc/default/grub
    grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub
  else
    log "all i915 params already present"
  fi
  if command -v update-grub >/dev/null 2>&1; then
    update-grub
  elif [ -x /usr/sbin/update-grub ]; then
    /usr/sbin/update-grub
  else
    warn "update-grub not found; run it manually"
  fi
fi

# ------------------------------------------------------- 2. phoc.ini ----
log "restore /etc/phosh/phoc.ini"
PKG_INI=/usr/share/phosh/phoc.ini
if [ ! -f "$PKG_INI" ]; then
  warn "$PKG_INI missing; skipping"
else
  [ -f /etc/phosh/phoc.ini ] && cp -a /etc/phosh/phoc.ini "/etc/phosh/phoc.ini.bak.$STAMP"
  install -m 644 "$PKG_INI" /etc/phosh/phoc.ini
  cat >> /etc/phosh/phoc.ini <<'EOF'

# High-DPI DSI panel on this device
[output:DSI-1]
scale = 2
EOF
  log "wrote /etc/phosh/phoc.ini (backup: /etc/phosh/phoc.ini.bak.$STAMP)"
fi

# ------------------------------------------------ 3. default audio sink ----
log "fix stale default audio sink"
if ! command -v wpctl >/dev/null 2>&1; then
  warn "wpctl not found; skipping"
else
  SINK_ID="$(as_master wpctl status 2>/dev/null | awk '
    /Sinks:/{s=1; next}
    s && /Sources:/{s=0}
    s && /Built-in Audio Analog Stereo/ {
      for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+\.$/) { sub(/\./,"",$i); print $i; exit }
    }')"
  if [ -z "$SINK_ID" ]; then
    warn "could not find the built-in analog sink"
  else
    log "wpctl set-default $SINK_ID"
    as_master wpctl set-default "$SINK_ID" || warn "wpctl set-default failed"
  fi
fi

# ------------------------------------------------------ 4. geolocation ----
log "enable geolocation"
if command -v gsettings >/dev/null 2>&1; then
  as_master gsettings set org.gnome.system.location enabled true \
    || warn "gsettings set failed"
  printf '    now: '; as_master gsettings get org.gnome.system.location enabled || true
else
  warn "gsettings not found; skipping"
fi

# ----------------------------------------------------------- 5. thunar ----
log "install thunar"
env DEBIAN_FRONTEND=noninteractive apt-get install -y thunar tumbler thunar-volman xdg-utils \
  || warn "apt-get install failed"
log "set thunar as default folder handler"
if command -v xdg-mime >/dev/null 2>&1; then
  as_master xdg-mime default thunar.desktop inode/directory \
    || warn "xdg-mime default failed"
else
  warn "xdg-mime not found"
fi

echo
log "done."
echo "    - reboot to apply the i915 params:  sudo reboot"
echo "    - phoc.ini needs a re-login (audio/location are live now)"
echo "    - thunar: launch it from the app grid"
echo "    - backups: *.bak.$STAMP"
