#!/usr/bin/env bash
# prefix-check — refuse, before dpkg runs, a package that cannot be installed
# into the prefix without root.
#
#   tools/prefix-check.sh < DEB-LIST     (apt's DPkg::Pre-Install-Pkgs hook)
#   tools/prefix-check.sh DEB...         (by hand)
#
# apt passes the .deb files it is about to install, one per line. Each is
# read offline (control fields, maintainer scripts, file list). If one needs
# root to install, the whole run stops here, before anything is unpacked,
# with the package and the reason, so a package that cannot work never
# half-installs and wedges the prefix (docs/standard.md).
#
# The install view (docs/view.md) makes most maintainer scripts work: writes
# to /etc and /var, alternatives, triggers, running the package's own
# programs. What still needs root is listed in RULES below; each came from a
# failure in the survey (docs/survey.md).
#
# SUDO_LESS_CHECK=off skips the check.
set -eu

[ "${SUDO_LESS_CHECK:-}" != off ] || exit 0
: "${PREFIX:=$HOME/.local}"
DEB=$PREFIX/bin/dpkg-deb
[ -x "$DEB" ] || DEB=dpkg-deb

# kind<TAB>where<TAB>extended regex<TAB>reason. where: script (the maintainer
# scripts), files (the file list, `tar -tv` style), depends (Pre-Depends and
# Depends).
RULES=$(cat <<'EOF'
script	script	(^|[^-[:alnum:]])(adduser|useradd|addgroup|groupadd)[[:space:]]	creates a system user or group
depends	depends	(^|[ ,|])adduser([ ,(]|$)	creates a system user or group (depends on adduser)
files	files	\./(usr/)?lib/modules/	installs kernel modules
files	files	\./boot/	installs into /boot
EOF
)

refuse=0
check() {
  local deb=$1 pkg ctl scripts files deps kind where re why hit
  pkg=$("$DEB" -f "$deb" Package 2>/dev/null) || return 0
  ctl=$(mktemp -d)
  "$DEB" -e "$deb" "$ctl" 2>/dev/null || :
  scripts=$(cat "$ctl"/preinst "$ctl"/postinst 2>/dev/null || :)
  rm -rf "$ctl"
  files=$("$DEB" -c "$deb" 2>/dev/null || :)
  deps=$("$DEB" -f "$deb" Pre-Depends Depends 2>/dev/null || :)
  while IFS=$'\t' read -r kind where re why; do
    case $where in
      script) hit=$(grep -m1 -E -- "$re" <<<"$scripts" || :) ;;
      files) hit=$(grep -m1 -E -- "$re" <<<"$files" || :) ;;
      depends) hit=$(grep -m1 -E -- "$re" <<<"$deps" || :) ;;
    esac
    if [ -n "$hit" ]; then
      echo "sudo-less: $pkg needs the admin: it $why" >&2
      echo "    ${hit#"${hit%%[![:space:]]*}"}" | cut -c1-160 >&2
      refuse=1
      return 0
    fi
  done <<<"$RULES"
}

if [ $# -gt 0 ]; then
  for d; do check "$d"; done
else
  while IFS= read -r d; do
    case $d in *.deb) [ -f "$d" ] && check "$d" ;; esac
  done
fi

if [ $refuse = 1 ]; then
  echo "sudo-less: nothing was installed. Ask the admin to install it system-wide," >&2
  echo "    or retry with SUDO_LESS_CHECK=off to try anyway." >&2
  exit 1
fi
