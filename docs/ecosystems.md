# Ecosystems: what each language made hard

Before the prefix view ([`view.md`](view.md)), dpkg installed a package with
its files moved under `$PREFIX`, while the package still expected them at
`/usr`, `/etc` and so on. Each language ran into that in its own way: an
interpreter that searches only compiled-in paths, a maintainer-script helper
that works on the absolute path, a shebang naming an interpreter that exists
only in the prefix. This page records what each one ran into, what fixed it
then, and what the view changes. It replaces the old `ecosystems/`
directory (per-language hooks and shims) and `recipes/` (per-package
exceptions).

The survey numbers are from [`survey-2026-09.md`](survey-2026-09.md): the
prediction for 12 packages of the section, then how many of 3 sampled
packages installed.

## Summary

| language | Debian section | the difficulty | survey: prediction (12) / installed (3) |
|---|---|---|---|
| Python | `python` | postinst `py3compile` worked on `/usr`; `sys.path` left out the prefix | 12 needed a shim, 11 of them then ran directly / 3 of 3 |
| Perl | `perl` | `@INC` left out the prefix | 12 needed `env` / 3 of 3 |
| Java | `java` | JRE/JDK postinst creates `/etc/.java` | 9 needed `env` / 3 of 3 |
| Ruby | `ruby` | `$LOAD_PATH` and `#!/usr/bin/ruby` shebangs | 10 ran directly, 2 needed the overlay / 3 of 3, 1 failed to load `libruby` |
| Haskell | `haskell` | `ghc`'s postinst runs `/usr/bin/ghc`, which is only in the prefix | 12 ran directly / 0 of 3 (the postinst) |
| Go, Rust, JavaScript, PHP, OCaml, Lisp, R | their sections | nothing specific to the language (R: the sample hit version skew) | [per section](survey-2026-09.md#per-section) |

## Python

Two things broke a Python package installed into the prefix (issue #5):

- **Installing.** The postinst from `dh_python3` runs `py3compile -p PKG`,
  which byte-compiles the package's files at their absolute paths
  (`/usr/lib/python3/dist-packages/...`). They were under `$PREFIX`, so
  `dpkg --configure` failed. The fix was a `py3compile` shim on `PATH`, in
  front of the real one. It took the `.py` files from `dpkg -L` and compiled
  them under `$PREFIX`.
- **Running.** The system `python3` does not look in
  `$PREFIX/usr/lib/python3/dist-packages`. The fix was a `.pth` file in the
  user site (`python3 -m site --user-site`), written by a hook that
  `install-config.sh` ran, which adds that directory to `sys.path`.

**In the view:** the real `py3compile` works, because `/usr/lib/python3` is
the prefix's tree there. Verified 2026-09-24 by reinstalling `ranger` with
no shim on `PATH`: all 81 `.pyc` files were built. A program run in the view
finds its modules without the `.pth`. A program run outside the view still
needs the `.pth` or `PYTHONPATH`, until installed programs run in the view
too.

For a pure-Python tool that does not depend on Debian, `pipx install TOOL`
needs neither fix.

## Perl

Perl's compiled-in `@INC` (`/usr/share/perl5`,
`/usr/lib/<triplet>/perl5/<version>`) never includes `$PREFIX`, so
`use Module;` failed (issue #7). The classifier missed it: it scans a
package's files for absolute paths, not the interpreter's search path.
The fix was `PERL5LIB`:

```sh
PERL5LIB=$PREFIX/usr/share/perl5:$PREFIX/usr/lib/x86_64-linux-gnu/perl5/5.42
```

The second part holds the architecture triplet and the Perl version
(`perl -MConfig -e 'print "$Config{archname}/perl5/$Config{version}"'`), so
it is specific to the host. It was pinned per package (`pmarkdown`), and was
meant to become a hook that sets it once with the host's values.

**In the view:** `@INC`'s paths are the prefix's trees, so no variable
should be needed; not tested yet.

## Java

`java-common` and every `openjdk-*-jre-headless` postinst run
`mkdir -m 755 /etc/.java`, which is not guarded, so `dpkg --configure` fails
without root (issue #7). There was no safe shim: the failing call is a plain
`mkdir` on `/etc`, and a `mkdir` shim would catch every other script too.
The workaround skipped the maintainer scripts:

```sh
tools/deb2home.sh openjdk-25-jre-headless
JAVA_HOME=$PREFIX/opt/openjdk-25-jre-headless/usr/lib/jvm/java-25-openjdk-amd64
```

The JVM creates its preferences directory when it first needs it, so
`/etc/.java` is not needed at run time. The JDK version and `JAVA_HOME` were
pinned and had to follow Debian's default JDK. A library jar is found only
on the classpath (`CLASSPATH`, or the application's own launcher).

**In the view:** `/etc/.java` is created in the prefix's `/etc`.
`apt-get install openjdk-21-jre-headless` installed and `java` ran in the
view (2026-09-24), with the `cacerts` file and the alternatives in place.

## Ruby

Ruby's `$LOAD_PATH` does not include `$PREFIX`. When the interpreter itself
comes from the prefix (`yard` pulled in `ruby3.3`, which the host did not
have), `/usr/bin/yard` starts with `#!/usr/bin/ruby` and fails with "bad
interpreter". The classifier missed this too: it did not check shebangs.
The fix was to run it through the overlay (`tools/prefix-run.sh yard`),
where `/usr/bin/ruby` and Ruby's `vendor_ruby` path resolve to the prefix.
`RUBYLIB` / `GEM_PATH` were never tried.

**In the view:** it should behave as in the overlay, for install and run;
not tested yet.

## Haskell

`ghc`'s postinst runs `/usr/bin/ghc` to register the package database. That
binary was only in the prefix, so the postinst failed. **In the view:**
`/usr/bin/ghc` is there; not tested yet.

## Single packages

What individual packages showed, each a case the classifier got wrong:

| package | what happened | how it ran | in the view |
|---|---|---|---|
| `ranger` | the Python case above | shim + `.pth` | installs, runs |
| `pmarkdown` | the Perl case above | `PERL5LIB` | not tested |
| `yard` | the Ruby case above | overlay | not tested |
| `openjdk-25-jre-headless` | the Java case above | `deb2home` + `JAVA_HOME` | installs (tested with 21) |
| `jq` | seeded on most desktops, so its check passed through the system `jq`. In a clean container the prefix's `jq` failed: `libjq.so.1` is found through the default linker path, not an RPATH | `LD_LIBRARY_PATH=$PREFIX/usr/lib/<triplet>` | should work, as in the overlay; not tested |
| `nodejs` | needs `LD_LIBRARY_PATH` for `libnode.so`, then loads `/usr/share/nodejs/undici/...` by a path compiled into the binary, which no variable reaches | overlay | should work, as in the overlay; not tested |
| `golang-go` | expected to need `GOROOT`; it does not: `go` finds its toolchain from its own path, like `java` | directly | — |
| `prismlauncher` | in `contrib`, not `main`; needed a newer Qt6 than the host's (a one-time `lock-seeded.sh unlock`) and a desktop session. Verified up to a modded Minecraft world loading | overlay, `--gui` | not tested |
| `screen` | postinst creates `/run/screen` with group `utmp`, writes `/etc/tmpfiles.d` and `/lib/systemd/system`, runs `update-rc.d` | out of reach | `/run` and group `utmp` still need root |
| `javascript-common` | postinst runs `mkdir -p /etc/lighttpd/conf-enabled`, not guarded; pulled in by `libjs-jquery` | out of reach | the `mkdir` lands in the prefix; not tested |

## What the classifier learned

- The absolute-path scan checks file contents under `/usr/share`,
  `/usr/lib`, `/usr/libexec` and `/etc`. It misses interpreter search paths
  (Perl, Python, Ruby), shebangs under `/usr/bin`, and libraries found
  through the default linker path.
- A check must not pass through the system's copy of a program: `jq` looked
  fine only because the host had its own.
- A postinst step that writes to `/etc` or runs a program from `/usr` was a
  hard failure before the view. In the view it lands in the prefix. What
  still fails is a step that needs real root: a system user or group,
  `/run`, services, `ldconfig` on the host.
