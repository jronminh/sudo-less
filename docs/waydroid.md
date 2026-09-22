# Waydroid on this box

Status: **working** (as of 2026-09-22) — boots, fits the screen, apps show
in the app grid. Install/container-level work is root (`mobian` with sudo);
day-to-day use (`waydroid session start`, launching apps) is `master`, no
sudo. Full story, including the resolution/HiDPI bugs and their fixes:
[`waydroid-mesa-debug.md`](waydroid-mesa-debug.md). Small scripts/units live
in [`../waydroid/`](../waydroid/); the large binaries they depend on
(extracted old Mesa, Android images) are **not** in this repo — see that
folder's note in `waydroid-mesa-debug.md` for where they actually live.

The multi-window freeform divide-by-zero is **fixed** (§15) by overlaying a
patched `services.jar` — a good example of the sudo-less split: the build
runs unprivileged (`../waydroid/patch-services-jar.sh`, done on the phone
`fe2`), and only the final overlay copy needs the admin account
(`../admin/waydroid-install-framework-overlay.sh`). A separate SystemUI NPE
still crash-loops multi-window; single-window is the stable daily state.

Official docs: https://docs.waydro.id/usage/install-on-desktops
Installer script: `~/sudo-less/admin/waydroid-install.sh` — run with
`sudo bash ~/sudo-less/admin/waydroid-install.sh`.

## Environment checks

- Wayland session active (`WAYLAND_DISPLAY=wayland-0`) — OK
- GPU: Intel i915 (Gemini Lake UHD 600), `/dev/dri/card0` + `renderD128` — OK
- Bare metal, systemd, cgroup2, unprivileged userns enabled — OK
- Binder module (`binder_linux.ko.xz`) present but not loaded; `CONFIG_ANDROID_BINDERFS` is NOT set
  → **binderfs absent → legacy `/dev/binder` fallback, needs runtime test**
- Low RAM: ~3.6 GB total, ~540 MB free at idle + ~1.6 GB swap — Android will be slow
- Deps (lxc, pkexec, python3-gbinder, nftables) auto-pulled by `apt install waydroid`

## After install

1. Start the session **without sudo** as the desktop user:
   `waydroid session start`
2. Launch full-screen UI:
   `waydroid show-full-ui`

## Revert / cleanup

Per the official docs:
```bash
waydroid session stop
sudo waydroid container stop
sudo apt remove waydroid
sudo rm -rf /var/lib/waydroid /home/.waydroid ~/waydroid ~/.share/waydroid ~/.local/share/applications/*aydroid* ~/.local/share/waydroid
```
Then reboot.

## Note

`mobian` also has opencode installed, so debugging can be done from that account too.
