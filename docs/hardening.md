# Hardening record

Applied: 2026-09-20. Config backups live in `~/hardening-backup/`.
No passwords or secrets are stored in this file.

## This box (Debian sid, host `mobian`)

Packages installed: `ufw fail2ban apparmor apparmor-utils unattended-upgrades`

1. Firewall (ufw) — active
   - default deny incoming, allow outgoing
   - allow `192.168.0.0/24` -> tcp/22 (SSH from LAN)
   - revert: `sudo ufw disable && sudo ufw reset`
2. sshd — `/etc/ssh/sshd_config.d/99-hardening.conf`
   - `PermitRootLogin no`, `PasswordAuthentication no`,
     `KbdInteractiveAuthentication no`, `PubkeyAuthentication yes`,
     `AllowUsers mobian`, `MaxAuthTries 3`, `LoginGraceTime 20`,
     `X11Forwarding no`
   - backup: `~/hardening-backup/sshd_config.orig` (+ `.conf` copy)
   - revert: remove `99-hardening.conf`, `sudo systemctl restart ssh`
   - NOTE: only key `phone-key` (phone) is in `~/.ssh/authorized_keys`.
     Add another key with `ssh-copy-id` before relying on it.
3. sysctl — `/etc/sysctl.d/99-hardening.conf`
   - `kptr_restrict=2`, `dmesg_restrict=1`, `yama.ptrace_scope=2`,
     `rp_filter=1`, redirects/source-route off
   - revert: remove file, `sudo sysctl --system`
4. fail2ban — active, jail `sshd`
   - revert: `sudo systemctl disable --now fail2ban`
5. AppArmor — active (114 profiles; 15 enforce, 23 complain)
   - revert: `sudo systemctl disable --now apparmor`
6. unattended-upgrades — enabled, SECURITY ONLY
   - `50unattended-upgrades` edited: commented `label=Debian` (full sid),
     kept `Debian-Security`
   - backups: `~/hardening-backup/50unattended-upgrades.orig` / `.after`
   - revert: restore `.orig`
7. getty — text login moved from `tty2` to `tty12` (keeps a break-glass
   console but off the usual tty1-6; desktop stays on tty7).
   - `getty@tty2` disabled, `getty@tty12` enabled
   - revert: `sudo systemctl disable --now getty@tty12 && sudo systemctl enable --now getty@tty2`

## Phone (Termux, `u0_aXXX@192.168.0.10:8022`)

1. Added this box's public key (`admin-key`) to phone
   `~/.ssh/authorized_keys` (dir 700, file 600). Key login works both ways.
2. sshd — `$PREFIX/etc/ssh/sshd_config` (appended)
   - `PasswordAuthentication no`, `KbdInteractiveAuthentication no`,
     `PubkeyAuthentication yes`, `PermitRootLogin no`, `MaxAuthTries 3`
   - backup on phone: `~/hardening-backup/sshd_config.orig`
   - revert: restore that file and run `pkill sshd; sshd`
   - NOTE: Termux sshd is started manually (no service manager), so after a
     phone reboot run `sshd` to listen again.

## Still recommended (manual)

- Run `sudo apt full-upgrade` periodically (sid is rolling; auto is security-only).
- Consider LUKS full-disk encryption (reinstall-time decision).
- Keep `~/phone-opencode` and other data backed up; test restores.
