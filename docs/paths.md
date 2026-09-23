# Prefixes and hardcoded paths

Why installing a Debian `.deb` into `~/.local` is not just "move the files" —
and how `tools/prefix-run.sh` closes the gap at runtime.

## The problem

A program does not find its config and data relative to where its `.deb` was
unpacked. Debian builds binaries for the root prefix `/`, so a compiled-in path
such as `/etc/foo/foo.conf` or `/usr/share/foo/templates` is a **constant string
in the binary**. Unpacking that package with `--instdir=$PREFIX` puts the files
at `~/.local/etc/...` and `~/.local/usr/share/...`, but the binary still opens
`/etc/...` and `/usr/share/...` — the relocated copies are ignored, and it may
even read the *host's* system files instead.

Only a **relocatable** package — one that computes its paths from `argv[0]`,
from an environment variable, or from a build prefix that happens to match —
behaves correctly under relocation. Everything else needs one of the fixes
below.

## How environments solve it

| environment | model | what makes the paths right |
|---|---|---|
| normal distro | install at `/` | the build prefix *is* the runtime prefix |
| Termux | rebuild with `@TERMUX_PREFIX@` = `/data/data/com.termux/files/usr` | paths are compiled in correctly; packages are patched |
| NixOS | one `/nix/store` for system and user | store paths are compiled in; nothing is relocated |
| Flatpak | `bwrap` assembles an ephemeral rootfs | the prefix is *mounted where the binary expects it* |
| AppImage | a SquashFS image mounted as a rootfs | same idea: the tree appears at its real location |

That is really two families: **(a) rebuild with the target prefix** (Termux,
NixOS), and **(b) make the target prefix look like `/` at runtime** (Flatpak,
AppImage, `chroot`/`proot`). A third, weaker option — **relocate only
relocatable packages** (Homebrew, conda, `tools/deb2home.sh`) — is what you get
when you do neither.

## Where sudo-less sits

- **Packages it installs** are in the weakest family: relocated, not rebuilt.
  On their own they work only if relocatable. `--instdir=$PREFIX` gives a real
  rootfs layout, the seeded dpkg db stops apt from duplicating system libraries,
  and env vars bridge some gaps (`PATH`, `XDG_DATA_DIRS`, `PKG_CONFIG_PATH`,
  `CMAKE_PREFIX_PATH`, `LD_LIBRARY_PATH`).
- **apt and dpkg themselves** are family (a): rebuilt from upstream + Termux's
  patches with the prefix retargeted to `~/.local` — see
  [`apt-dpkg-port.md`](apt-dpkg-port.md).
- The **build rootfs** (`mmdebstrap` + `bwrap`) is family (b): a real Debian
  where `/` is `/`, thrown away when the build finishes.

## Closing the gap: `tools/prefix-run.sh`

The same three privilege tiers the build scripts already use apply at *runtime*.
`prefix-run.sh` picks the strongest available and runs your command through it:

| tier | mode | mechanism | extra deps | kernel |
|---|---|---|---|---|
| root | `rootfs` | `chroot` a complete rootfs | none | none |
| no root, userns | `overlay` | `bwrap` overlays `$PREFIX/{usr,etc}` on `/usr`,`/etc` | `bubblewrap` | userns + overlayfs ≥ 5.11 |
| no root, userns | `overlay-native` | the same overlay via `unshare -Urm` + `mount -t overlay` | none (util-linux ≥ 2.38) | userns + overlayfs ≥ 5.11 |
| no root, no userns | `rootfs` | `proot -R` a complete rootfs | `proot` (1 static bin) | **none** |
| nothing available | `env` | export `LD_LIBRARY_PATH`/`XDG_DATA_DIRS`/`PATH` | none | none |

```sh
tools/prefix-run.sh jq . file.json     # auto-picks a mode
tools/prefix-run.sh --explain --print tree /some/dir   # show what it would run
tools/prefix-run.sh --mode rootfs nginx -v             # force a complete rootfs
```

The `overlay` mode is the Flatpak/AppImage model: it **stacks** `$PREFIX/usr`
over the host's `/usr` rather than replacing it, which matters because the
seeded dpkg db means the prefix holds only leaf packages while the base
libraries still come from the system. The equivalent hand-rolled `bwrap` call:

```sh
bwrap --ro-bind / / \
  --overlay-src /usr --overlay-src "$PREFIX/usr" --tmp-overlay /usr \
  --overlay-src /etc --overlay-src "$PREFIX/etc" --tmp-overlay /etc \
  --dev-bind /dev /dev --proc /proc -- "$@"
```

`--tmp-overlay` (bubblewrap ≥ 0.9.0) gives an ephemeral writable upper layer, so
writes to `/etc` don't touch the host. Overlaying is required rather than
`--bind "$PREFIX/usr" /usr`: a bind would *hide* the system libraries.

### Native overlay: no third-party tools

bwrap is a convenience, not a requirement: `unshare` and `mount` are util-linux
(base system) and overlayfs is the kernel. `--mode overlay-native` builds the
same stack with nothing else. In `auto` mode it is picked when bwrap is missing
or its probe fails:

```sh
U=$(id -u) G=$(id -g) unshare -Urm --propagation private bash -c '
  ovl=$(mktemp -d); mount -t tmpfs -o mode=0700 tmpfs "$ovl"
  mkdir "$ovl/up" "$ovl/wk"
  mount -t overlay overlay \
    -o "lowerdir=$PREFIX/usr:/usr,upperdir=$ovl/up,workdir=$ovl/wk" /usr
  exec unshare -U --map-user="$U" --map-group="$G" -- "$@"' _ CMD
```

- **`lowerdir` is leftmost-wins**, the reverse of bwrap's `--overlay-src` order:
  `$PREFIX/usr:/usr`, not `/usr:$PREFIX/usr`.
- `unshare -Ur` makes you uid 0 inside the namespace, which some programs
  refuse (userspace apt does). After mounting, a nested user namespace
  (`--map-user`, util-linux ≥ 2.38) maps the command back to your own uid.
- `$PREFIX` must not contain `:` or `,` (overlayfs option syntax) and must not
  live under `/usr` or `/etc` (a layer can't be an ancestor of the mount point).

There is deliberately **no root variant**. The admin's job is to *enable*
userspace once (`admin/native/enable-userspace.sh` turns on unprivileged user
namespaces with base tools only), not to run the user's software as root. A
per-run `sudo` runner would defeat the point, and it is also a privilege
escalation: once `/usr` is overlaid with a user-owned tree, anything root
execs in that namespace (mount helpers, `ld.so`, libc) may be the user's file.

## GUI/session passthrough: `--gui`

A GUI app needs more than paths — a display, a GPU and an audio socket. Add
`--gui`:

```sh
tools/prefix-run.sh --gui prismlauncher
```

**Overlay mode already sees the session by accident**: its base bind is the
*entire* host `/` (`--ro-bind / /`) before overlaying `$PREFIX/usr`,`etc` on
top, so `/tmp/.X11-unix` (X11), `$XDG_RUNTIME_DIR` (Wayland +
PipeWire/Pulse), and `/dev/dri` (GPU, via the existing `--dev-bind /dev
/dev`) are all already visible, and bwrap inherits the caller's environment
(`DISPLAY`/`WAYLAND_DISPLAY`) by default. Verified end to end on a live
Mobian/Phosh session: `prismlauncher` launched, rendered its window,
connected to the network, logged into a Minecraft account, downloaded a
modded instance, and **launched the game itself with no visible problems
(GL + audio working)** — #8's full "a world loads" acceptance bar, through
*unmodified* `prefix-run.sh`, before `--gui` added anything.

**`--gui` is what `rootfs` mode actually needs**, since that mode replaces
`/` outright (`bwrap --bind "$ROOTFS" /`) and would not see `$XDG_RUNTIME_DIR`
without an explicit bind. `--gui` adds that bind (plus explicit
`--setenv DISPLAY`/`WAYLAND_DISPLAY`/`XDG_RUNTIME_DIR`, and Java's
`_JAVA_AWT_WM_NONREPARENTING=1`) for both `overlay` and `rootfs`, and —
something nothing did before — **refuses clearly** if no `DISPLAY`+X11
socket or `WAYLAND_DISPLAY`+socket is detected, rather than letting the GUI
app fail deep inside its own Wayland/Qt init with a cryptic error. It's
incompatible with `--mode env`: without an overlay or rootfs, the app's own
`/usr/lib` paths won't resolve either, session or not.

`scripts/catalog/recipes.sh`'s `gui` tier mirrors this: `tier_ok` checks for both
`bwrap` and a live session, so `verify` reports `SKIP` (not a false `FAIL`)
when run from a session-less shell.

## Floor tier: env vars only, no namespaces at all

Below `overlay`/`rootfs` is a weaker tier that needs **nothing** — no
`bwrap`, no userns, no `proot`, not even a built rootfs: `env` var
redirection alone. Two conditions decide whether a package is
floor-supportable, both required:

1. **installs clean** — `check-package.sh`'s `ok`/`risky` verdict, not
   `unlikely` (a root-only postinst always needs a higher tier, or a shim
   that specifically targets it — see `ranger`'s `py3compile`).
2. **every path it reads honors an env override** — nothing baked in that
   no environment variable can redirect. `PYTHONPATH`/`PERL5LIB` (#5, #7),
   `LD_LIBRARY_PATH`, `GOROOT`, `XDG_*`, `TERMINFO_DIRS` are floor knobs;
   an absolute `/usr/share/foo` path compiled into the binary is not — that
   needs `overlay` no matter how RISKY-clean the install was.

Both tested, not assumed, with two real recipes:

- **`golang-go`** — `tier direct`, not even `env`: `go version` *and* a real
  `go run hello.go` (actual compile + execute) both work with **zero** env
  vars. `go` self-locates its stdlib relative to its own binary path, the
  same trick OpenJDK's `java` uses (#17) — nothing to redirect at all.
- **`nodejs`** — genuinely **not** floor-fixable, category 2 above: `node`
  first needs `LD_LIBRARY_PATH` for `libnode.so`, then crashes loading
  `internal/deps/undici/undici` from a hardcoded
  `/usr/share/nodejs/undici/...` path — no env var reaches that. Needs
  `tools/prefix-run.sh` (`overlay`), same as any other baked-in-path case.

**No separate manifest** (`config/floor.tsv`-style) — the standard from #10
already generalized this: `recipes/<pkg>.recipe` *is* the curated,
`verify`-proved catalog for every tier, floor included. A `tier direct` or
`tier env` recipe **is** the floor-tier entry; there's no second system to
maintain.

## The consequence

This is exactly the "what works / what breaks" split in
[`working-packages.md`](working-packages.md): relocatable leaf tools (CLI
utilities, interpreters, `-dev` libraries) work directly; anything that reads
`/etc`, `/usr/share`, `/usr/lib`, or `/usr/libexec` by absolute path — or a
script whose shebang names an interpreter not on this host — needs
`prefix-run.sh` (or a complete rootfs); services/setuid stay out of scope
either way. Interpreted-language apps (Python, Perl, Ruby) are a narrower
case: the *interpreter's own* default module search path
(`sys.path`/`@INC`/`$LOAD_PATH`) misses `$PREFIX`, fixed with an env var (or,
for Python, a `.pth` `install-config.sh` writes globally — see #5) rather
than a full overlay/rootfs. `scripts/catalog/check-package.sh --runtime` reports
which class a package is in (`direct` / `env` / `overlay` / `never`), with an
`interp=`/`shebang:` hint for the env/overlay cases.

The tiers above are a **standard**: each package declares its minimum tier and
the mechanism that gets it there in a `recipes/<pkg>.recipe`, verified by
`scripts/catalog/recipes.sh`. The normative contract is [`standard.md`](standard.md).
