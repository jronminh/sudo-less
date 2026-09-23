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
#   * The config dir ($PREFIX/etc/dpkg) and admin dir ($PREFIX/var/lib/dpkg)
#     are compiled in under the build prefix and relocated at run time to
#     wherever dpkg is installed (patches/dpkg/0100-relocatable.patch).
#   * --sysconfdir=/etc, --localstatedir=/var: update-alternatives uses them
#     as paths inside the install root (DPKG_ROOT, the prefix), so they keep
#     Debian's values: $PREFIX/etc/alternatives, $PREFIX/var/log.
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
  --localstatedir=/var \
  --with-pkgconfdir="$PREFIX/etc/dpkg" \
  --disable-dselect \
  --disable-shared \
  --without-libselinux \
  --with-admindir="$PREFIX/var/lib/dpkg" \
  dpkg_cv_c99_snprintf=yes

log "building"
make -j"$(nproc)"
log "installing into $PREFIX"
# sysconfdir is already compiled in as /etc; overriding it here only moves
# alternatives/README, which a non-root build cannot write to /etc.
make install sysconfdir="$PREFIX/etc"
log "dpkg installed: $PREFIX/bin/dpkg ($("$PREFIX/bin/dpkg" --version | head -1))"
