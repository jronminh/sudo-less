#!/usr/bin/env bash
# Build upstream dpkg with sudo-less's patches (patches/dpkg/series, a fork of
# Termux's), for a user-writable prefix ($PREFIX, default ~/.local).
#
# Run inside a Debian sid build environment with:
#   build-essential autoconf automake autopoint libtool pkg-config gettext po4a
#   libmd-dev libncurses-dev zlib1g-dev libbz2-dev liblzma-dev libzstd-dev
#
# Key porting decisions (see docs/apt-dpkg-port.md):
#   * The root-only bits (superuser check, chown) are removed by plain
#     patches; nothing is built with -D__ANDROID__ (patches/UPSTREAM.md).
#   * A native build: configure finds the architecture itself.
#   * --without-libselinux (Termux's --without-selinux is an unrecognized no-op).
#   * admindir defaults to $PREFIX/var/lib/dpkg via --with-admindir.
#   * --sysconfdir=/etc: dpkg's config dir must NOT be $PREFIX/etc, or a
#     relocated artifact tries to read the *builder's* prefix (unreadable to
#     another user) and dies with "error opening configuration directory".
#     The admin dir stays $PREFIX via --with-admindir, so the db is still local.
source "$(dirname "$0")/../common.sh"

fetch "$DPKG_URL" "dpkg-$DPKG_VER.tar.gz"
rm -rf "$SRC/dpkg-$DPKG_VER"
tar -C "$SRC" -xzf "$SRC/dpkg-$DPKG_VER.tar.gz"

cd "$SRC/dpkg-$DPKG_VER"
# build-aux/get-version needs a git checkout or this marker file
printf '%s\n' "$DPKG_VER" > .dist-version

apply_series "$REPO/patches/dpkg"
rm -f configure
log "autogen"
./autogen >/dev/null

log "configuring"
./configure \
  --prefix="$PREFIX" \
  --sysconfdir=/etc \
  --disable-dselect \
  --disable-shared \
  --without-libselinux \
  --with-admindir="$PREFIX/var/lib/dpkg" \
  dpkg_cv_c99_snprintf=yes

log "building"
make -j"$(nproc)"
log "installing into $PREFIX"
# sysconfdir is already compiled in as /etc; overriding it here only moves
# the files `make install` would put there (alternatives/README, dpkg.cfg.d),
# which a non-root build cannot write.
make install sysconfdir="$PREFIX/etc"
log "dpkg installed: $PREFIX/bin/dpkg ($("$PREFIX/bin/dpkg" --version | head -1))"
