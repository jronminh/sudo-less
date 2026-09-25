#!/bin/sh
# Installed by build-dpkg.sh as $PREFIX/bin/dpkg, dpkg-query, dpkg-divert,
# dpkg-statoverride, dpkg-trigger and update-alternatives: runs the real one
# (in $PREFIX/lib/sudo-less/dpkg) inside the prefix view, where it has root
# "/" and admin dir /var/lib/dpkg, like Debian's (docs/view.md).
#
# dpkg --install, --remove, ... are followed by prefix-integrate (below).
#
# Queries that only read the database skip the view (it costs ~0.15 s, and
# apt asks dpkg for the foreign architectures on every run): they get the
# prefix's admin dir instead. In the run view anything else is refused:
# the install view cannot be built inside it.
self=$(readlink -f "$0")
P=${self%/bin/*}
n=${0##*/}
real=$P/lib/sudo-less/dpkg/$n

# In a private view already (the install view, or a service's): run it.
[ "${SUDO_LESS_VIEW:-}" != private ] || exec "$real" "$@"
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
# apt runs prefix-integrate itself, once after all its dpkg runs
# (apt-dpkg/config/apt.conf.d/02integrate.in), and says so with
# DPKG_FRONTEND_LOCKED; after any other run that can change packages or
# alternatives, it runs here.
integrate=
case $n in dpkg|update-alternatives) [ -n "${DPKG_FRONTEND_LOCKED:-}" ] || integrate=1 ;; esac
if [ -z "$integrate" ] || [ ! -x "$P/lib/sudo-less/prefix-integrate" ]; then
  PREFIX=$P PREFIX_VIEW_DEBS=$debs exec "$P/lib/sudo-less/prefix-view" "$real" "$@"
fi
rc=0
PREFIX=$P PREFIX_VIEW_DEBS=$debs "$P/lib/sudo-less/prefix-view" "$real" "$@" || rc=$?
PREFIX=$P "$P/lib/sudo-less/prefix-integrate" || :
exit $rc
