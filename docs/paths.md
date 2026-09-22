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
than a full overlay/rootfs. `scripts/check-package.sh --runtime` reports
which class a package is in (`direct` / `env` / `overlay` / `never`), with an
`interp=`/`shebang:` hint for the env/overlay cases.

The tiers above are a **standard**: each package declares its minimum tier and
the mechanism that gets it there in a `recipes/<pkg>.recipe`, verified by
`scripts/recipes.sh`. The normative contract is [`standard.md`](standard.md).
