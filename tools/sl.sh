#!/usr/bin/env bash
# The sl-* commands: sudo-less's package commands, named so they cannot be
# mistaken for the system's apt and dpkg. tools/install.sh installs this one
# file as $PREFIX/bin/sl-install, sl-remove, ... and it reads what to do from
# the name it was run by.
#
#   sl-install PKG...    install into the prefix       (apt install)
#   sl-remove PKG...     remove, keep its config       (apt remove)
#   sl-purge PKG...      remove with its config        (apt purge)
#   sl-autoremove        remove unneeded dependencies  (apt autoremove)
#   sl-update            refresh the package lists     (apt update)
#   sl-upgrade           upgrade what you installed    (apt upgrade)
#   sl-search WORD...    search the package lists      (apt search)
#   sl-show PKG...       show a package                (apt show)
#   sl-list              the packages you installed (not the system's)
#   sl-shell [CMD...]    a shell (or CMD) in the run view, where /usr and
#                        /etc show the prefix's files over the host's
#   sl-apt ARG...        the prefix's apt, as is
#   sl-dpkg ARG...       the prefix's dpkg, as is
#
# Each one points apt at the prefix's own config (APT_CONFIG) for its own
# run only. docs/design.md.
set -eu

self=$(readlink -f "$0")
P=${self%/bin/*}
export APT_CONFIG=$P/etc/apt/apt.conf.d/00local-prefix
apt=$P/bin/apt
dpkg=$P/bin/dpkg

usage() { sed -n '6,19p' "$self" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

n=${0##*/}
case $n in
  sl-install|sl-remove|sl-purge|sl-autoremove|sl-update|sl-upgrade|sl-search|sl-show)
    exec "$apt" "${n#sl-}" "$@" ;;
  sl-list)
    # Seeded packages (the system's, lock-seeded.sh) are on hold: yours are
    # the ones selected for install.
    "$P/bin/dpkg-query" -W -f '${Status}\t${Package}\t${Version}\n' "$@" |
      awk -F '\t' '$1 == "install ok installed" { printf "%-32s %s\n", $2, $3 }' ;;
  sl-shell)
    [ $# -gt 0 ] || set -- "${SHELL:-/bin/bash}"
    [ -n "${SUDO_LESS_VIEW:-}" ] || echo "sl-shell: in the run view; exit to leave" >&2
    PREFIX=$P exec "$P/lib/sudo-less/prefix-view" --run "$@" ;;
  sl-apt)  exec "$apt" "$@" ;;
  sl-dpkg) exec "$dpkg" "$@" ;;
  *) case ${1:-} in -h|--help|'') usage 0 ;; *) usage 2 ;; esac ;;
esac
