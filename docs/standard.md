# The sudo-less standard (spec v2)

What sudo-less supports, and how a claim about a package is written down and
proved. The design behind it is [`design.md`](design.md); the numbers are
[`survey-2026-09.md`](survey-2026-09.md).

## Triage, not universal support

sudo-less does not promise every `.deb`. It **classifies** each package,
handles the ones in scope with the cheapest mechanism that works, and says
plainly why the others are not. A `never` or "the admin's" verdict is a
decision with a reason, not a gap. Universal coverage is explicitly not the
goal: prefer a clear verdict over a fragile hack.

Two questions, asked of every package:

1. **Scope:** is it the user's, the admin's, or out of reach? The user sees
   this.
2. **Mechanism:** what does it need to run from the prefix? Only sudo-less
   sees this; it applies the mechanism itself
   ([`mechanisms.md`](mechanisms.md)).

## Scope

| scope | meaning | the user sees |
|---|---|---|
| `user` | installs and runs from `~/.local` | `apt-get install PKG`, then `PKG` |
| `admin` | belongs to the system: needs root to install or to work | a refusal naming what the admin must do |
| `never` | no way fits the rules (32-bit only, self-updating, needs root at run time) | a refusal with the reason |

### By Debian section

A package's scope starts from its Debian `Section`. The split, with the
survey's evidence per section in [`survey-2026-09.md`](survey-2026-09.md#per-section):

| scope | sections |
|---|---|
| `user` | libraries and development: `libs`, `libdevel`, `devel`, `debug`, `introspection`, `vcs`; languages: `python`, `perl`, `ruby`, `rust`, `golang`, `haskell`, `javascript`, `java`, `php`, `ocaml`, `lisp`, `gnu-r`, `interpreters` ([`ecosystems/`](../ecosystems/)); tools and content: `utils`, `text`, `editors`, `shells`, `doc`, `fonts`, `localization`, `tex`; applications: `science`, `math`, `graphics`, `sound`, `video`, `games`, `electronics`, `hamradio`, `education`, `embedded`; desktop: `x11`, `gnome`, `kde`, `xfce`; mixed client/server: `web`, `comm` |
| `admin` | `admin`, `kernel`, `net`, `mail`, `database`, `httpd`, `tasks`, `metapackages`, and the `required` / `important` / `standard` packages of a base install |
| undecided | `cli-mono`, `gnustep`, `misc`, `news`, `oldlibs`, `otherosfs`, `zope` |

### Signals override the section

Whatever its section, a package is the **admin's** if it:

- depends on `adduser` or creates a system user;
- ships a system service (depends on `init-system-helpers`, installs units
  or init scripts);
- needs a setuid or setgid file, or a file capability, to work.

A client in an admin section (`curl`, `mtr` in `net`) can be brought into
scope by a recipe.

### Version skew is the admin's too

On a rolling host, a newer package can need a newer system library than the
host has (24 % of the survey's sample on sid). sudo-less never upgrades
system packages, so this is reported as "needs the admin to upgrade X", not
as apt's "held broken packages". On Debian stable it hardly happens.

## Mechanism

One of `none`, `env`, `overlay` ([`mechanisms.md`](mechanisms.md)), plus a
`gui` attribute for apps that need a desktop session.
`scripts/catalog/check-package.sh --runtime` predicts it; its `direct`
means `none`.

## Recipes: the exceptions

A package needs no recipe when the classifier gets it right. A recipe exists
to **override** the classifier and to **prove** the result.

One file per package, `recipes/<package>.recipe`: plain text, one `key
value` per line, `#` comments, blank lines ignored.

| key | required | meaning |
|---|---|---|
| `package` | yes | the package name (matches the file name) |
| `install` | yes | the raw `check-package.sh` verdict: `ok`, `risky` or `unlikely` |
| `scope` | no | `user` (default), `admin` or `never` |
| `mechanism` | for scope `user` | `none`, `env` or `overlay` |
| `gui` | no | `yes` for an app that needs a desktop session |
| `env` | no | `NAME=value`, repeatable; `$PREFIX` is substituted |
| `shim` | no | a shim that must exist in `$PREFIX/bin`, repeatable |
| `verify` | no | one shell command that proves the package works |
| `note` | no | free text, repeatable; required for scope `admin` or `never` |

Rules:

- `install` is the raw verdict *before* any shim or env applies: `ranger` is
  `install risky` (its postinst calls `py3compile`) with `mechanism none`,
  fixed by a shim. That difference is the fix.
- A recipe with scope `admin` or `never` has a `note` and no `verify`.
- `env` in a recipe is a stopgap: a language's search path belongs in its
  ecosystem hook, set once for every package.

## Verification

```sh
scripts/catalog/recipes.sh list              # package, raw verdict, scope, mechanism
scripts/catalog/recipes.sh show ranger       # the recipe
scripts/catalog/recipes.sh verify [PKG...]   # default: every recipe
```

`verify` checks the mechanism's prerequisites (and a session for `gui`),
that each declared shim exists, then runs `verify` with `env` applied. It
prints `PASS`, `FAIL`, `SKIP` (prerequisites missing) or `OUT` (scope
`admin` or `never`), and exits non-zero on any failure. For `mechanism
none` it also checks that the command resolves under `$PREFIX`, so a system
copy on `PATH` cannot pass for the prefix's. **A recipe is a claim until
`verify` passes on a real host.**

## Worked examples

`recipes/ranger.recipe`: pure Python; a shim fixes the install, the Python
ecosystem hook puts the prefix on `sys.path`, so nothing else is needed:

```
package    ranger
install    risky
mechanism  none
shim       py3compile
verify     ranger --version
```

`recipes/nodejs.recipe`: `node` loads `/usr/share/nodejs/...` by absolute
path, which no variable reaches:

```
package    nodejs
install    risky
mechanism  overlay
verify     tools/prefix-run.sh node -e process.version
```

`recipes/screen.recipe`: its postinst creates `/run/screen` and calls
`update-rc.d`:

```
package    screen
install    unlikely
scope      never
note       root-only postinst (creates /run/screen, /lib/systemd/system, calls update-rc.d)
```

## Language and dependencies

The whole project stays **bash and plain text**. This is a rule, not a
preference:

- scripts are bash (`#!/usr/bin/env bash`); no interpreter beyond bash;
- recipes are data, plain `key value` lines parsed with `sed`;
- `verify` and `env` values are shell;
- no compiled helper, no third-party runtime, no `jq`, Python or parser.

The overlay calls standard tools (`bwrap`, `unshare`) as programs, not as
runtimes.

## Versioning

**Spec v2** (2026-09). Changes from v1: the tier ladder (`direct`, `env`,
`overlay`, `rootfs`, `gui`, `never`) is replaced by two questions, scope
and mechanism; `gui` is an attribute; `rootfs` is gone; scope follows the
Debian section; recipes are exceptions to the classifier, with the keys
`scope`, `mechanism` and `gui` instead of `tier`.

Adding a scope, mechanism or key is a spec change; adding recipes is not.
