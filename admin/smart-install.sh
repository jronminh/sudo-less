#!/bin/bash
# smart-install.sh
# Run as the `mobian` user (the only sudo-capable account):
#     sudo bash ~/sudo-less/admin/smart-install.sh
#
# Gives `master` unprivileged SMART access to the USB NVMe (JMicron JMS583
# bridge, USB id 152d:0583) WITHOUT root, the disk group, sudo, pkexec, or a
# wrapper:
#   - installs smartmontools
#   - adds a udev rule granting the active local session user read-write
#     access to the bridge's block + SCSI-generic nodes (TAG+="uaccess")
#   - sets CAP_SYS_RAWIO on /usr/sbin/smartctl (needed for the
#     vendor-specific NVMe passthrough), re-applied after upgrades via an
#     apt hook
#   - smartctl 7.5 knows 152d:0583, so `smartctl -a /dev/sda` just works
#
# Revert:
#   sudo rm -f /etc/udev/rules.d/60-jms583-uaccess.rules \
#                /etc/apt/apt.conf.d/99-smartctl-cap
#   sudo setcap -r /usr/sbin/smartctl
#   sudo udevadm control --reload-rules
#   sudo apt-get remove -y smartmontools   # optional

set -euo pipefail

UDEV=/etc/udev/rules.d/60-jms583-uaccess.rules
APTHOOK=/etc/apt/apt.conf.d/99-smartctl-cap

echo "==> sudo check"
sudo -v

echo "==> installing smartmontools"
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y smartmontools

echo "==> installing udev uaccess rule: $UDEV"
sudo tee "$UDEV" >/dev/null <<'EOF'
# 60-jms583-uaccess.rules
# JMicron JMS583 (USB 152d:0583) NVMe bridge.
# Grant the active local session user (logind ACL via TAG+="uaccess")
# read-write access to the block and SCSI-generic nodes, so unprivileged
# smartctl can issue SMART / NVMe passthrough without root, a wrapper, or
# the disk group. smartctl also needs CAP_SYS_RAWIO (setcap) for the
# vendor-specific passthrough commands.
ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd[a-z]", ATTRS{idVendor}=="152d", ATTRS{idProduct}=="0583", TAG+="uaccess"
ACTION=="add|change", SUBSYSTEM=="scsi_generic", KERNEL=="sg[0-9]*", ATTRS{idVendor}=="152d", ATTRS{idProduct}=="0583", TAG+="uaccess"
EOF
sudo chown root:root "$UDEV"
sudo chmod 0644 "$UDEV"

echo "==> granting CAP_SYS_RAWIO to smartctl"
sudo setcap cap_sys_rawio+ep /usr/sbin/smartctl

echo "==> installing apt hook: $APTHOOK"
sudo tee "$APTHOOK" >/dev/null <<'EOF'
// 99-smartctl-cap — re-apply the file capability smartctl needs for
// unprivileged SMART access; package upgrades replace the binary and drop
// the capability.
DPkg::Post-Invoke { "getcap /usr/sbin/smartctl 2>/dev/null | grep -q cap_sys_rawio || setcap cap_sys_rawio+ep /usr/sbin/smartctl || true"; };
EOF
sudo chown root:root "$APTHOOK"
sudo chmod 0644 "$APTHOOK"

echo "==> reloading udev"
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=block --subsystem-match=scsi_generic

echo
echo "Done. As master, plug in the JMS583 bridge and run:"
echo "    smartctl -a /dev/sda"
