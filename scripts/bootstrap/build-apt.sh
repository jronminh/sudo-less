#!/usr/bin/env bash
# Build upstream apt (Debian 2.8.1) with Termux's patches, retargeted to a
# user-writable prefix ($PREFIX, default ~/.local).
#
# Run inside a Debian sid build environment with:
#   build-essential cmake xsltproc docbook-xsl gettext po4a
#   libgcrypt20-dev libgnutls28-dev libgpg-error-dev libcurl4-openssl-dev
#   liblz4-dev liblzma-dev libbz2-dev zlib1g-dev libzstd-dev libxxhash-dev
#   libdb-dev libseccomp-dev libmd-dev libudev-dev libperl-dev
# (no libselinux1-dev needed)
#
# Key porting decisions (see docs/apt-dpkg-port.md):
#   * @TERMUX_PREFIX@ is a self-contained Termux rootfs; on Debian the helper
#     binaries live in /usr/bin, so map @TERMUX_PREFIX@/bin -> /usr/bin,
#     @TERMUX_PREFIX@/tmp -> /tmp, and only apt's own etc/apt -> $PREFIX.
#   * CMAKE_INSTALL_FULL_LOCALSTATEDIR=$PREFIX/var makes dpkg status resolve to
#     $PREFIX/var/lib/dpkg/status (isolated from the system db).
#   * RPATH=$PREFIX/lib so our libapt-pkg.so.6.0 wins over the system .7.0.
source "$(dirname "$0")/../common.sh"

fetch "$APT_URL" "apt-$APT_VER.tar.gz"
rm -rf "$SRC/apt-$APT_VER"
tar -C "$SRC" -xzf "$SRC/apt-$APT_VER.tar.gz"

cd "$SRC/apt-$APT_VER"
apply_patches "$REPO/patches/apt/termux"
apply_patches "$REPO/patches/apt/local"

log "retargeting @TERMUX_PREFIX@ -> $PREFIX"
mapfile -t files < <(grep -rl '@TERMUX_PREFIX@' \
  --include='*.cc' --include='*.h' --include='*.in' . \
  | grep -v -e '^\./test/' -e '^\./doc/' -e '^\./debian/')
[ "${#files[@]}" -gt 0 ] || die "no files containing @TERMUX_PREFIX@ found (apt layout changed?)"
# helper programs apt shells out to live in the system, not in our prefix
sed -i "s|@TERMUX_PREFIX@/bin/|/usr/bin/|g" "${files[@]}"
sed -i "s|@TERMUX_PREFIX@/tmp|/tmp|g" "${files[@]}"
# DPkg::Path must keep the system PATH (plus our bin) for maintainer scripts
sed -i "s|\"@TERMUX_PREFIX@/bin\"|\"$PREFIX/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\"|" apt-pkg/init.cc
sed -i "s|@TERMUX_PREFIX@|$PREFIX|g" "${files[@]}"
if grep -rn '@TERMUX_PREFIX@' "${files[@]}"; then die "unsubstituted @TERMUX_PREFIX@ remains"; fi

BUILD="$SRC/build-apt"
rm -rf "$BUILD"; mkdir -p "$BUILD"
log "configuring"
cmake -S "$SRC/apt-$APT_VER" -B "$BUILD" \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DPERL_EXECUTABLE=/usr/bin/perl \
  -DCMAKE_INSTALL_FULL_LOCALSTATEDIR="$PREFIX/var" \
  -DCACHE_DIR="$PREFIX/var/cache/apt" \
  -DCOMMON_ARCH="$DEB_ARCH" \
  -DDPKG_DATADIR=/usr/share/dpkg \
  -DUSE_NLS=OFF -DWITH_DOC=OFF -DWITH_DOC_MANPAGES=OFF \
  -DCMAKE_INSTALL_LIBEXECDIR=lib \
  -DCMAKE_INSTALL_RPATH='$ORIGIN/../lib;$ORIGIN/../..' \
  -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
  -DCMAKE_BUILD_TYPE=Release

log "building"
make -C "$BUILD" -j"$(nproc)"
log "installing into $PREFIX"
make -C "$BUILD" install
log "apt installed: $PREFIX/bin/apt ($("$PREFIX/bin/apt" --version | head -1))"
