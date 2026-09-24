#!/usr/bin/env bash
# Build upstream dpkg with sudo-less's patches (apt-dpkg/patches/dpkg/series, a fork of
# Termux's), for a user-writable prefix ($PREFIX, default ~/.local).
#
# Run inside a Debian sid build environment with:
#   build-essential autoconf automake autopoint libtool pkg-config gettext po4a
#   libmd-dev libncurses-dev zlib1g-dev libbz2-dev liblzma-dev libzstd-dev
#
# Key porting decisions (see docs/apt-dpkg-port.md):
#   * The root-only bits (superuser check, chown) are removed by plain
#     patches; nothing is built with -D__ANDROID__ (apt-dpkg/patches/UPSTREAM.md).
#   * A native build: configure finds the architecture itself.
#   * --without-libselinux (Termux's --without-selinux is an unrecognized no-op).
#   * dpkg runs inside the install view (tools/prefix-view.sh, docs/view.md),
#     where the prefix is overlaid on /usr, /etc, /var and /opt. So it is
#     configured with Debian's own paths: config dir /etc/dpkg, admin dir
#     /var/lib/dpkg, root "/". Only the programs and their data live under
#     --prefix; the dpkg-maintscript-helper finds its data next to itself
#     wherever the prefix is (apt-dpkg/patches/dpkg/0100-maintscript-helper-datadir.patch).
#   * The programs that touch the database or the installed tree move to
#     $PREFIX/lib/sudo-less/dpkg; $PREFIX/bin gets a wrapper for each that
#     enters the install view (apt-dpkg/dpkg-wrapper.sh).
source "$(dirname "$0")/../common.sh"

fetch "$DPKG_URL" "dpkg-$DPKG_VER.tar.gz"
rm -rf "$SRC/dpkg-$DPKG_VER"
tar -C "$SRC" -xzf "$SRC/dpkg-$DPKG_VER.tar.gz"

cd "$SRC/dpkg-$DPKG_VER"
# build-aux/get-version needs a git checkout or this marker file
printf '%s\n' "$DPKG_VER" > .dist-version

apply_series "$REPO/apt-dpkg/patches/dpkg"
rm -f configure
log "autogen"
./autogen >/dev/null

log "configuring"
./configure \
  --prefix="$PREFIX" \
  --sysconfdir=/etc \
  --localstatedir=/var \
  --with-pkgconfdir=/etc/dpkg \
  --with-admindir=/var/lib/dpkg \
  --disable-dselect \
  --disable-shared \
  --without-libselinux \
  dpkg_cv_c99_snprintf=yes

log "building"
make -j"$(nproc)"

log "installing into $PREFIX"
# /etc and /var of the view are $PREFIX/etc and $PREFIX/var.
STAGE="$SRC/dpkg-stage"
rm -rf "$STAGE"
make install DESTDIR="$STAGE" >/dev/null
mkdir -p "$PREFIX"
cp -a "$STAGE$PREFIX/." "$PREFIX/"
for d in etc var; do
  [ -d "$STAGE/$d" ] || continue
  mkdir -p "$PREFIX/$d"
  cp -an "$STAGE/$d/." "$PREFIX/$d/"   # never over the prefix's own files
done

VIEW_TOOLS="dpkg dpkg-query dpkg-divert dpkg-statoverride dpkg-trigger update-alternatives"
L="$PREFIX/lib/sudo-less"
mkdir -p "$L/dpkg"
for t in $VIEW_TOOLS; do
  for b in bin sbin; do
    [ -f "$PREFIX/$b/$t" ] || continue
    mv -f "$PREFIX/$b/$t" "$L/dpkg/$t"
    install -m 0755 "$REPO/apt-dpkg/dpkg-wrapper.sh" "$PREFIX/$b/$t"
  done
  [ -x "$L/dpkg/$t" ] || die "dpkg did not install $t"
done
install -m 0755 "$REPO/tools/prefix-view.sh" "$L/prefix-view"
install -m 0755 "$REPO/tools/prefix-wrap.sh" "$L/prefix-wrap"
install -m 0755 "$REPO/tools/prefix-check.sh" "$L/prefix-check"
log "dpkg installed: $PREFIX/bin/dpkg ($("$PREFIX/bin/dpkg" --version | head -1))"
