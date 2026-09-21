#!/usr/bin/env bash
# Predict whether a Debian package will work when installed into a userspace
# prefix (~/.local) by the ported apt/dpkg — WITHOUT installing it.
#
#   ./scripts/check-package.sh PKG [PKG...]
#   ./scripts/check-package.sh --meta PKG      # index metadata only (no download)
#
# How: fetch the .deb from the repo (apt-get download), then read it offline
# with dpkg-deb:
#   * control scripts (preinst/postinst/prerm/postrm) -> root-only commands
#   * file list -> system-integration paths (systemd, python dist-packages, ...)
# plus the index metadata (Section/Priority/Essential/Depends).
#
# Verdicts: OK / RISKY / UNLIKELY, with the reasons.
set -uo pipefail
source "$(dirname "$0")/common.sh"

META_ONLY=0
[ "${1:-}" = "--meta" ] && { META_ONLY=1; shift; }
[ $# -gt 0 ] || { echo "usage: $0 [--meta] PKG..." >&2; exit 2; }

APT="$PREFIX/bin/apt-get"
APT_CACHE="$PREFIX/bin/apt-cache"
DPKG_DEB="$(command -v dpkg-deb || echo "$PREFIX/bin/dpkg-deb")"

# apt-cache/apt-get download need the package index; populate it if missing.
if ! compgen -G "$PREFIX/var/lib/apt/lists/*_Packages*" >/dev/null; then
  log "no package lists; running apt-get update"
  "$APT" update
fi

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# script commands that need root / system integration
RISKY_SCRIPT='systemctl|invoke-rc.d|update-rc.d|/etc/init.d|adduser|useradd|groupadd|debconf|ldconfig|update-alternatives|dpkg-statoverride|chroot|py3compile|update-ca-certificates|update-fonts|pam-auth-update|update-menus|update-desktop-database|dpkg-trigger|/var/lib/dpkg/info'
# file paths that indicate system integration
RISKY_FILES='/lib/systemd/|/usr/lib/systemd/|/etc/init.d/|/usr/lib/python3/dist-packages/|/usr/libexec/|/usr/lib/udev/|/etc/dbus-1/|/usr/share/polkit-1/|/lib/modules/|/etc/pam.d/|/etc/ld.so.conf.d/|/usr/lib/tmpfiles.d/|/etc/default/|/usr/share/dbus-1/'
# dependency names that pull in system plumbing
RISKY_DEPS='init-system-helpers|systemd|adduser|debconf|libpam|passwd|login|initramfs-tools|ucf|lsb-base|sysvinit'

check_one() {
  local pkg="$1" reasons=() verdict="OK"
  local meta section essential depends
  meta="$("$APT_CACHE" show "$pkg" 2>/dev/null)" || { echo "$pkg: NOT IN REPO"; return; }
  section="$(sed -n 's/^Section: //p' <<<"$meta" | head -1)"
  essential="$(sed -n 's/^Essential: //p' <<<"$meta" | head -1)"
  depends="$(sed -n 's/^\(Pre-\)\?Depends: //p' <<<"$meta" | paste -sd, -)"

  [[ "$essential" == yes ]] && reasons+=("Essential package")
  if grep -Eqi "$RISKY_DEPS" <<<"$depends"; then
    reasons+=("deps pull system plumbing ($(grep -Eoi "$RISKY_DEPS" <<<"$depends" | sort -u | paste -sd, -))")
  fi

  local scripts="" files=""
  if [ "$META_ONLY" -eq 0 ]; then
    if ( cd "$WORK" && "$APT" download "$pkg" >/dev/null 2>&1 ); then
      local deb; deb="$(ls "$WORK"/"${pkg}"_*.deb 2>/dev/null | head -1)"
      if [ -n "$deb" ]; then
        rm -rf "$WORK/ctrl"
        "$DPKG_DEB" -e "$deb" "$WORK/ctrl" >/dev/null 2>&1
        scripts="$(cat "$WORK"/ctrl/{preinst,postinst,prerm,postrm} 2>/dev/null || true)"
        files="$("$DPKG_DEB" -c "$deb" 2>/dev/null || true)"
        if grep -Eqi "$RISKY_SCRIPT" <<<"$scripts"; then
          reasons+=("maintainer script: $(grep -Eoi "$RISKY_SCRIPT" <<<"$scripts" | sort -u | paste -sd, -)")
        fi
        if grep -Eqi "$RISKY_FILES" <<<"$files"; then
          reasons+=("system paths: $(grep -Eoi "$RISKY_FILES" <<<"$files" | sort -u | paste -sd, -)")
        fi
        if grep -Eq '^[-r][-r]w[-r]x[-r]x' <<<"$files" && grep -Eq ' rws| rs' <<<"$files"; then
          reasons+=("setuid/setgid files")
        fi
      else
        reasons+=("download produced no .deb")
      fi
    else
      reasons+=("could not download")
    fi
  fi

  # verdict
  if [ "${#reasons[@]}" -eq 0 ]; then
    printf '%-14s %-9s section=%s\n' "$pkg" "OK" "${section:-?}"
  else
    printf '%-14s %-9s %s\n' "$pkg" "UNLIKELY" "${reasons[*]}"
  fi
}

for p in "$@"; do check_one "$p"; done
