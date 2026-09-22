#!/usr/bin/env bash
# flatpak/bridge.sh — run a Flatpak app with extra host paths substituted
# before Flatpak's own sandbox is built.
#
# The problem this fixes: some Flatpak apps talk to a system daemon over a
# Unix socket at a *fixed* path (usually under /run), and neither the app
# nor the client library it's built on exposes any override — no flag, no
# env var, no preferences field. Flatpak's own `--filesystem` permission
# only ever mounts a host path at the *same* absolute path inside the
# sandbox; it cannot remap. If you have no root, you can't create that path
# under the real /run either — so the app is stuck even though a perfectly
# good sudo-less *userspace* daemon may already be running somewhere you
# *can* write to (e.g. $XDG_RUNTIME_DIR).
#
# The fix: build an unprivileged bwrap mount namespace *around* `flatpak
# run`, the same base bind tools/prefix-run.sh's overlay mode already uses
# (--ro-bind / /, see docs/paths.md), then bind your real userspace path
# on top at the fixed path the app expects. `flatpak run`, executed inside
# that namespace, sees the substitute as if it were real; Flatpak's own
# inner sandbox is built from *that* view, so its manifest permission
# (e.g. filesystems=/run/foo:ro) picks it up with zero Flatpak-side
# changes. No root anywhere — unprivileged user+mount namespaces only.
#
# Usage:
#   flatpak/bridge.sh APPID FAKE=REAL [FAKE=REAL...] [-- ARGS...]
#
# Example (see flatpak/fixes/dev.deedles.Trayscale.fix):
#   flatpak/bridge.sh dev.deedles.Trayscale \
#     /run/tailscale=/run/user/"$(id -u)"/tailscale
#
# This is a bridge, not an installer: REAL must already exist (start your
# userspace daemon first) and the bridge only lasts for this one
# invocation — there's no persistence, no service, nothing left running
# after the app closes beyond what you started yourself.
#
# See docs/flatpak-bridge.md for the write-up, the decision tree against
# the alternatives (one-time root + tmpfiles.d; patch + rebuild the app),
# and the .fix file schema.
set -euo pipefail

usage() {
  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

[ $# -ge 1 ] || usage 1
case "$1" in
  -h|--help) usage 0 ;;
esac

appid="$1"; shift

# `--ro-bind / /` (the same base tools/prefix-run.sh's overlay mode uses,
# see docs/paths.md) leaves every existing directory read-only, so bwrap
# can't create a brand-new mountpoint under it (e.g. /run/tailscale, when
# only /run exists on the real host). prefix-run.sh's own fix for this
# (--overlay-src + --tmp-overlay, i.e. real unprivileged overlayfs) failed
# here with EINVAL — this kernel/config doesn't take it for /run, whatever
# the reason. Fall back to a technique that needs nothing but bind mounts:
# --tmpfs the FAKE path's *parent*, then re-bind every entry that was
# already there so the sandbox's view is unchanged except for the one path
# being substituted. Scoped per-mapping, deduplicated.
shopt -s nullglob
declare -A seen_parent
overlays=()
binds=()
while [ $# -gt 0 ] && [ "$1" != "--" ]; do
  map="$1"; shift
  case "$map" in
    *=*) fake="${map%%=*}"; real="${map#*=}" ;;
    *)   echo "bad mapping (want FAKE=REAL): $map" >&2; exit 1 ;;
  esac
  [ -n "$fake" ] && [ -n "$real" ] || {
    echo "bad mapping (want FAKE=REAL): $map" >&2; exit 1
  }
  [ -e "$real" ] || echo "warning: $real does not exist yet — is the userspace daemon running?" >&2

  parent="$(dirname "$fake")"
  if [ -z "${seen_parent[$parent]:-}" ]; then
    seen_parent[$parent]=1
    overlays+=(--tmpfs "$parent")
    for entry in "$parent"/*; do
      [ -e "$entry" ] || continue
      overlays+=(--bind "$entry" "$entry")
    done
  fi
  binds+=(--bind "$real" "$fake")
done
[ "${1:-}" = "--" ] && shift

[ "${#binds[@]}" -gt 0 ] || { echo "no FAKE=REAL mappings given" >&2; usage 1; }

exec bwrap \
  --unshare-user --unshare-pid \
  --ro-bind / / \
  --dev-bind /dev /dev \
  --proc /proc \
  --bind /tmp /tmp \
  --bind "$HOME" "$HOME" \
  "${overlays[@]}" \
  "${binds[@]}" \
  --die-with-parent \
  -- flatpak run "$appid" "$@"
