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

## 8. Unresolved (as of this original log — see §9 below, this got fixed)

- Upstream bug `waydroid/android_hardware_waydroid#75`: hwcomposer aborts in
  `dmabuf_modifiers()` (Scudo heap corruption) -> surfaceflinger crash-loop ->
  Android never finishes booting. Triggered by Mesa 26.1.x's advertised
  format/modifier set. No Waydroid image update fixes it.
- Options not yet tried: pin/downgrade Mesa < 26.1; patch/rebuild hwcomposer.

---

## 9. Correction — this WAS solved, just never written back here

A separate, later work folder (`/opt/waydroid-work/`, not referenced from
this repo until now) shows the bug above was root-caused and fixed the same
day, continuing past where this log stops. TL;DR: **run the compositor
Waydroid talks to on Mesa 25.0.7 instead of system Mesa 26.1.x.**

- Confirmed root cause: Mesa 26.x advertises 273 dmabuf format/modifier
  pairs on this Intel GPU vs. 197 on Mesa 25.0.7; Waydroid's hwcomposer has
  a heap-corruption bug walking the larger set. Old bug (since 2023) — the
  *Waydroid image* was never the problem, only the host's Mesa version.
- Fix built two ways, both keeping the *system* Mesa install untouched — an
  isolated Mesa 25.0.7 tree is extracted (not installed) to
  `/opt/waydroid-work/old-mesa/` (168MB) via
  [`../waydroid/fetch-old-mesa.sh`](../waydroid/fetch-old-mesa.sh):
  1. **Nested**: a throwaway `cage` compositor loads old Mesa via
     `LD_LIBRARY_PATH` and hosts just the Waydroid session — the original
     `bin/waydroid-oldmesa` launcher script in that work folder.
  2. **Native (whole desktop)**: `/usr/bin/phoc` itself becomes a wrapper
     that sets `LD_LIBRARY_PATH`/`LIBGL_DRIVERS_PATH`/
     `__EGL_VENDOR_LIBRARY_DIRS` to `old-mesa/` and execs the real binary
     (preserved as `/usr/bin/phoc.real`) — the whole desktop runs Mesa
     25.0.7, Waydroid is a normal session, no `cage` needed. **This is the
     one actually live** as of 2026-09-22 (confirmed via
     `/proc/<phoc-pid>/environ` and `/proc/<phoc-pid>/maps` — though maps
     showed *both* Mesa 26.1.6's and 25.0.7's `libgallium` loaded at once, a
     mixed state worth cleaning up eventually; left alone for now to stay
     focused on Waydroid itself, not the desktop compositor).
- Multi-window mode (`persist.waydroid.multi_windows=true`) has an open
  upstream bug: Android's freeform layout divides by zero
  (`LaunchParamsUtil.getDefaultFreeformSize`, `waydroid/waydroid#1446`) when
  display stable bounds are 0x0 at boot → `system_server` dies. Docs here
  originally said "do NOT use that path." Retested 2026-09-22: enabled it,
  restarted the session, launched an app — booted and ran without the crash
  for ~35s (`system_server`/`zygote`/`webview_zygote` all alive). Not fully
  characterized — don't assume the upstream bug is simply gone, retest
  deliberately before relying on multi-window.
- Whoever removed the `waydroid` apt package (apt history:
  `apt-get -y remove thunar thunar-data thunar-volman waydroid nautilus
  nautilus-data gnome-sushi` at 2026-09-21 13:59:26, batched with two file
  managers — reads like a GUI-declutter pass that happened to catch
  Waydroid, not "Waydroid was a dead end") did so **8 minutes after** the
  work folder's own "FINAL WORKING STATE" entry (13:51). The fix was never
  a failure; it just wasn't reflected back into this repo before the
  package got swept up in an unrelated cleanup.

## 10. Reinstall (2026-09-22) — what survives, what doesn't

Reinstalled clean: `apt-mark unhold waydroid lxc lxcfs liblxc-common && apt
install waydroid` (as `mobian`; more than just `waydroid` had been purged —
`lxc`/`lxcfs`/`liblxc-common` were also held, `python3-gbinder`/
`liblxc1t64` fully gone). Notable, in case this happens again:

- `/opt/waydroid-work/` and `/var/lib/waydroid/` (images, LXC container
  state, overlays) are **not** owned/touched by the `waydroid` package at
  all — `apt remove`/`apt install` never deletes or recreates them. Only
  `/usr`, `/etc` package-owned files, and the dpkg database entry, actually
  get removed/reinstalled. So a from-scratch reinstall does **not** mean a
  from-scratch container — the Android images, LXC config, and this whole
  `/opt/waydroid-work` folder had silently survived the whole time.
  `waydroid-container.service` came back up immediately post-install,
  reusing all of it, no `waydroid init` needed.
- What genuinely doesn't survive a reinstall: `/usr/lib/waydroid/data/
  configs/config_base` (the cgroup `ro`→`rw` fix from §1 — package-owned,
  gets reset to packaged defaults) and `/var/lib/waydroid/waydroid_base.prop`
  (props reset to fresh defaults, `ro.config.low_ram=true` lost). Both
  needed redoing after reinstall; the live LXC config
  (`/var/lib/waydroid/lxc/waydroid/config`) needed the same cgroup fix too,
  then `systemctl restart waydroid-container.service` to pick it up.
- The systemd drop-in (`/etc/systemd/system/waydroid-container.service.d/
  delegate.conf`, `Delegate=yes`) is **not** package-owned either (manual
  addition under `.d/`) — survived the whole removal/reinstall cycle
  untouched, same as `/opt/waydroid-work`.

## 11. Resolution bugs on a HiDPI screen (2026-09-22)

This panel is HiDPI: `DSI-1`, physical mode 1920x1200, Wayland output
`scale: 2` → logical 960x600 (matches `admin/desktop-fix.sh`'s own
`[output:DSI-1] scale = 2` in `/etc/phosh/phoc.ini`). Two separate bugs
followed from that, in opposite directions:

**Nested `cage` → blurry.** Booted fine (no Scudo crash) but the whole UI
was badly blurred — `cage`'s nested Wayland backend surface didn't account
for the output's scale=2, so Android's frame was rendered small and
stretched back up by the compositor. (Also had to override
`WLR_BACKENDS=wayland` for `cage` specifically — the session's global
`WLR_BACKENDS=drm,libinput`, set for `phoc`, leaked in and made `cage`
fight for the DRM seat instead of nesting as a client.)

**Fix for the blur: drop `cage` entirely.** Since `phoc` is already running
old Mesa live (§9), Waydroid doesn't need a second compositor — run
`waydroid session start` + `waydroid show-full-ui` natively
(`Wayland display: wayland-0`, not a nested one). Screenshot-confirmed
crisp, full-resolution.

**Native → only 1/4 of the screen visible.** Same HiDPI root cause,
opposite direction: Android was rendering its buffer at the *physical*
resolution (`persist.waydroid.width/height=1920x1200`, matching the panel),
but Waydroid's Wayland client never declares `buffer_scale=2` to `phoc`.
An unscaled buffer's pixels get placed 1:1 into logical space, so a
1920x1200 buffer landed in a 960x600-logical output — 4x oversized, only
the top-left logical 960x600 (physical-pixel) corner ever visible.

**Fix for the 1/4 clipping**: set `persist.waydroid.width=960` /
`persist.waydroid.height=600` (the *logical*, not physical, size) via
`waydroid prop set` — note this needs the session already running first
(`prop get`/`set` fail with "session is stopped" otherwise) — then a full
`session stop` + `session start` for SurfaceFlinger to pick it up fresh.
Confirmed: fits correctly. Trade-off: lower absolute resolution than the
panel's native 1920x1200 (same softness as the `cage` blur, different
cause) — no known way yet to get Waydroid's Wayland client to declare
`buffer_scale=2` and use the full native resolution without this
workaround.

## 12. App-drawer visibility (2026-09-22)

Two separate problems, both now fixed:

- Installed Android apps' `.desktop` launchers
  (`~/.local/share/applications/waydroid.*.desktop`) are auto-generated by
  Waydroid itself, but it bakes `NoDisplay=true` into every one
  (single-window default) — files exist, but never show in the app grid.
  **Automated fix**: [`../waydroid/waydroid-fix-desktop-entries`](../waydroid/waydroid-fix-desktop-entries)
  (flips `NoDisplay`, refreshes the desktop-entry cache, idempotent),
  triggered by a systemd user path unit
  ([`../waydroid/systemd/`](../waydroid/systemd/), inotify-watches
  `~/.local/share/applications/`, no polling) — survives future Waydroid
  resyncs (new app installs, session restarts) automatically.
- Two things legitimately named "Waydroid" show in the app grid — the
  package's own generic launcher (`/usr/share/applications/Waydroid.desktop`,
  system-wide, always visible) and a custom
  `~/.local/share/applications/waydroid-oldmesa.desktop` launcher for the
  now-abandoned `cage` approach (§11) — that second one is dead weight,
  safe to remove.
- Separately, userspace-`apt`-installed GUI packages had the same
  *symptom* (`.desktop` file present, not visible) for an unrelated reason —
  fixed generically in the `sudo-less` toolkit itself, not here: see
  `working-packages.md`'s `update-desktop-database` entry and
  `config/apt.conf.d/01update-desktop-database.in`.

## 13. Where the large binaries actually live

Deliberately **not** in this repo (`sudo-less` is meant to stay small —
scripts and patches, see the top-level README's "Why it's cheap"), but
documented here so nothing is orphaned:

- `/opt/waydroid-work/old-mesa/` (168MB, extracted Mesa 25.0.7) and
  `/opt/waydroid-work/debs/` (35MB, the `.deb`s it came from) — root-owned,
  world-readable, reproducible from
  [`../waydroid/fetch-old-mesa.sh`](../waydroid/fetch-old-mesa.sh). Backup
  copy (in case `/opt/waydroid-work` ever actually gets removed, unlike
  this time — see §10): `~master/waydroid-work-backup/`.
- `/var/lib/waydroid/images/{system,vendor}.img` (2.3GB, the Android OS
  images) — root-owned, world-readable. Backup copy:
  `~master/waydroid-images/`.
- `/usr/bin/phoc` (the live old-Mesa wrapper) and `/usr/bin/phoc.real`
  (pristine original) — backed up to `~master/phoc-backup/` and also to
  `~mobian/phoc-backup/`, given this exact file's history of causing a
  stuck-DRM-master crash loop requiring a reboot (§6 above). Not currently
  planned to be touched.
