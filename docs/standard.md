# The sudo-less standard (tier spec v1)

This is the contract that package **recipes** conform to. Its point is to make
fixes comparable and *proven*, not anecdotal: a recipe declares the **minimum
tier** a package needs and the mechanism that gets it there, and
`scripts/catalog/recipes.sh` verifies the claim. See [`paths.md`](paths.md) for why the
tiers exist.

## Design principle: triage, not universal support

sudo-less does not "handle the userspace." It **classifies** it and handles
the selected slices at the least tier each needs. The unit of work is never
"make everything work" — it's: *decide which problem this package is, then
either solve it at the cheapest tier that works, or declare it `never` with
a reason.* That's triage, and the recipe database **is** the triage table:

1. `check-package.sh` → does it install without root? (`ok` / `risky` /
   `unlikely`)
2. `check-package.sh --runtime` → does it read baked-in paths, or does an
   interpreter's own search path miss the prefix?
3. Assign the **minimum tier**: `direct` | `env` | `overlay` | `rootfs` |
   `gui` | `never`.
4. Solvable → a `recipes/<pkg>.recipe`, `verify` passes.
5. Not solvable → a `tier never` recipe with the reason (root-only postinst,
   32-bit-only, self-updating, service, …) — see `recipes/screen.recipe`,
   `recipes/javascript-common.recipe`.

This is legitimate, not lazy, because it's **data-driven**: `check-package.sh`
classifies, the recipe declares the tier, `verify` proves it — the same
input always gets the same verdict, and a `never` verdict records *why* a
package is excluded rather than leaving a silent gap. A collector lists
solutions ("use Homebrew for this, Flatpak for that"); a standard routes
problems. Universal `.deb` coverage is explicitly not the goal — prefer a
`never` verdict over a fragile hack, and answer every new package request
with classification + a recipe, not by widening a mechanism "just in case."

## Tiers (normative)

Each tier states what it **requires**, what it **guarantees**, and what it
**excludes**. A recipe names the *lowest* tier that works. The **status** column
is the promise: only the floor (`direct`/`env`) is supported today, reached via
the default route ([`release.md`](release.md)); the rest are experimental.
One tier is supported at a time, deliberately — with one maintainer, only one
tier can be vouched for. A tier graduates to supported only when verified and
stable.

| tier | status | requires | guarantees | excludes |
|---|---|---|---|---|
| `direct` | **supported** | nothing | relocatable binaries run with `PATH` (+ `LD_LIBRARY_PATH`) | anything reading paths not on `PATH` |
| `env` | **supported** | nothing (no root, no namespaces, no new deps) | lookups the program exposes an env knob for (`PYTHONPATH`, `PERL5LIB`, `GEM_PATH`, `CLASSPATH`, `XDG_*`, …) | absolute paths baked into binaries; root-only postinst |
| `overlay` | experimental | `bwrap` + unprivileged userns + overlayfs ≥ 5.11 | hardcoded `/etc`, `/usr/share`, `/usr/lib` resolve to the prefix, stacked over the system tree | root-only postinst; session integration |
| `rootfs` | experimental | a complete rootfs + `bwrap`/`proot`/`chroot` | a real `/`: paths *and* root-only postinst (dpkg runs as root inside) | host services, kernel/initramfs, host integration |
| `gui` | experimental | an `overlay`/`rootfs` runner **plus** a desktop session | display, GPU and audio passed through | — |
| `never` | out of scope | — | nothing: documented as out of scope | 32-bit-only, self-updating/proprietary, container-in-container, services, PAM/setuid |

`never` is a valid, useful verdict: it records *why* a package is out of scope
so the boundary reads as a decision, not a gap.

## Recipe format

One file per package, `recipes/<package>.recipe`. Plain text, one `key value`
per line, `#` comments, blank lines ignored — no parser, no dependencies.

| key | required | meaning |
|---|---|---|
| `package` | yes | package name (must match the filename) |
| `install` | yes | raw `check-package.sh` verdict: `ok` \| `risky` \| `unlikely` |
| `tier` | yes | minimum tier (see above) |
| `env` | no | `NAME=value`, repeatable; `$PREFIX` is substituted |
| `shim` | no | a shim that must exist in `$PREFIX/bin`, repeatable |
| `verify` | no | one shell command that proves the package works |
| `note` | no | free text, repeatable (required rationale for `tier never`) |

Rules:

- `install` is the **raw** verdict, *before* the recipe's `shim`/`env` are
  applied — so `ranger` is `install risky` (its postinst calls `py3compile`
  against an absolute path) fixed to `tier direct` by a `shim`. That
  difference is the fix.
- A `tier never` recipe carries a `note` explaining the exclusion and no
  `verify`.

## Verification

```sh
scripts/catalog/recipes.sh list              # package, raw verdict, tier
scripts/catalog/recipes.sh show ranger       # the recipe
scripts/catalog/recipes.sh verify [PKG...]   # default: every recipe
```

`verify` checks the tier's prerequisites are present, that each declared `shim`
exists in `$PREFIX/bin`, then runs `verify` with `env` applied. It prints
`PASS` / `FAIL` / `SKIP` and exits non-zero on any failure. **A recipe is a
claim until `verify` passes on a real host.**

## Worked examples

`recipes/jq.recipe` — relocatable, needs nothing:

```
package  jq
install  ok
tier     direct
verify   jq --version
```

`recipes/ranger.recipe` — pure Python; the postinst byte-compiles into the
absolute `/usr/lib/python3/dist-packages` (so the raw verdict is `risky`). A
shim fixes the install; `sys.path` is handled globally by
`install-config.sh`'s `.pth` in the system python3's user site (#5), so no
recipe-level `env` is needed and the tier is `direct`:

```
package  ranger
install  risky
tier     direct
shim     py3compile
verify   ranger --version
```

`recipes/pmarkdown.recipe` — pure Perl; `check-package.sh` calls it `OK` (no
absolute path baked into its own script), but host perl's default `@INC`
never includes `$PREFIX`, so `use Markdown::Perl;` fails without an explicit
`env`:

```
package  pmarkdown
install  ok
tier     env
env      PERL5LIB=$PREFIX/usr/share/perl5:$PREFIX/usr/lib/x86_64-linux-gnu/perl5/5.42
verify   pmarkdown --version
```

## Language and dependencies

The whole project stays **bash + plain text**. This is a hard rule, not a
preference:

- scripts are bash (`#!/usr/bin/env bash`); **no interpreter beyond bash**.
- recipes are **data** — plain-text `key value`, parsed with `sed`, not
  TOML/YAML/JSON (that is why the format is line-based).
- `verify` and `env` values are shell.
- no compiled helper, no third-party runtime, no `jq`/Python/parser.

The higher tiers call standard Debian tools (`bwrap`, `proot`, `mmdebstrap`) as
*programs*, not language runtimes; the `direct` and `env` tiers need none of
them.

## Versioning

Spec **v1**. Adding a tier or a key is a spec change; adding recipes is not.
