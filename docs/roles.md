# Roles: `mobian` vs `master`

Two-persona split on this box (Debian forky/sid, host `mobian`, x86_64).

## `mobian` (uid 1000) — admin / root delegate

- Only member of `sudo` (`%sudo ALL=(ALL:ALL) ALL`); **all** root work happens
  here.
- Installs/updates packages, systemd units, udev rules, file capabilities,
  polkit rules; keeps system files root-owned.
- Owns host hardening (ufw, key-only sshd, fail2ban, AppArmor, sysctl,
  security-only unattended-upgrades) — see `hardening.md`.
- Owns privileged services: smartmontools + `cap_sys_rawio`, Waydroid, the
  setuid container stack (`newuidmap`/`newgidmap`).
- SSH admin account; runs the root-side prep in `../admin/` once:
  `sudo bash ~/sudo-less/admin/native/enable-userspace.sh` (base tools only), then
  `sudo bash ~/sudo-less/admin/third-party/install-tools.sh [--with-podman]`.
- **Admin enables, never runs.** Every script in `../admin/` is one-time
  enablement so `master` can run software in userspace. None of them runs
  `master`'s software as root; a per-run `sudo` path would be an escape hatch,
  not a feature.

## `master` (uid 1001) — unprivileged daily user

- **No sudo, no root.** Holds the active desktop session.
- Runs the no-root half of every task: `deb2home`, user namespaces, rootless
  podman, mmdebstrap+proot, userspace apt/dpkg (this repo).
- Powers off / suspends / reboots, edits hostname/locale/time, manages
  NetworkManager, mounts disks, and restarts a small allowlist of services via
  **polkit** (no password, no `pkexec`) — see `polkit.md`.
- Uses devices via udev `uaccess` and file capabilities (e.g. `smartctl` on the
  USB-NVMe bridge).

## What `master` may do without root (summary)

| area | mechanism | actions |
|---|---|---|
| power | polkit | `systemctl suspend\|reboot\|poweroff` |
| settings | polkit | `hostnamectl set-hostname`, `localectl`, `timedatectl` |
| network | polkit | `nmcli` connect/disconnect, edit connections, wifi scan |
| storage | polkit | `udisksctl mount\|unmount\|eject\|power-off\|unlock` |
| services | polkit | start/stop/restart/reload on `waydroid-container, NetworkManager, bluetooth, systemd-timesyncd, ssh, docker` **only** |
| SMART | udev `uaccess` + `CAP_SYS_RAWIO` on `smartctl` | `smartctl -a /dev/sda` (active local session only) |
| userspace | (none needed) | user namespaces, subuid/subgid, rootless podman/distrobox |

Everything else (`apt install`, other units, arbitrary `pkexec`) is denied or
would require `mobian`'s password. Do not rely on it.

## Package management (two lanes)

- **System packages** — `mobian` only: `sudo apt update && sudo apt upgrade`,
  writing `/usr`, `/etc`, `/var`, db `/var/lib/dpkg`.
- **User-space packages** — `master`: the userspace apt from this repo
  (`apt-get ...` into `~/.local`, db `~/.local/var/lib/dpkg`). Seeded system
  packages are held and the userspace apt refuses to run as root, so the two
  lanes never cross.

## Hard rules

- Never `sudo`/`su` as `master` (always fails: "not in the sudoers file").
- **Keep at least one working privileged path.** On a single-user device,
  de-privileging the only user can soft-lock you out of `sudo`/root; recover
  with a GRUB `init=/bin/bash` shell + `../admin/native/unlock.sh`.
- Never weaken host hardening.
- Root/admin changes go through `mobian`, ideally via a script in `../admin/`.
