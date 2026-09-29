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
#   sl-uninstall [--yes] remove sudo-less: say what goes, and with --yes
#                        remove it (the prefix, the links into it, the
#                        PATH block), your settings in config/ with it
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

usage() { sed -n '6,24p' "$self" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

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
  case :$PATH: in *":$P/bin:"*) f=1 ;; *) f= ;; esac
  case :$PATH: in *":$P/usr/bin:"*) ;; *) f= ;; esac
  if [ -n "$f" ]; then ok "PATH has $P/bin and $P/usr/bin"
  else fail "PATH lacks $P/bin or $P/usr/bin: open a new login shell"
  fi
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
  if [ "$P" != "$HOME/.local" ] && [ -x "$HOME/.local/lib/sudo-less/prefix-view" ]; then
    warn "an older sudo-less is still in ~/.local, and its programs come first on PATH: tools/migrate.sh"
  fi
  f=$(outside_links | while IFS= read -r l; do [ -e "$l" ] || echo "$l"; done)
  if [ -z "$f" ]; then ok "$(outside_links | wc -l) links into the prefix (units, session), none broken"
  else warn "links into the prefix that lead nowhere (a unit or file gone):"; printf '%s\n' "$f" | sed 's/^/          /'
  fi
  f=$("$dpkg" --audit 2>&1 || :)
  if [ -z "$f" ]; then ok "no half-installed packages"
  else fail "half-installed packages (sl-dpkg --audit):"; printf '%s\n' "$f" | sed 's/^/          /'
  fi
  return $bad
}

# The links outside the prefix that point into it, one per line: the
# session's (environment.d, the run view's unit), ~/.config/sudo-less (your
# settings) and the services' units (prefix-units, and the links
# `systemctl --user enable` made to them).
CONF=${XDG_CONFIG_HOME:-$HOME/.config}
LINKDIRS="$CONF/environment.d $CONF/systemd/user ${XDG_DATA_HOME:-$HOME/.local/share}/systemd/user"
outside_links() {
  local d l
  {
    [ ! -L "$CONF/sudo-less" ] || echo "$CONF/sudo-less"
    for d in $LINKDIRS; do
      [ -d "$d" ] || continue
      find "$d" -maxdepth 2 -type l -print 2>/dev/null
    done
  } | while IFS= read -r l; do
    case $(readlink -m -- "$l") in "$P"/*) printf '%s\n' "$l" ;; esac
  done
}

# The PATH block install-shell-path.sh wrote.
MARK='# >>> sudo-less PATH >>>' END='# <<< sudo-less PATH <<<'
rc_files() { grep -lxF "$MARK" "$HOME/.bashrc" "$HOME/.profile" 2>/dev/null || :; }

uninstall() {
  local yes= l u rc links
  [ "${1:-}" != --yes ] || yes=1
  if [ "$P" = "$HOME/.local" ]; then
    echo "sl-uninstall: $P is shared with other programs; it cannot go as a whole." >&2
    echo "  Move to ~/.sudo-less first (tools/migrate.sh), which also cleans $P." >&2
    exit 1
  fi
  if [ -n "$yes" ]; then echo "sudo-less in $P: removing"
  else echo "sudo-less in $P: what sl-uninstall --yes removes"; fi
  echo "  the prefix       $P ($(du -sh "$P" 2>/dev/null | cut -f1))"
  outside_links | sed 's/^/  link             /'
  rc_files | sed 's/^/  PATH block in    /'
  [ -z "$(ls -A "$P/config" 2>/dev/null)" ] ||
    echo "  your settings in $P/config (copy them first to keep them)"
  [ -n "$yes" ] || exit 0

  # Listed now: one link can point to another (the enable link to the run
  # view's), so once the first is gone the second no longer leads here.
  links=$(outside_links)
  # Stop the services first, while their units are still there.
  if systemctl --user show-environment >/dev/null 2>&1; then
    for l in "${XDG_DATA_HOME:-$HOME/.local/share}"/systemd/user/* "$CONF"/systemd/user/*; do
      [ -L "$l" ] || continue
      case $(readlink -m -- "$l") in "$P"/*) ;; *) continue ;; esac
      u=${l##*/}
      systemctl --user disable --now "$u" 2>/dev/null || :
    done
  fi
  PREFIX=$P "$P/lib/sudo-less/prefix-view" --stop 2>/dev/null || :
  printf '%s\n' "$links" | while IFS= read -r l; do [ -z "$l" ] || rm -f -- "$l"; done
  for rc in $(rc_files); do
    # the block, and the blank line install-shell-path.sh put before it
    awk -v m="$MARK" -v e="$END" '
      skip { if ($0 == e) skip = 0; next }
      $0 == m { skip = 1; blanks = 0; next }
      /^$/ { blanks++; next }
      { for (; blanks > 0; blanks--) print ""; print }
      END { for (; blanks > 0; blanks--) print "" }' "$rc" > "$rc.sl-uninstall.tmp"
    cat "$rc.sl-uninstall.tmp" > "$rc"    # keep the file's inode and mode
    rm -f "$rc.sl-uninstall.tmp"
  done
  # Files dpkg made read-only, and directories without write permission.
  chmod -R u+w "$P" 2>/dev/null || :
  rm -rf -- "$P"
  systemctl --user daemon-reload 2>/dev/null || :
  echo "removed. Open a new terminal (and log in again for the desktop)."
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
  sl-uninstall) uninstall "$@" ;;
  sl-shell)
    [ $# -gt 0 ] || set -- "${SHELL:-/bin/bash}"
    [ -n "${SUDO_LESS_VIEW:-}" ] || echo "sl-shell: in the run view; exit to leave" >&2
    PREFIX=$P exec "$P/lib/sudo-less/prefix-view" --run "$@" ;;
  sl-apt)  exec "$apt" "$@" ;;
  sl-dpkg) exec "$dpkg" "$@" ;;
  *) case ${1:-} in -h|--help|'') usage 0 ;; *) usage 2 ;; esac ;;
esac
