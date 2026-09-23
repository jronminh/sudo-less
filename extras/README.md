# extras

Device-specific scripts for the maintainer's own machine (a Mobian x86_64
tablet with a JMS583 USB-NVMe bridge and Waydroid). They are **not** part of
the supported core of this repo: nothing in `bootstrap.sh`, `tools/`,
`scripts/` or `admin/` depends on them, and they get no support or testing
beyond that one device. Read them as worked examples.

- `device/` — root-side setup, run once as the admin account:
  `smart-install.sh`, `desktop-fix.sh`, `waydroid-install.sh`,
  `waydroid-install-framework-overlay.sh`.
- `waydroid/` — unprivileged Waydroid fixes (desktop entries, old Mesa,
  `services.jar` freeform patch). See `../docs/waydroid.md` and
  `../docs/waydroid-mesa-debug.md`.
