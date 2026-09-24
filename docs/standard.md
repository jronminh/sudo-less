# The sudo-less standard (spec v3)

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
2. **Mechanism:** how does each of its programs run from the prefix:
   directly, or in the run view? Only sudo-less sees this; it decides by
   itself ([`view.md`](view.md#how-programs-get-there)).

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
| `user` | libraries and development: `libs`, `libdevel`, `devel`, `debug`, `introspection`, `vcs`; languages: `python`, `perl`, `ruby`, `rust`, `golang`, `haskell`, `javascript`, `java`, `php`, `ocaml`, `lisp`, `gnu-r`, `interpreters` ([`ecosystems.md`](ecosystems.md)); tools and content: `utils`, `text`, `editors`, `shells`, `doc`, `fonts`, `localization`, `tex`; applications: `science`, `math`, `graphics`, `sound`, `video`, `games`, `electronics`, `hamradio`, `education`, `embedded`; desktop: `x11`, `gnome`, `kde`, `xfce`; mixed client/server: `web`, `comm` |
| `admin` | `admin`, `kernel`, `net`, `mail`, `database`, `httpd`, `tasks`, `metapackages`, and the `required` / `important` / `standard` packages of a base install |
| undecided | `cli-mono`, `gnustep`, `misc`, `news`, `oldlibs`, `otherosfs`, `zope` |

### Signals override the section

Whatever its section, a package is the **admin's** if it:

- depends on `adduser` or creates a system user;
- ships a system service (depends on `init-system-helpers`, installs units
  or init scripts);
- needs a setuid or setgid file, or a file capability, to work.

A client in an admin section (`curl`, `mtr` in `net`) can be brought into
scope as an exception.

### Version skew is the admin's too

On a rolling host, a newer package can need a newer system library than the
host has (24 % of the survey's sample on sid). sudo-less never upgrades
system packages, so this is reported as "needs the admin to upgrade X", not
as apt's "held broken packages". On Debian stable it hardly happens.

## Mechanism

Per program, one of `direct` (it runs from `$PREFIX/usr/bin`) or `view` (a
script in `$PREFIX/bin` runs it in the shared run view), plus a `gui`
attribute for apps that need a desktop session. `prefix-wrap` decides it
after each install, from the installed files, and `prefix-wrap --check
PROG` prints the decision ([`view.md`](view.md#how-programs-get-there)).
`scripts/catalog/check-package.sh --runtime` predicts it before install:
its `env` and `overlay` both mean `view` now.

## Exceptions

Where the classifier is wrong about a package, the case is written down in
[`ecosystems.md`](ecosystems.md), with what the package ran into and how it
was made to work, and the classifier is fixed where it can be. A claim that
a package works holds only once it has been run on a real host, from the
prefix, not through the system's copy on `PATH`.

## Language and dependencies

The whole project stays **bash and plain text**. This is a rule, not a
preference:

- scripts are bash (`#!/usr/bin/env bash`); no interpreter beyond bash;
- no compiled helper, no third-party runtime, no `jq`, Python or parser.

The overlay calls standard tools (`bwrap`, `unshare`) as programs, not as
runtimes.

## Versioning

**Spec v3** (2026-09). Changes from v2: recipes (`recipes/*.recipe` and
`scripts/catalog/recipes.sh`) are gone; exceptions are documented in
[`ecosystems.md`](ecosystems.md). Changes from v1 to v2: the tier ladder (`direct`, `env`,
`overlay`, `rootfs`, `gui`, `never`) is replaced by two questions, scope
and mechanism; `gui` is an attribute; `rootfs` is gone; scope follows the
Debian section; recipes are exceptions to the classifier, with the keys
`scope`, `mechanism` and `gui` instead of `tier`.

Adding a scope or mechanism is a spec change.
