#!/bin/sh
# Installed by build-dpkg.sh as $PREFIX/bin/dpkg, dpkg-query, dpkg-divert,
# dpkg-statoverride, dpkg-trigger and update-alternatives: runs the real one
# (in $PREFIX/lib/sudo-less/dpkg) inside the prefix view, where it has root
# "/" and admin dir /var/lib/dpkg, like Debian's (docs/view.md).
#
# Queries that only read the database skip the view (it costs ~0.3s, and apt
# asks dpkg for the foreign architectures on every run): they get the
# prefix's admin dir instead.
self=$(readlink -f "$0")
P=${self%/bin/*}
n=${0##*/}
real=$P/lib/sudo-less/dpkg/$n

if [ -z "${SUDO_LESS_VIEW:-}" ]; then
  fast=
  case $n in
    dpkg-query) fast=1 ;;
    dpkg)
      for a; do
        case $a in
          --print-architecture|--print-foreign-architectures|--assert-*|\
          --compare-versions|--version|--help|-l|--list|-s|--status|\
          -L|--listfiles|-S|--search|-p|--print-avail|--get-selections)
            fast=1; break ;;
        esac
      done ;;
  esac
  [ -z "$fast" ] || exec "$real" --admindir="$P/var/lib/dpkg" "$@"
  # The view gives the prefix a copy of each host directory these .deb files
  # install into (tools/prefix-view.sh). apt passes a directory of them with
  # --recursive.
  debs= rec=
  if [ "$n" = dpkg ]; then
    for a; do case $a in -R|--recursive) rec=1 ;; esac; done
    for a; do
      case $a in
        -*) ;;
        *.deb) [ ! -f "$a" ] || debs="$debs$a
" ;;
        *) [ -z "$rec" ] || [ ! -d "$a" ] ||
             debs="$debs$(find -L "$a" -type f -name '*.deb')
" ;;
      esac
    done
  fi
  PREFIX=$P PREFIX_VIEW_DEBS=$debs exec "$P/lib/sudo-less/prefix-view" "$real" "$@"
fi
exec "$real" "$@"
