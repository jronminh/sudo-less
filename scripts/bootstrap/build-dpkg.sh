#!/usr/bin/env bash
# Build upstream dpkg (1.22.6) with Termux's patches, for a user-writable
# prefix ($PREFIX, default ~/.local).
#
# Run inside a Debian sid build environment with:
#   build-essential autoconf automake autopoint libtool pkg-config gettext po4a
#   libmd-dev libncurses-dev zlib1g-dev libbz2-dev liblzma-dev libzstd-dev
#
# Key porting decisions (see docs/apt-dpkg-port.md):
#   * Upstream dpkg has ZERO __ANDROID__ references; Termux's patches wrap the
#     root-only bits (superuser check, chown) in #ifndef __ANDROID__. We compile
#     with -D__ANDROID__ to activate them, i.e. this is "Termux dpkg".
#   * configure.diff hardcodes the arch as TERMUX_ARCH; on a native build we
#     substitute the host's values (DEB_CPU / DEB_ARCH, auto-detected).
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

apply_patches "$REPO/patches/dpkg/termux"
# configure.diff is applied after autogen regenerates ./configure
rm -f configure
log "autogen"
./autogen >/dev/null
log "applying configure.diff"
patch -p1 -F3 --no-backup-if-mismatch < "$REPO/patches/dpkg/termux/configure.diff"
sed -i "s/cpu_type=TERMUX_ARCH/cpu_type=$DEB_CPU/" configure
sed -i "s/dpkg_arch=TERMUX_ARCH/dpkg_arch=$DEB_ARCH/" configure

log "configuring"
./configure \
  --prefix="$PREFIX" \
  --sysconfdir=/etc \
  --disable-dselect \
  --disable-shared \
  --without-libselinux \
  --with-admindir="$PREFIX/var/lib/dpkg" \
  dpkg_cv_c99_snprintf=yes \
  CPPFLAGS="-D__ANDROID__"

log "building"
make -j"$(nproc)"
log "installing into $PREFIX"
make install
log "dpkg installed: $PREFIX/bin/dpkg ($("$PREFIX/bin/dpkg" --version | head -1))"
