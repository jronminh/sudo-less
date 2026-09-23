#!/bin/bash
# dev-backend — a userspace stand-in for the admin side of updo, to test the
# client and daemon without root.
#
# Usage: tools/updo/dev-backend.sh start | stop | env
#
# start: runtime user units (gone at logout/reboot) listening on
#   $XDG_RUNTIME_DIR/updo-dev/updo.sock   a persistent-style identity
#   $XDG_RUNTIME_DIR/updo-dev/probe.sock  a per-call-style one (--ephemeral)
# Each call gets its own updod in a sandboxed service (ProtectSystem=strict,
# ProtectHome=read-only, NoNewPrivileges, writable only
# $XDG_RUNTIME_DIR/updo-dev/rw), as the real updo-IDENT@.service will. Unlike
# it, the identity is you: a user manager cannot switch users, so this tests
# the protocol, the sandbox and the client, not the separate uid.
# env: print the variable that points the client at this backend.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RT="${XDG_RUNTIME_DIR:?}"
D="$RT/updo-dev"
UNITS="$RT/systemd/user"

case "${1:-}" in
  start)
    [ -x "$HERE/out/updod" ] || "$HERE/build.sh" >/dev/null
    mkdir -p "$D/rw" "$UNITS"
    install -m 755 "$HERE/out/updod" "$D/updod"     # $HOME is hidden in the sandbox
    for id in updo probe; do
      flag=; [ "$id" = probe ] && flag=--ephemeral
      cat > "$UNITS/updo-dev-$id.socket" <<UNIT
[Socket]
ListenStream=%t/updo-dev/$id.sock
SocketMode=0600
Accept=yes
UNIT
      cat > "$UNITS/updo-dev-$id@.service" <<UNIT
[Service]
ExecStart=$D/updod --allow-uid $(id -u) --name $id $flag
StandardInput=socket
StandardOutput=journal
StandardError=journal
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=yes
NoNewPrivileges=yes
ReadWritePaths=$D/rw
UNIT
    done
    systemctl --user daemon-reload
    systemctl --user start updo-dev-updo.socket updo-dev-probe.socket
    "$0" env ;;
  stop)
    systemctl --user stop updo-dev-updo.socket updo-dev-probe.socket 2>/dev/null || true
    rm -f "$UNITS"/updo-dev-*
    systemctl --user daemon-reload
    rm -rf "$D" ;;
  env)
    echo "export UPDO_RUNDIR=$D" ;;
  *) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
