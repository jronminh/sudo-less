# Contributors

- **jronminh** — project author. Host setup and direction: the two-persona
  (`mobian`/`master`) model, polkit/udev/capability design, the no-root
  philosophy, testing on real hardware, and all decisions.
- **deepseek-v4-flash** ([opencode](https://opencode.ai)) — pairing assistant.
  Ported and retargeted Termux's apt/dpkg patches to `~/.local`, wrote the
  build/rootfs/container scripts, `check-package.sh` / `test-packages.sh`,
  the docs and README, and ran the builds and package tests.
- **Claude** (Opus 5.5 and Sonnet 5, [Claude Code](https://claude.com/claude-code),
  Anthropic) — pairing assistant, from 2026-09-22. Rebased the apt/dpkg
  fork onto apt 3.3.3 and dpkg 1.23.11; the prefix views (install, run,
  service) and `prefix-wrap`; `prefix-check`; `dev/survey.sh` and the
  survey reports; the problem map and Debian's privilege surface;
  `prefix-units` (packages' services as user units), `prefix-sandbox`
  (systemd's sandbox on a view, seccomp through `setpriv`) and
  `prefix-integrate`; the dsb development policy; CI fixes and docs.

Thanks to [Termux](https://termux.dev) and the Debian apt/dpkg maintainers,
whose patches and sources this builds on.
