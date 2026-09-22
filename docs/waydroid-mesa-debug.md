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
but Waydroid's Wayland client never declared `buffer_scale=2` to `phoc`
while those props were set. An unscaled buffer's pixels get placed 1:1
into logical space, so a 1920x1200 buffer landed in a 960x600-logical
output — 4x oversized, only the top-left logical 960x600 (physical-pixel)
corner ever visible.

**First (wrong) fix tried**: set `persist.waydroid.width=960` /
`persist.waydroid.height=600` (the logical size). This did fit the screen,
but at a real cost: lower absolute resolution than the panel's native
1920x1200 — same softness as the `cage` blur, just a different cause.
Superseded by the real fix below; recorded here so nobody re-tries it.

**Actual fix, found by reading Waydroid's own hwcomposer source**
(`waydroid/android_hardware_waydroid`, `hwcomposer/wayland-hwc.cpp`):
Waydroid has real, working HiDPI auto-calibration built in — it listens
for the compositor's `wl_output.scale` event, computes
`ro.sf.lcd_density = default_density(180) × scale`, and properly declares
`wl_surface_set_buffer_scale()` (or uses `wp_viewporter` if the compositor
offers it, which `phoc` does). **But `choose_width_height()` skips that
entire path the moment `persist.waydroid.width`/`height` are set at all**
— literally commented `// Ignore hint it requested` in the source. Those
props were sitting at `1920`/`1200` as **stale leftovers from the original
old-Mesa debugging session**, before anything was touched today — that's
what actually broke this, not a Waydroid limitation. Setting them to
960x600 "fixed" the fit by accident while keeping the real auto-calibration
disabled.

**Fix**: `waydroid prop set persist.waydroid.width ""` and same for
`height` — genuinely *clear* them, don't set them to anything — then a
full `session stop` + `session start` for calibration to run fresh (needs
the session running first to reach `prop set` at all, same chicken-and-egg
as before). Confirmed via `waydroid prop get waydroid.display_scale` →
`2.000000` (correctly auto-detected) and `ro.sf.lcd_density` → `360`
(`180×2`, matching the source's formula exactly), and
screenshot-confirmed: **crisp native resolution and correct fit,
simultaneously** — no trade-off. Also happened to still be running with
multi-window enabled (§9) at the time, which visibly worked fine too.

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

## 14. Multi-window: root cause pinned down exactly (2026-09-22, not yet fixed)

Retesting multi-window (§9, §11) surfaced a *second* symptom beyond the
known crash — booted fine, but a floating app window filled only about
half the screen vertically. Diagnosed by disabling
`persist.waydroid.multi_windows` and confirming full-screen mode fills the
display correctly top-to-bottom (screenshot-verified) — so this is
specifically a multi-window/freeform sizing bug, same buggy area as the
known upstream crash (`waydroid/waydroid#1446`), not the display-scale fix
from §11 (that one's independently confirmed correct).

**Exact bug, found by reading the real LineageOS 20 source** (this vendor
image is LineageOS 20 VANILLA) — not decompiled/guessed, the actual
upstream file:
[`LaunchParamsUtil.java`](https://github.com/LineageOS/android_frameworks_base/blob/lineage-20.0/services/core/java/com/android/server/wm/LaunchParamsUtil.java),
`services/core/java/com/android/server/wm/LaunchParamsUtil.java`,
method `getDefaultFreeformSize()`:

```java
final int portraitHeight = Math.min(stableBounds.width(), stableBounds.height());
final int otherDimension = Math.max(stableBounds.width(), stableBounds.height());
final int portraitWidth = (portraitHeight * portraitHeight) / otherDimension;  // divides by 0
```

When `stableBounds` is an empty `Rect` (0x0) at the point this runs,
`otherDimension` is `0` → `ArithmeticException`. This is exactly the
"stable bounds are 0x0 at boot" symptom from the original notes (§9) —
sometimes it crashes outright (the known upstream issue), sometimes it
apparently limps through with a bad size instead (today's half-height
symptom) — same root cause, timing-dependent outcome.

**The fix itself is trivial** — a one-line divide-by-zero guard:

```java
final int portraitWidth = (otherDimension == 0) ? portraitHeight
        : (portraitHeight * portraitHeight) / otherDimension;
```

**What deploying it actually needs** (not done — parked, revisit if
multi-window becomes worth having): this is compiled into `services.jar`'s
dex inside the running system image already, so a source-level `.java`
patch can't just be dropped in. Options: (a) a full LineageOS/AOSP
rebuild — not remotely feasible on this hardware; (b) a surgical
smali-level patch to just this one method (disassemble the class,
add the equivalent guard, reassemble, repack `services.jar`, drop into
the Waydroid overlay so the base image stays untouched). (b) is realistic
— the phone at `ssh fe2` (Termux, Tailscale) already has a working Android
build toolchain (`jadx`, `javac`, `d8`, `aapt`, `apksigner`, `zipalign`,
`keytool` — used to build an existing `~/python-apk/pyrunner.apk` project
there) but not `smali`/`baksmali` specifically; `apktool` (bundles both)
is available via `pkg install apktool` in Termux's repo but not yet
installed. **Decision: leave multi-window off
(`persist.waydroid.multi_windows=false`, already set) and treat
single-window as the stable daily state** — this is a real, understood,
fixable bug, just not worth the effort right now for a "nice to have"
(simultaneous floating app windows) when single-window already works
crisply.
