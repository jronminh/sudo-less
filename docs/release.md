# The default route: prebuilt apt/dpkg

`bootstrap.sh` is the **supported** way to use sudo-less. It fetches a prebuilt,
patched apt/dpkg for your architecture, checks its hash, unpacks it into
`$PREFIX` (`~/.local`) and configures it. No root, no build, no namespaces —
nothing beyond `curl` (or `wget`), `tar` and a writable `$PREFIX`. That is the
floor tier; see [`standard.md`](standard.md) for what it does and does not
promise.

```sh
curl -fsSL https://raw.githubusercontent.com/jronminh/sudo-less/main/bootstrap.sh | bash
```

Building from source ([`porting.md`](porting.md)), the overlay and GUI apps
are **experimental** — kept and documented, but
not the promise.

## Trust model: pinned inputs, verifiable output

There is no signature to trust. Instead the inputs are pinned and public, so the
output is reproducible and you can check it yourself:

- **apt 2.8.1** and **dpkg 1.22.6**, with the **verbatim** Termux patch sets
  (`patches/apt/termux/`, `patches/dpkg/termux/`) plus one local apt fix.
- The build is the same scripted, no-fork build the repo already uses
  (`scripts/bootstrap/build-apt.sh`, `build-dpkg.sh`).
- Each release asset ships a `.sha256`; `bootstrap.sh` verifies it and refuses
  to unpack on mismatch.

So verification is: **rebuild from the same pinned inputs and compare.** If the
hash differs from a build you did yourself, don't trust the artifact.

## Compatibility baseline

Releases are built against **Debian 12 (bookworm, oldstable)**, so the binaries
run on bookworm and newer. That is the real compatibility limit: anything older
than bookworm (older glibc) is not supported, and this is stated rather than
hidden.

Build releases in a container pinned to that suite, **not** on the host,
which has whatever suite it happens to run. CI does this
(`.github/workflows/build.yml`, `container: debian:bookworm`); by hand, in
any container runtime:

```sh
podman run --rm -v "$PWD:$PWD" -w "$PWD" debian:bookworm ./scripts/env/build-on-host.sh
```

`package-prebuilt.sh` writes a `<asset>.buildinfo` recording the suite, arch,
apt/dpkg versions and build date. Attach it to the release so the baseline is
*recorded*, not assumed.

The artifact *is* relocatable across users and prefixes: apt follows the config
`install-config.sh` regenerates (`config/apt.conf.d/00local-prefix`), so
`/home/builder/.local` → `/home/you/.local` is fine — see
[`apt-dpkg-port.md`](apt-dpkg-port.md).

## Cutting a release (maintainer)

```sh
# 1. build in a CLEAN prefix against the pinned baseline suite (bookworm):
podman run --rm -v "$PWD:$PWD" -w "$PWD" debian:bookworm ./scripts/env/build-on-host.sh

# 2. package it:
./scripts/bootstrap/package-prebuilt.sh   # -> dist/<asset>, .sha256, .buildinfo

# 3. attach ALL THREE to a GitHub Release (tag = --version for bootstrap.sh):
gh release create <tag> dist/<asset> dist/<asset>.sha256 dist/<asset>.buildinfo
```

The asset name encodes the pinned versions and arch:
`sudo-less-apt-dpkg-<apt>-<dpkg>-<arch>.tar.gz`. Bump `APT_VER`/`DPKG_VER` in
`scripts/common.sh` (and the patch sets) deliberately — not on every upstream
release. `bootstrap.sh` fetches `releases/latest/download/<asset>` by default,
or a specific tag with `--version`.

## Verifying an artifact

```sh
./bootstrap.sh --verify-only      # download + check sha256, unpack nothing
./bootstrap.sh --dry-run          # show what it would do
```

## Scope

- **Supported:** the floor tier (`direct`/`env`) via this route.
- **Experimental:** source builds, the overlay, and GUI apps.
- **Out of scope:** `tier never` packages (32-bit-only, self-updating,
  services, PAM/setuid) — see `recipes/` and [`standard.md`](standard.md).

One tier is supported at a time, deliberately: with one maintainer, only one
tier can be *vouched for*. Another tier graduates from experimental to supported
only when it is verified and stable.
