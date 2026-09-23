# ecosystems: per-language support

Each language plugs into sudo-less the same way, in its own directory
([`../docs/design.md`](../docs/design.md)):

- `install.sh`: a one-time hook, run by `scripts/setup/install-config.sh`,
  that sets what the language needs for every package (a search path);
- `shims/`: replacements for root-only tools that the language's
  maintainer scripts call;
- later, parts for the pipeline's classify and integrate stages.

| language | Debian section | status | survey 2026-09: prediction (12) / installed (3) |
|---|---|---|---|
| [Python](python/) | `python` | supported: `.pth` hook and `py3compile` shim | 12 need the shim, 11 then run directly / 3 of 3 |
| [Perl](perl/) | `perl` | installs; `PERL5LIB` still pinned in recipes | 12 need `env` / 3 of 3 |
| [Java](java/) | `java` | libraries install; the JDK only through `deb2home` | 9 need `env` / 3 of 3 |
| [Ruby](ruby/) | `ruby` | installs; some gems need the overlay | 10 run directly, 2 need the overlay / 3 of 3, 1 fails to load `libruby` |
| Haskell | `haskell` | `ghc`'s postinst runs `/usr/bin/ghc`, which is in the prefix: fails | 12 run directly / 0 of 3 (the postinst) |
| Go, Rust, JavaScript, PHP, OCaml, Lisp, R | their sections | nothing language-specific needed so far (R: the sample hit version skew) | see [`../docs/survey-2026-09.md`](../docs/survey-2026-09.md#per-section) |

Numbers: [`../docs/survey-2026-09.md`](../docs/survey-2026-09.md).
