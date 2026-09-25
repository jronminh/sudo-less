#!/usr/bin/env bash
# Build hostile .deb files and install them with the prefix's dpkg, to check
# that nothing lands in, or is read from, your home outside the prefix
# (issue #29). Each package is purged afterwards.
#
#   dev/hostile-debs.sh
#
# Needs the userspace dpkg installed (PREFIX, default ~/.local) and ar
# (binutils) for the package with a crafted data.tar.
set -u
: "${PREFIX:=$HOME/.local}"
DPKG=$PREFIX/bin/dpkg
W=$(mktemp -d "${TMPDIR:-/tmp}/hostile-debs.XXXXXX")
trap 'rm -rf "$W"' EXIT
fail=0

# The files a hostile package tries to write or read, on the host.
MARK=$HOME/.sudo-less-hostile
SECRET=$HOME/.sudo-less-secret-test
echo "secret $$" > "$SECRET"
rm -rf "$MARK"*

control() {  # control DIR NAME
  mkdir -p "$1/DEBIAN"
  printf 'Package: %s\nVersion: 1.0\nArchitecture: all\nMaintainer: test <t@t>\nDescription: hostile test package\n' \
    "$2" > "$1/DEBIAN/control"
}
build() { dpkg-deb --root-owner-group --build "$1" "$W/$2.deb" >/dev/null; }
install_deb() { "$DPKG" -i "$W/$1.deb" >"$W/$1.log" 2>&1; echo $?; }
purge() { "$DPKG" -P --force-remove-reinstreq "$@" >/dev/null 2>&1 || :; }
check() {  # check NAME CONDITION-DESCRIPTION COMMAND...
  local name=$1 what=$2; shift 2
  if "$@"; then printf 'ok    %-24s %s\n' "$name" "$what"
  else printf 'FAIL  %-24s %s\n' "$name" "$what"; fail=1; fi
}

# 1. A maintainer script writes and reads your home.
d=$W/t1; control "$d" hostile-postinst
cat > "$d/DEBIAN/postinst" <<EOF
#!/bin/sh
echo pwned > "$MARK-postinst" 2>/dev/null
mkdir -p /usr/share/hostile-postinst
cat "$SECRET" > /usr/share/hostile-postinst/stolen 2>/dev/null
ls -A "$HOME" > /usr/share/hostile-postinst/home-list 2>/dev/null
exit 0
EOF
chmod 0755 "$d/DEBIAN/postinst"; build "$d" hostile-postinst
install_deb hostile-postinst >/dev/null
check postinst-write "a postinst cannot write \$HOME" test ! -e "$MARK-postinst"
check postinst-read "a postinst cannot read \$HOME" \
  sh -c "! grep -q secret '$PREFIX/usr/share/hostile-postinst/stolen' 2>/dev/null"
check postinst-list "a postinst sees only the prefix in \$HOME" \
  sh -c "! grep -qvxE '\\.local' '$PREFIX/usr/share/hostile-postinst/home-list' 2>/dev/null"
purge hostile-postinst

# 2. Package A ships a directory symlink into your home, package B a file
# through it.
d=$W/t2a; control "$d" hostile-link
mkdir -p "$d/usr/share"; ln -s "$HOME" "$d/usr/share/hostile-link"; build "$d" hostile-link
d=$W/t2b; control "$d" hostile-through
mkdir -p "$d/usr/share/hostile-link"; echo pwned > "$d/usr/share/hostile-link/.sudo-less-hostile-through"
build "$d" hostile-through
install_deb hostile-link >/dev/null; install_deb hostile-through >/dev/null
check symlink-through "a file through another package's symlink stays out of \$HOME" \
  test ! -e "$MARK-through"
purge hostile-through hostile-link

# 3. A data.tar member with ../ in its name.
if command -v ar >/dev/null; then
  d=$W/t3; control "$d" hostile-dotdot; mkdir -p "$d/usr/share/doc"; build "$d" hostile-dotdot
  mkdir -p "$W/t3x/x" && echo pwned > "$W/t3x/x/f"
  (cd "$W/t3x" && tar --transform "s,^x/f,../../../../../../..$MARK-dotdot," -cJf data.tar.xz x/f 2>/dev/null)
  # dpkg-deb builds only clean archives: swap in the crafted data.tar.
  (cd "$W" && ar x hostile-dotdot.deb debian-binary control.tar.xz && rm hostile-dotdot.deb &&
    ar rc hostile-dotdot.deb debian-binary control.tar.xz t3x/data.tar.xz)
  install_deb hostile-dotdot >/dev/null
  check dotdot "a ../ member stays out of \$HOME" test ! -e "$MARK-dotdot"
  purge hostile-dotdot
else
  echo "skip  dotdot                   (no ar)"
fi

# 4. A setuid program.
d=$W/t4; control "$d" hostile-suid
mkdir -p "$d/usr/bin"; printf '#!/bin/sh\nid\n' > "$d/usr/bin/hostile-suid"; chmod 4755 "$d/usr/bin/hostile-suid"
build "$d" hostile-suid; install_deb hostile-suid >/dev/null
check setuid "a setuid bit is not kept" \
  sh -c "[ -e '$PREFIX/usr/bin/hostile-suid' ] && [ ! -u '$PREFIX/usr/bin/hostile-suid' ]"
purge hostile-suid

rm -f "$SECRET"; rm -rf "$MARK"*
[ $fail = 0 ] && echo "all passed" || echo "some FAILED (logs were in $W)"
exit $fail
