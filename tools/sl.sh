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
#   sl-status            the prefix, and a check of what sudo-less needs
#                        (exit 1 if something is wrong)
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
SL_ENV_APT_CONFIG=${APT_CONFIG:-}   # for sl-status: set by the caller's shell?
export APT_CONFIG=$P/etc/apt/apt.conf.d/00local-prefix
B=$P/lib/sudo-less/bin    # the prefix's apt and dpkg, off PATH
apt=$B/apt
dpkg=$B/dpkg

usage() { sed -n '6,21p' "$self" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# sl-status: facts about the prefix, then checks. A check says ok, warn
# (works, but worth knowing) or FAIL (something sudo-less needs is broken).
status() {
  local bad=0 mine held stamp f
  ok()   { printf '  ok    %s\n' "$*"; }
  warn() { printf '  warn  %s\n' "$*"; }
  fail() { printf '  FAIL  %s\n' "$*"; bad=1; }

  echo "prefix     $P"
  echo "apt        $("$apt" --version 2>/dev/null | head -1)"
  echo "dpkg       $("$B/dpkg-query" --version 2>/dev/null | sed -n '1s/.*version \([^ ]*\).*/\1/p')"
  mine=$("$B/dpkg-query" -W -f '${Status}\n' 2>/dev/null | grep -c '^install ok installed$' || :)
  held=$("$B/dpkg-query" -W -f '${Status}\n' 2>/dev/null | grep -c '^hold ok installed$' || :)
  echo "packages   $mine yours (sl-list), $held the system's (seeded, on hold)"
  echo "size       $(du -sh "$P/usr" 2>/dev/null | cut -f1) in usr/, $(du -sh "$P/var/cache/apt" 2>/dev/null | cut -f1) of downloads (sl-apt clean)"
  stamp=$(find "$P/var/lib/apt/lists" -maxdepth 1 -name '*Packages*' -printf '%TY-%Tm-%Td %TH:%TM\n' 2>/dev/null | sort | tail -1)
  echo "lists      ${stamp:-never} (sl-update)"
  echo

  echo "checks"
  for f in apt apt-get dpkg; do
    case $(command -v "$f" 2>/dev/null) in
      "$P"/*) fail "\`$f\` on PATH is the prefix's ($(command -v "$f")): reinstall the tools (tools/install.sh)" ;;
      '')     ok "\`$f\`: none on PATH" ;;
      *)      ok "\`$f\` is the system's ($(command -v "$f"))" ;;
    esac
  done
  case :$PATH: in
    *":$P/bin:"*":$P/usr/bin:"*|*":$P/usr/bin:"*":$P/bin:"*) ok "PATH has $P/bin and $P/usr/bin" ;;
    *) fail "PATH lacks $P/bin or $P/usr/bin: open a new login shell" ;;
  esac
  if [ -n "${SL_ENV_APT_CONFIG:-}" ]; then
    warn "APT_CONFIG is set in this shell, so the system's apt reads the prefix's config: open a new terminal"
  else
    ok "APT_CONFIG is not set in this shell"
  fi
  if unshare -Ur true 2>/dev/null; then ok "unprivileged user namespaces work"
  else fail "no unprivileged user namespaces: the admin runs admin/enable-userspace.sh once"
  fi
  if PREFIX=$P "$P/lib/sudo-less/prefix-view" --run true 2>/dev/null; then ok "the run view starts"
  else fail "the run view does not start (sl-shell true shows why)"
  fi
  if command -v sqv >/dev/null; then ok "sqv found: sl-update verifies signatures"
  else fail "no sqv: sl-update cannot verify signatures"
  fi
  f=$("$dpkg" --audit 2>&1 || :)
  if [ -z "$f" ]; then ok "no half-installed packages"
  else fail "half-installed packages (sl-dpkg --audit):"; printf '%s\n' "$f" | sed 's/^/          /'
  fi
  return $bad
}

n=${0##*/}
case $n in
  sl-install|sl-remove|sl-purge|sl-autoremove|sl-update|sl-upgrade|sl-search|sl-show)
    exec "$apt" "${n#sl-}" "$@" ;;
  sl-list)
    # Seeded packages (the system's, lock-seeded.sh) are on hold: yours are
    # the ones selected for install.
    "$B/dpkg-query" -W -f '${Status}\t${Package}\t${Version}\n' "$@" |
      awk -F '\t' '$1 == "install ok installed" { printf "%-32s %s\n", $2, $3 }' ;;
  sl-status) status ;;
  sl-shell)
    [ $# -gt 0 ] || set -- "${SHELL:-/bin/bash}"
    [ -n "${SUDO_LESS_VIEW:-}" ] || echo "sl-shell: in the run view; exit to leave" >&2
    PREFIX=$P exec "$P/lib/sudo-less/prefix-view" --run "$@" ;;
  sl-apt)  exec "$apt" "$@" ;;
  sl-dpkg) exec "$dpkg" "$@" ;;
  *) case ${1:-} in -h|--help|'') usage 0 ;; *) usage 2 ;; esac ;;
esac
