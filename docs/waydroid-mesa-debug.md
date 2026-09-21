# Waydroid + Mesa debugging log

Date: 2026-09-21
Host: Debian forky/sid, Phosh (phoc), Intel Gemini Lake UHD 600, Mesa 26.1.6
Purpose: record every change made while debugging the Waydroid boot loop
(upstream hwcomposer / Mesa dmabuf bug). Reboot is pending.

--------------------------------------------------------------------------------
## 1. Root-cause fixes — KEEP

These fixed a real Debian packaging defect (cgroup mounted read-only in the LXC
container), which caused:
  libprocessgroup: Failed to make and chown /sys/fs/cgroup/uid_X: Read-only file system
  init: createProcessGroup(...) failed for service 'surfaceflinger'

- `/usr/lib/waydroid/data/configs/config_base`
    `lxc.mount.auto = cgroup:ro sys:ro proc`  ->  `cgroup:rw sys:ro proc`
    (backup at `config_base.bak`; this template is only re-read on `waydroid init`,
     and is silently reverted by waydroid package updates)
- `/var/lib/waydroid/lxc/waydroid/config`
    same one-line change to the *live* config (regenerated only by `waydroid init`)
- `/etc/systemd/system/waydroid-container.service.d/delegate.conf`  (NEW)
    ```
    [Service]
    Delegate=yes
    ```

## 2. Memory tuning — KEEP

- `/etc/default/zramswap`:  `ALGO=lz4` -> `ALGO=zstd`, `PERCENT=50` -> `PERCENT=100`
- Hot-added for the current boot only (not persistent):
    `/dev/zram1` = 3 GiB, zstd, priority 150  (via /sys/class/zram-control/hot_add)
    -> swap total went 1.8 G -> 4.8 G
- `/var/lib/waydroid/waydroid_base.prop`: appended `ro.config.low_ram=true`

## 3. Packages installed — KEEP (harmless)

- `opendoas` (doas, default-deny /etc/doas.conf)   [before Mesa debug]
- `wayland-utils` (provides `wayland-info`)
- `cage` (nested compositor experiment)

## 4. master Waydroid integration — KEEP

- `$HOME/.local/bin/waydroid-smart`  (on-demand start/stop, frees RAM)
- `$HOME/.local/bin/waydroid-nested` (cage+pixman attempt; did not work)
- `$HOME/.config/systemd/user/waydroid-session.service` (installed, DISABLED)
- `$HOME/.local/share/applications/waydroid-smart.desktop`

## 5. Mesa experiment — FULLY REVERTED

Tried to make phoc advertise fewer dmabuf modifiers (WLR_DRM_NO_MODIFIERS=1) to
dodge the hwcomposer crash. None of it worked and it was all undone:

- `/etc/environment`  : added `WLR_DRM_NO_MODIFIERS=1`        -> REMOVED (file deleted)
- `/etc/pam.d/greetd` : added `session required pam_env.so`   -> REMOVED
- `/etc/systemd/system/greetd.service.d/env.conf`             -> REMOVED (dir deleted)
- Restarted `greetd` ~14 times, which left the greeter crash-looping with
    `phoc: connector DSI-1: Atomic commit failed: Permission denied`
  (stuck DRM master state from the repeated restarts — NOT caused by the env var;
   it persisted after all the above were reverted).

## 6. Current state at time of writing

- `greetd` : **stopped** (to stop the flashing crash-loop)
- `phoc`   : killed (none running)
- Graphical session: down. **A reboot is required** to clear the stuck DRM state.
- Waydroid session: stopped.
- All experiment changes reverted; sections 1-4 remain in place.

## 7. Reboot checklist

1. Reboot.
2. Log in as `master` on tty7 (greetd/phrog will start fresh).
3. Verify fixes still present:
     grep cgroup /usr/lib/waydroid/data/configs/config_base   # expect cgroup:rw
     grep low_ram /var/lib/waydroid/waydroid_base.prop        # expect =true
     swapon --show                                            # zram, zstd config applies at boot
4. Waydroid: `waydroid-smart` (on-demand). Expect boot to still fail at the
   hwcomposer (`android_hardware_waydroid#75`) — open upstream bug, no fixed
   image (latest published: system 20260403, vendor 20260428 = what we have).

## 8. Unresolved

- Upstream bug `waydroid/android_hardware_waydroid#75`: hwcomposer aborts in
  `dmabuf_modifiers()` (Scudo heap corruption) -> surfaceflinger crash-loop ->
  Android never finishes booting. Triggered by Mesa 26.1.x's advertised
  format/modifier set. No Waydroid image update fixes it.
- Options not yet tried: pin/downgrade Mesa < 26.1; patch/rebuild hwcomposer.
