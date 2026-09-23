# Mechanisms: environment and overlay

How sudo-less makes a relocated package run. This is the **inside** view,
for people working on sudo-less. A user sees none of it: they see only
whether a package is in scope ([`standard.md`](standard.md)), and in scope
means `apt-get install PKG` and then `PKG` works.

## The problem

A program does not find its config and data relative to where its `.deb` was
unpacked. Debian builds binaries for the root prefix `/`, so a compiled-in
path such as `/etc/foo/foo.conf` or `/usr/share/foo/templates` is a
**constant string in the binary**. Unpacking with `--instdir=$PREFIX` puts the
files at `~/.local/etc/...` and `~/.local/usr/share/...`, but the binary still
opens `/etc/...` and `/usr/share/...`. It ignores the relocated copies, and
may read the host's files instead.

Environments solve this in one of two ways:

| environment | model | what makes the paths right |
|---|---|---|
| normal distro | install at `/` | the build prefix *is* the runtime prefix |
| Termux, NixOS | rebuild with the target prefix | paths are compiled in correctly |
| Flatpak, AppImage, `chroot`/`proot` | make the prefix look like `/` at run time | the tree is mounted where the binary expects it |

sudo-less rebuilds only apt and dpkg ([`apt-dpkg-port.md`](apt-dpkg-port.md))
and installs every other package unchanged. So it uses the second way where
it must, and cheaper tricks where they are enough.

## The mechanisms

From cheapest to heaviest. sudo-less picks the cheapest one that works for a
package, and applies it **automatically**.

| mechanism | fixes | needs | how it is applied |
|---|---|---|---|
| **none** | nothing to fix: the package finds its files relative to its binary, or through `PATH` | nothing | — |
| **environment** | a lookup that honors a variable (`PERL5LIB`, `JAVA_HOME`, `XDG_DATA_DIRS`, `LD_LIBRARY_PATH`, …) | nothing | set once for every package, by each ecosystem's hook |
| **shim** | a maintainer script calling a tool with an absolute path (`py3compile`) | nothing | a replacement on `PATH`, from `ecosystems/*/shims/` |
| **overlay** | paths compiled into the binary (`/usr/share/...`, `/etc/...`), shebangs naming an interpreter only in the prefix | unprivileged user namespaces + overlayfs (enabled once by `admin/enable-userspace.sh`) | a wrapper runs the command through `tools/prefix-run.sh` |

`scripts/catalog/check-package.sh --runtime` tells which mechanism a package
needs. On a random sample of 516 packages from the supported sections
(2026-09-23), it predicted: none 73 %, overlay 17 %, environment 4 %, and 4 %
out of reach (`never`).

## Environment

A variable set **once for every package**, never per package. Each
ecosystem's `install.sh` hook (run by `scripts/setup/install-config.sh`) sets
what its language needs:

| ecosystem | what it sets | status |
|---|---|---|
| Python | a `.pth` file in the system python3's user site, adding `$PREFIX/usr/lib/python3/dist-packages` to `sys.path` | done (`ecosystems/python/install.sh`) |
| Perl | `PERL5LIB` with the host's own architecture triplet and Perl version | to do; today a recipe pins it (`recipes/pmarkdown.recipe`) |
| Java | `JAVA_HOME` for the default JDK installed with `deb2home` | to do; today a recipe pins it |
| Ruby | `RUBYLIB` / `GEM_PATH` | to do; today some gems use the overlay |
| all | `PATH`, `XDG_DATA_DIRS`, `DPKG_ADMINDIR` | done (`scripts/setup/install-shell-path.sh`, `install-session-env.sh`) |

A variable works only if **every path the program reads honors it**. If one
path is compiled in, the package needs the overlay no matter what the
environment says. `nodejs` is the example: `LD_LIBRARY_PATH` finds
`libnode.so`, then `node` loads `/usr/share/nodejs/undici/...` by absolute
path, which no variable reaches.

A variable that reaches a program's library search path (`LD_LIBRARY_PATH`)
affects every program started from that shell, so it is set only where it is
needed and never ahead of the system's own directories.

## Overlay

The overlay makes the prefix look like `/usr` and `/etc` **stacked over** the
host's, not in place of them. The prefix holds only the packages you
installed, and base libraries still come from the system (the seeded dpkg
database keeps apt from duplicating them), so replacing `/usr` would hide
them.

### How it runs: `tools/prefix-run.sh`

`prefix-run.sh` builds the view in a private user and mount namespace and
runs the command in it. It chooses a runner by what the host has:

| runner | how | extra deps | kernel |
|---|---|---|---|
| `overlay` | `bwrap` overlays `$PREFIX/{usr,etc}` on `/usr`, `/etc` | `bubblewrap` | userns + overlayfs ≥ 5.11 |
| `overlay-native` | the same with `unshare -Urm` + `mount -t overlay` | none (util-linux ≥ 2.38) | userns + overlayfs ≥ 5.11 |

```sh
tools/prefix-run.sh jq . file.json                    # picks a runner
tools/prefix-run.sh --explain --print tree /some/dir  # show what it would run
```

The bwrap form, by hand:

```sh
bwrap --ro-bind / / \
  --overlay-src /usr --overlay-src "$PREFIX/usr" --tmp-overlay /usr \
  --overlay-src /etc --overlay-src "$PREFIX/etc" --tmp-overlay /etc \
  --dev-bind /dev /dev --proc /proc -- "$@"
```

`--tmp-overlay` (bubblewrap ≥ 0.9.0) gives a throwaway writable upper layer,
so writes to `/etc` never reach the host.

The native form needs only util-linux and the kernel:

```sh
U=$(id -u) G=$(id -g) unshare -Urm --propagation private bash -c '
  ovl=$(mktemp -d); mount -t tmpfs -o mode=0700 tmpfs "$ovl"
  mkdir "$ovl/up" "$ovl/wk"
  mount -t overlay overlay \
    -o "lowerdir=$PREFIX/usr:/usr,upperdir=$ovl/up,workdir=$ovl/wk" /usr
  exec unshare -U --map-user="$U" --map-group="$G" -- "$@"' _ CMD
```

- `lowerdir` is **leftmost-wins**, the reverse of bwrap's `--overlay-src`
  order.
- `unshare -Ur` makes you uid 0 inside, which some programs refuse (the
  userspace apt does); a nested namespace (`--map-user`) maps the command
  back to your own uid.
- `$PREFIX` may not contain `:` or `,`, nor live under `/usr` or `/etc`.
- The lower layer must have no locked mounts below it. Inside a systemd
  sandbox with `ProtectKernelModules=` (a hidden `/usr/lib/modules`),
  overlayfs refuses `/usr` ("failed to clone lowerpath").

There is deliberately **no root variant**. Once `/usr` is overlaid with a
user-owned tree, anything root runs in that namespace (`ld.so`, libc, mount
helpers) may be the user's file.

### Applied automatically: wrappers (to do)

Today a user must know to type `tools/prefix-run.sh node`. The plan: after
each install, for every binary `check-package.sh --runtime` marks as needing
the overlay, write a wrapper into `$PREFIX/bin` that runs the real binary
through `prefix-run.sh`. `$PREFIX/bin` is first on `PATH`, so `node` works as
typed.

- The wrapper execs the binary from `$PREFIX/usr/bin` by absolute path, so it
  never calls itself.
- A recipe's `mechanism` key overrides the prediction either way.
- If the host cannot build the overlay (no user namespaces), the wrapper says
  so and names the admin step, instead of failing deep inside the program.
- Removing the package removes its wrappers.

## Desktop session

Being a GUI app is a property of a package, not a mechanism. Its launcher and
icons are found through `XDG_DATA_DIRS`, which `install-session-env.sh` sets
for the whole desktop session. Under the overlay, the session is already
visible, because the base bind is the host's whole `/`: `/tmp/.X11-unix`,
`$XDG_RUNTIME_DIR` (Wayland, PipeWire) and `/dev/dri`. Verified with
`prismlauncher`, which launched a modded game with GL and audio (#8).

`prefix-run.sh --gui` makes the session binds explicit and refuses clearly
when no session is found.

## Not a mechanism: a second root filesystem

sudo-less does not run packages inside a complete rootfs (a whole Debian
built with `mmdebstrap`, where maintainer scripts run as namespace root). The
packages that would need one have root-only maintainer scripts: services,
system users, setuid. Those are the admin's or `never` by scope, and a
second Debian with its own updates is not "the system's packages in
`~/.local`". For a whole distribution without root, use rootless podman or
distrobox.
