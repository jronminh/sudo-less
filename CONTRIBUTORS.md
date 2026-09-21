# Contributors

- **jronminh** — project author. Host setup and direction: the two-persona
  (`mobian`/`master`) model, polkit/udev/capability design, the no-root
  philosophy, testing on real hardware, and all decisions.
- **deepseek-v4-flash** ([opencode](https://opencode.ai)) — pairing assistant.
  Ported and retargeted Termux's apt/dpkg patches to `~/.local`, wrote the
  build/rootfs/container scripts, `check-package.sh` / `test-packages.sh`,
  the docs and README, and ran the builds and package tests.

Thanks to [Termux](https://termux.dev) and the Debian apt/dpkg maintainers,
whose patches and sources this builds on.
