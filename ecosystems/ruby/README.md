# Ruby

**Debian section:** `ruby`. **Status:** installs; most packages run
directly, some need the overlay.

Ruby's `$LOAD_PATH` does not include `$PREFIX`. Gems whose executables load
their libraries by absolute path run through `tools/prefix-run.sh`, which
overlays the prefix onto `/usr`.

Example: `recipes/yard.recipe`. History: issue #7.

**To do:** try `RUBYLIB` / `GEM_PATH` (mechanism `env`) before the overlay.
