# Master privileges — polkit + doas note

Date: 2026-09-21
Host: Debian forky/sid (Mobian-ish), user `master` (uid 1001)

Goal: give `master` an **Android-`shell`-like** role — per-action
authorization via polkit, no full root — plus a default-deny doas.

Update 2026-09-21: SMART access moved off polkit/wrapper to plain
unprivileged `smartctl` (udev `uaccess` + `CAP_SYS_RAWIO`); the old
`49-master-smart.rules` and `master-smart-check` wrapper were removed.

## Roles: `mobian` vs `master`

Two-persona split on this box.

**`mobian` (uid 1000) — admin / root delegate**
- Only member of `sudo` (`%sudo ALL=(ALL:ALL) ALL`); all root work is done here.
- Installs/updates packages, systemd units, udev rules, file capabilities,
  polkit rules; keeps system files root-owned.
- Owns host hardening (ufw, key-only sshd, fail2ban, AppArmor, sysctl,
  security-only unattended-upgrades).
- Owns privileged services: smartmontools + `cap_sys_rawio`, Waydroid (needs
  sudo), the setuid container stack (`newuidmap/newgidmap`).
- SSH admin account; runs the root-side prep scripts in `master`'s home
  (`admin-prep.sh`, `smart-install.sh`,
  `waydroid-install.sh`, `desktop-fix.sh`, `unlock.sh`).
- Recovery/repair: debugging, kernel/firmware, LUKS unlock.

**`master` (uid 1001) — unprivileged daily user**
- No sudo/root; holds the active `seat0` desktop session.
- Gets narrowly scoped powers only via polkit, groups, udev `uaccess`, and
  file capabilities (see below); runs the no-root half of the setup.

## Files changed

- `/etc/polkit-1/rules.d/49-master-android-shell.rules` (root:root 0644)
  - Sorted before `50-default.rules` (first matching rule wins).
- `/etc/doas.conf` (root:root 0600)
  - Default-deny: no `permit` rules, so doas grants nothing to anyone.
  - `master` running `doas id` => "Operation not permitted".

## SMART (unprivileged — not polkit)

- `/etc/udev/rules.d/60-jms583-uaccess.rules` (root:root 0644)
  - `TAG+="uaccess"` on the JMicron JMS583 (`152d:0583`) block + SCSI-generic
    nodes; logind gives the **active local session user** an rw ACL.
- `/usr/sbin/smartctl` carries `cap_sys_rawio=ep` (needed for the
  vendor-specific NVMe passthrough).
- `/etc/apt/apt.conf.d/99-smartctl-cap` re-applies that capability after a
  smartmontools upgrade (dpkg replaces the binary and drops the cap).
- `master` runs `smartctl -a /dev/sda` **directly** — no wrapper, pkexec, or
  polkit rule. smartctl 7.5 knows `152d:0583`, so no `-d` guesswork.
- `~/.local/bin/smartctl` → `/usr/sbin/smartctl` symlink: Debian's
  `/etc/profile` keeps `/usr/sbin` off a non-root `PATH`, so this makes
  `smartctl` work by name for `master`.
- Install/revert script: `~/sudo-less/admin/device/smart-install.sh`.

## What `master` may do (polkit grants)

| Area | Actions granted |
|---|---|
| Power | `login1.suspend`, `-suspend-multiple-sessions`, `reboot`, `-reboot-multiple-sessions`, `power-off`, `-power-off-multiple-sessions` |
| Settings | `hostname1.set-hostname`, `-set-static-hostname`, `-set-machine-info`, `locale1.set-locale`, `-set-keyboard`, `timedate1.set-time`, `-set-timezone`, `-set-ntp`, `-set-local-rtc` |
| Network | `NetworkManager.network-control`, `settings.modify.system`, `settings.modify.own`, `wifi.scan` |
| Storage | `udisks2.filesystem-mount`, `-mount-system`, `-mount-other-seat`, `-fstab`, `-unmount-others`, `eject-media` |
| Services | `systemd1.manage-units` — **scoped**: units `waydroid-container`, `NetworkManager`, `bluetooth`, `systemd-timesyncd`, `ssh`, `docker`; verbs `start`, `stop`, `restart`, `reload`, `try-restart`, `reload-or-restart` |

Deliberately **not** granted: `packagekit.package-install`,
`login1.manage`, and blanket (unscoped) `systemd1.manage-units`.

## Group memberships

- `master` is in `bluetooth` (pre-existing) — `bluetoothctl` works.
- **Revoked 2026-09-21:** `systemd-journal` and `input` were removed —
  `master` can no longer read the journal or `/dev/input/event*`.

Group changes take effect on next login; a running session keeps the old
groups until logout.

## Already worked without changes

- **Bluetooth** — `master` is in `bluetooth` group; `bluetoothctl` works.
- **Brightness** — `org.gnome.mutter.backlight-helper` is `active: yes`
  and `master` has an active GNOME session; brightness keys/UI work.
- **Display rotation** — session-level, no privilege.
- **Install userland apps** — `bun` (1.4.2) at `~/.local/bin/bun`;
  `bun install -g` goes to `~/.bun/bin`. Python: use a venv
  (`pip --user` is blocked by PEP 668). AppImages: `~/.local/bin`.

## Usage examples (as `master`, no root)

```bash
# network
nmcli dev wifi list
nmcli dev wifi connect "SSID" password "…"
nmcli con up "Wired connection 1"
nmcli radio wifi off
nmcli dev wifi hotspot ifname wlan0 ssid MyAP password 12345678

# storage
udisksctl mount   -b /dev/sdb1
udisksctl unmount -b /dev/sdb1
udisksctl eject   -b /dev/sr0
udisksctl power-off -b /dev/sdb
udisksctl unlock  -b /dev/sdb1          # LUKS
udisksctl mount   -b /dev/nvme0n1p2     # internal (mount-system)

# power
systemctl suspend
systemctl reboot
systemctl poweroff
loginctl lock-session

# settings
hostnamectl set-hostname mytab
localectl set-locale LANG=en_US.UTF-8
localectl set-keymap us
timedatectl set-timezone Asia/Bangkok
timedatectl set-ntp true

# services (only the six units, only safe verbs)
systemctl restart waydroid-container.service
systemctl restart NetworkManager.service
systemctl restart bluetooth.service

# logs / input — NOT available (journal/input groups revoked 2026-09-21)
# journalctl -b -p err                  # needs systemd-journal group
wtype "hello world"                     # Wayland text, no privilege

# SMART (unprivileged; needs the JMS583 bridge plugged in and an active
# local session for the uaccess ACL)
smartctl -a /dev/sda
smartctl -i /dev/sda
smartctl -t short /dev/sda              # self-test (writes to device)
```

## Verification

```bash
# check an action as master (rc 0 = yes, rc 2 = auth required)
sudo -u master pkcheck --action-id org.freedesktop.udisks2.filesystem-mount --process \$\$

# details-scoped manage-units cannot be checked via pkcheck as non-root;
# verify with a real call on an already-active unit (no-op).
# ALWAYS pass --no-ask-password, else the polkit agent pops up asking for
# mobian's password on the denied cases:
sudo -u master systemctl --no-ask-password start bluetooth.service        # rc=0 (allowed)
sudo -u master systemctl --no-ask-password start systemd-journald.service # denied (unit not listed)
sudo -u master systemctl --no-ask-password kill bluetooth.service         # denied (verb not listed)

# full checker (run as master; non-interactive, no prompts): ~/verify-privs.sh
#   covers: all polkit actions, the 6 services, groups, SMART, userland tools,
#   and the rootless container/rootfs stack

# watch decisions live
journalctl -t polkitd -f

# SMART as master (no root): should print the drive's SMART table
sudo -u master smartctl -a /dev/sda
```

## Risks / caveats

- ~~`input` group = keylogging all users/sessions~~ — **removed 2026-09-21**
  (it never enabled injection; `/dev/uinput` is `root:root 0600`).
- ~~`systemd-journal` group = read all logs~~ — **removed 2026-09-21**.
- `udisks2.filesystem-mount-system` = root-mounted internal partitions;
  read surface + DoS. udisks2 applies `nosuid,nodev` by default.
- `ssh.service` restart = remote DoS.
- `docker.service` = latent root if Docker is later installed and `master`
  gains docker access (currently not installed, unit absent, no socket).
- No direct root escalation found in the polkit grants themselves.
- `cap_sys_rawio` on the world-executable `smartctl`: anyone who can open the
  device (uaccess ACL = active seat user) can issue raw ATA/NVMe passthrough.
  Scoped by the udev ACL, not a full-root vector, but review it.
- `uaccess` covers only the **active local session** user — an SSH-only
  session as `master` will not get the ACL (device nodes stay root:disk).

## Revert

```bash
sudo rm -f /etc/polkit-1/rules.d/49-master-android-shell.rules
sudo systemctl restart polkit
# groups: systemd-journal/input already removed; to re-add (NOT recommended):
#   sudo gpasswd -a master systemd-journal && sudo gpasswd -a master input
# SMART unprivileged access:
sudo rm -f /etc/udev/rules.d/60-jms583-uaccess.rules \
             /etc/apt/apt.conf.d/99-smartctl-cap
sudo setcap -r /usr/sbin/smartctl
sudo udevadm control --reload-rules
# doas: keep default-deny /etc/doas.conf, or remove the file/package:
#   sudo apt remove opendoas
```
