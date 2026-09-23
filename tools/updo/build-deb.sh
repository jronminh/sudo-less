#!/bin/sh
# Build updo_VERSION_ARCH.deb into tools/updo/out/. No root needed to build;
# installing it is the admin step that enables updo (docs/updo.md).
#
#   /usr/bin/updo                               the client (any user)
#   /usr/libexec/updo/updod                     the daemon, run per call by systemd
#   /usr/sbin/updo-admin                        check | apply | list
#   /usr/lib/systemd/system-generators/updo-generator
#                                               units from updo.conf, every boot
#                                               and daemon-reload
#   /etc/updo/updo.conf, /etc/updo/conf.d/      the policy (conffile)
#   /usr/lib/sysctl.d/60-updo.conf              dev.tty.legacy_tiocsti = 0
set -eu
umask 022
cd "$(dirname "$0")"
VERSION=0.1.0
ARCH="$(dpkg --print-architecture)"
./build.sh >/dev/null
R="$(mktemp -d)"; chmod 755 "$R"
trap 'rm -rf "$R"' EXIT

install -D -m 755 out/updo "$R/usr/bin/updo"
install -D -m 755 out/updod "$R/usr/libexec/updo/updod"
install -D -m 755 updo-admin "$R/usr/sbin/updo-admin"
install -D -m 644 updo.conf "$R/etc/updo/updo.conf"
mkdir -p "$R/etc/updo/conf.d"
install -d "$R/usr/lib/systemd/system-generators" "$R/usr/lib/sysctl.d" "$R/usr/share/doc/updo"
cat > "$R/usr/lib/systemd/system-generators/updo-generator" <<'EOF'
#!/bin/sh
# One socket + service template per enabled identity in /etc/updo/updo.conf.
exec /usr/libexec/updo/updod --generate "$1"
EOF
chmod 755 "$R/usr/lib/systemd/system-generators/updo-generator"
cat > "$R/usr/lib/sysctl.d/60-updo.conf" <<'EOF'
# updo hands the caller's terminal to the identity: it must not be able to
# type into it (TIOCSTI).
dev.tty.legacy_tiocsti = 0
EOF
cat > "$R/usr/share/doc/updo/README" <<'EOF'
updo: run commands as a bounded middle identity, never root.
Policy: /etc/updo/updo.conf, then `updo-admin apply`. Design: docs/updo.md
in https://github.com/jronminh/sudo-less
EOF

mkdir -p "$R/DEBIAN"
cat > "$R/DEBIAN/control" <<EOF
Package: updo
Version: $VERSION
Architecture: $ARCH
Maintainer: jronminh <congminh9981@gmail.com>
Depends: libc6, systemd
Section: admin
Priority: optional
Description: run commands as a bounded middle identity, never root
 A sudo-like client and a socket-activated daemon. The admin decides in
 /etc/updo/updo.conf which users may act as which identity, and what that
 identity may run and write; systemd sandboxes every call. No setuid binary,
 no password, no ssh, no long-running root process.
EOF
echo /etc/updo/updo.conf > "$R/DEBIAN/conffiles"
cat > "$R/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = configure ] && [ -d /run/systemd/system ]; then
  sysctl -q -w dev.tty.legacy_tiocsti=0 2>/dev/null || true
  updo-admin apply || echo "updo: fix /etc/updo/updo.conf, then run updo-admin apply" >&2
fi
EOF
cat > "$R/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = remove ] && [ -d /run/systemd/system ]; then
  for u in $(systemctl list-units --plain --no-legend --all 'updo-*.socket' | awk '{print $1}'); do
    systemctl stop "$u" || true
  done
fi
EOF
cat > "$R/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
[ ! -d /run/systemd/system ] || systemctl daemon-reload || true
# the identities' users stay (their uids may own files); their homes go
[ "$1" != purge ] || rm -rf /var/lib/updo /var/lib/private/updo
EOF
chmod 755 "$R/DEBIAN/postinst" "$R/DEBIAN/prerm" "$R/DEBIAN/postrm"
dpkg-deb --root-owner-group -Zxz --build "$R" "out/updo_${VERSION}_${ARCH}.deb" >/dev/null
echo "built: $(pwd)/out/updo_${VERSION}_${ARCH}.deb"
