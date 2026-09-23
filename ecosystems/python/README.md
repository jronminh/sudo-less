# Python

**Debian section:** `python`. **Status:** supported; mechanism `none` once set up.

Two things break a Python package installed into the prefix, and both are
handled here:

| problem | fix | file |
|---|---|---|
| postinst runs `py3compile -p PKG`, which byte-compiles the absolute `/usr/lib/python3/dist-packages` and fails | a shim on `PATH` ahead of the real one compiles the files where they are, under `$PREFIX` | `shims/py3compile` |
| the system `python3` does not look in `$PREFIX/usr/lib/python3/dist-packages` | a `.pth` file in the user site adds it to `sys.path` | `install.sh` (run by `scripts/setup/install-config.sh`) |

For a pure-Python tool not tied to Debian, `pipx install TOOL` is simpler
still: it needs neither fix. See `docs/working-packages.md`.

Example: `recipes/ranger.recipe`. History: issue #5.
