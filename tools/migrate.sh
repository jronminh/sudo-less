#!/usr/bin/env bash
# tools/migrate.sh — move a sudo-less install from ~/.local, which it shared
# with other programs, to a prefix of its own, ~/.sudo-less.
#
#   tools/migrate.sh [plan]          what each step would do; changes nothing
#   tools/migrate.sh install         set up the new prefix and install your
#                                    packages in it: services enabled, not
#                                    started; the old install keeps working
#   tools/migrate.sh carry           stop the services, carry over what
#                                    installing again cannot make (config
#                                    files you changed, the services' state,
#                                    alternatives you chose), start them
#   tools/migrate.sh clean-old       list what is sudo-less's in the old
#   tools/migrate.sh clean-old --yes prefix, then remove it
#
# FROM (default ~/.local) and TO (default ~/.sudo-less) choose the two
# prefixes; NO_SHELL=1 leaves ~/.bashrc, ~/.profile and the session alone
# (a test), and PKGS="A B" installs only those. Packages are installed
# again from the archive, not copied: the old prefix has files no package
# owns (#39), and copies would keep paths to it. apt and dpkg themselves are copied from the old prefix, so nothing
# is downloaded or built for them.
set -euo pipefail
source "$(dirname "$0")/../scripts/common.sh"

FROM=$(readlink -m "${FROM:-$HOME/.local}")
TO=$(readlink -m "${TO:-$HOME/.sudo-less}")
[ "$FROM" != "$TO" ] || die "FROM and TO are the same: $FROM"
STEP=${1:-plan}; shift || :

# The old prefix's apt and dpkg: in .sl (since 2026-10), in lib/sudo-less/bin
# (8bd1569), or in bin before.
FA= FD=
for d in "$FROM/.sl/apt/bin:$FROM/.sl/dpkg/bin" "$FROM/lib/sudo-less/bin:$FROM/lib/sudo-less/bin" \
         "$FROM/bin:$FROM/bin"; do
  [ -x "${d%%:*}/apt-get" ] || continue
  FA=${d%%:*} FD=${d#*:}; break
done
[ -n "$FA" ] || die "no sudo-less apt in $FROM (FROM=...)"
from_apt() { local c=$1; shift; APT_CONFIG=$FROM/etc/apt/apt.conf.d/00local-prefix "$FA/$c" "$@"; }
from_q() { "$FD/dpkg-query" --admindir="$FROM/var/lib/dpkg" "$@"; }
TD=$TO/.sl/dpkg/bin

# The packages you installed (not on hold) and chose (apt's manual mark):
# their dependencies come with them.
mine() {
  comm -12 \
    <(from_q -W -f '${Status}\t${binary:Package}\n' | awk -F '\t' '$1 == "install ok installed" { print $2 }' | sed 's/:'"$DEB_ARCH"'$//' | sort -u) \
    <(from_apt apt-mark showmanual 2>/dev/null | sed 's/:'"$DEB_ARCH"'$//' | sort -u)
}

# The packages to install again: PKGS if given, else all of yours.
wanted() { if [ -n "${PKGS:-}" ]; then printf '%s\n' $PKGS; else mine; fi; }

# Config files you changed: "PKG PATH" for each conffile of a package to
# install again whose file differs from what the package shipped.
changed_conffiles() ( set +e +o pipefail
  local pkg path sum rest
  for pkg in $(wanted); do
    from_q -W -f '${Conffiles}\n' "$pkg" 2>/dev/null |
      while read -r path sum rest; do
        [ -n "$path" ] && [ -f "$FROM$path" ] || continue
        case $rest in *obsolete*) continue ;; esac
        [ "$(md5sum < "$FROM$path" | cut -d' ' -f1)" = "$sum" ] || echo "$pkg $path"
      done
  done
)

# The state directories of the services (StateDirectory= in their units),
# that the old prefix has. The units are the old prefix's, the new one's
# (once `install` has made them), or ones an earlier version wrote in place.
state_dirs() ( set +e +o pipefail
  local d
  for d in "$FROM"/.sudo-less/units/* "$FROM"/.sl/state/units/* "$TO"/.sl/state/units/* \
           "${XDG_DATA_HOME:-$HOME/.local/share}"/systemd/user/*; do
    [ -f "$d" ] || continue
    grep -qF '# sudo-less user unit' "$d" 2>/dev/null || continue
    sed -n 's/^# sudo-less sandbox: StateDirectory=//p' "$d"
  done | tr ' ' '\n' | sed 's/:.*//' | grep . | sort -u |
    while read -r d; do [ ! -d "$FROM/var/lib/$d" ] || echo "$d"; done
)

# Alternatives you set by hand: "NAME VALUE".
manual_alternatives() ( set +e +o pipefail
  local f
  for f in "$FROM"/var/lib/dpkg/alternatives/*; do
    [ -f "$f" ] && [ "$(head -1 "$f")" = manual ] || continue
    echo "${f##*/} $(PREFIX=$FROM "$FD/update-alternatives" --query "${f##*/}" 2>/dev/null | sed -n 's/^Value: //p')"
  done
)

# What of the old prefix is sudo-less's, one path per line. Everything else
# in it (your own programs, pip's, Flatpak's, what you extracted to opt/
# yourself) stays.
old_files() ( set +e +o pipefail
  local f
  for f in usr etc var .sl .sudo-less lib/sudo-less lib/apt lib/dpkg lib/libdpkg.a \
           lib/libdpkg.la lib/pkgconfig/apt-pkg.pc lib/pkgconfig/libdpkg.pc \
           include/apt-pkg include/dpkg libexec/dpkg share/dpkg share/sudo-less \
           share/perl5/Dpkg share/perl5/Dpkg.pm share/doc/dpkg \
           share/polkit-1/actions/org.dpkg.pkexec.update-alternatives.policy \
           share/zsh/vendor-completions/_dpkg-parsechangelog; do
    [ -e "$FROM/$f" ] && echo "$FROM/$f"
  done
  for f in "$FROM"/lib/libapt-pkg.so* "$FROM"/lib/libapt-private.so* "$FROM"/share/aclocal/dpkg-*.m4 \
           "$FROM"/share/bash-completion/completions/{apt,dpkg,dpkg-deb,dpkg-query,dpkg-source}; do
    [ -e "$f" ] || [ -L "$f" ] && echo "$f"
  done
  [ ! -d "$FROM/share/man" ] || find "$FROM/share/man" -type f \( -name 'dpkg*' -o -name 'deb-*' \
    -o -name 'deb.5*' -o -name 'deb822.5*' -o -name 'dsc.5*' -o -name 'Dpkg*' -o -name 'libdpkg*' \
    -o -name 'update-alternatives*' -o -name 'start-stop-daemon*' \)
  [ ! -d "$FROM/share/locale" ] || find "$FROM/share/locale" -type f \( -name dpkg.mo -o -name dpkg-dev.mo \)
  # bin, sbin: the sl-* commands, the launchers, apt's and dpkg's programs
  for f in "$FROM"/bin/* "$FROM"/sbin/*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    case ${f##*/} in
      sl-*|apt|apt-*|dpkg|dpkg-*|update-alternatives|start-stop-daemon) echo "$f" ;;
      # a launcher, or the py3compile shim of an earlier version
      *) ! grep -qs -e 'sudo-less view wrapper' -e '^# py3compile shim' "$f" || echo "$f" ;;
    esac
  done
  # opt: the files the old prefix's packages put there (not whole folders:
  # what you extracted there yourself stays)
  from_q -W -f '${Status}\t${binary:Package}\n' 2>/dev/null |
    awk -F '\t' '$1 == "install ok installed" { print $2 }' |
    while read -r f; do from_q -L "$f" 2>/dev/null; done |
    grep '^/opt/' | while read -r f; do [ -f "$FROM$f" ] || [ -L "$FROM$f" ] && echo "$FROM$f"; done
  # units an earlier sudo-less wrote in place (not yet links to $TO), and
  # links into the old prefix
  for f in "${XDG_DATA_HOME:-$HOME/.local/share}"/systemd/user/*; do
    [ -f "$f" ] && [ ! -L "$f" ] && grep -qF '# sudo-less user unit' "$f" 2>/dev/null && echo "$f"
  done
  for f in "${XDG_CONFIG_HOME:-$HOME/.config}"/environment.d "${XDG_CONFIG_HOME:-$HOME/.config}"/systemd/user \
           "${XDG_DATA_HOME:-$HOME/.local/share}"/systemd/user; do
    [ -d "$f" ] && find "$f" -maxdepth 2 -type l
  done | while read -r f; do
    # into what goes above: not just anything in $FROM, which has your own
    # units too (share/systemd/user)
    t=$(readlink -m "$f")
    case $t in
      "$FROM"/usr/*|"$FROM"/etc/*|"$FROM"/var/*|"$FROM"/lib/sudo-less/*|"$FROM"/.sudo-less/*|"$FROM"/.sl/*) echo "$f" ;;
      "$FROM"/*) ! grep -qsF '# sudo-less user unit' "$t" || echo "$f" ;;
    esac
  done
  return 0
)

case $STEP in
plan)
  echo "from  $FROM"
  echo "to    $TO$([ ! -x "$TO/.sl/bin/sl-status" ] || echo ' (already set up)')"
  echo
  echo "install: copy apt and dpkg from $FROM, set up $TO (the host's suite), and install again:"
  wanted | tr '\n' ' ' | fold -s -w 76 | sed 's/^/  /'; echo
  echo
  echo "carry: config files you changed:"
  changed_conffiles | sed 's/^/  /'
  echo "carry: the services' state (var/lib):"
  state_dirs | sed 's/^/  /'
  echo "carry: alternatives you chose:"
  manual_alternatives | sed 's/^/  /'
  echo
  echo "clean-old: $(old_files | wc -l) paths of sudo-less's in $FROM (tools/migrate.sh clean-old lists them)"
  ;;

install)
  mkdir -p "$TO"
  # apt and dpkg: the programs, the real dpkg behind its wrappers, apt's
  # libraries and methods, dpkg's data. Copied as the old prefix has them;
  # tools/install.sh (from install-config.sh) moves them into .sl.
  if [ -d "$FROM/.sl/apt" ]; then
    mkdir -p "$TO/.sl"; cp -a "$FROM/.sl/apt" "$FROM/.sl/dpkg" "$TO/.sl/"
  else
  for d in bin sbin lib/sudo-less/bin; do
    [ -d "$FROM/$d" ] || continue
    for f in "$FROM/$d"/*; do
      [ -f "$f" ] && [ ! -L "$f" ] || continue
      case ${f##*/} in apt|apt-*|dpkg|dpkg-*|update-alternatives|start-stop-daemon) ;; *) continue ;; esac
      mkdir -p "$TO/$d"; cp -a "$f" "$TO/$d/"
    done
  done
  mkdir -p "$TO/lib/sudo-less" "$TO/share"
  cp -a "$FROM/lib/sudo-less/dpkg" "$TO/lib/sudo-less/"
  cp -a "$FROM/lib/apt" "$FROM"/lib/libapt-pkg.so* "$FROM"/lib/libapt-private.so* "$TO/lib/"
  [ ! -d "$FROM/share/dpkg" ] || cp -a "$FROM/share/dpkg" "$TO/share/"
  fi
  log "copied apt and dpkg from $FROM"

  PREFIX=$TO bash "$REPO/scripts/setup/install-config.sh" ${NO_SHELL:+--no-shell}
  # dpkg's foreign architectures. Not the apt sources: the new prefix
  # follows the host's suite (apt-dpkg/install.sh), and old sources of a
  # newer suite (the sid of earlier versions) would bring packages the
  # host's libraries are too old for. They are listed, to add back by hand.
  [ ! -f "$FROM/var/lib/dpkg/arch" ] || cp -a "$FROM/var/lib/dpkg/arch" "$TO/var/lib/dpkg/"
  for f in "$FROM/etc/apt/sources.list" "$FROM"/etc/apt/sources.list.d/*; do
    [ -f "$f" ] || continue
    grep -v '^[[:space:]]*\(#\|$\)' "$f" | sed "s|^|  old source (${f#"$FROM"/}): |"
  done

  # The .debs the old prefix downloaded: apt takes those of the same
  # version from its cache instead of downloading them again (hard links
  # when both prefixes are on one file system, so no space either).
  mkdir -p "$TO/var/cache/apt/archives"
  for f in "$FROM"/var/cache/apt/archives/*.deb; do
    [ -f "$f" ] || continue
    ln -f "$f" "$TO/var/cache/apt/archives/" 2>/dev/null || cp -a "$f" "$TO/var/cache/apt/archives/"
  done

  "$TO/.sl/bin/sl-update"
  pkgs=$(wanted | tr '\n' ' ')
  log "installing: $pkgs"
  # Services are enabled, and started by `carry`, once their state is here.
  export SUDO_LESS_UNITS=nostart
  # shellcheck disable=SC2086
  if ! "$TO/.sl/bin/sl-install" -y $pkgs; then
    log "together they failed; one at a time:"
    failed=
    for p in $pkgs; do "$TO/.sl/bin/sl-install" -y "$p" || failed="$failed $p"; done
    [ -z "$failed" ] || log "not installed:$failed (sl-status, and: sl-install PKG to see why)"
  fi
  # The old .debs linked in above, and what was downloaded: not kept.
  "$TO/.sl/bin/sl-apt" clean
  log "next: tools/migrate.sh carry"
  log "until clean-old, ~/.local/bin (first on PATH) still runs the old install's sl-* and programs"
  ;;

carry)
  [ -x "$TO/.sl/bin/sl-status" ] || die "$TO is not set up: tools/migrate.sh install"
  units=$(ls "$TO/.sl/state/db/units-enabled" 2>/dev/null | tr '\n' ' ')
  usermgr=
  systemctl --user show-environment >/dev/null 2>&1 && usermgr=1
  if [ -n "$units" ] && [ -n "$usermgr" ]; then
    log "stopping: $units"
    # shellcheck disable=SC2086
    systemctl --user stop $units || :
  fi
  changed_conffiles | while read -r pkg path; do
    # only for what the new prefix has (install may have left one out)
    "$TD/dpkg-query" -W -f '${Status}' "$pkg" 2>/dev/null | grep -q ' installed$' || continue
    ! cmp -s "$FROM$path" "$TO$path" || continue    # carried already
    [ ! -e "$TO$path" ] || cp -a "$TO$path" "$TO$path.dpkg-dist"
    mkdir -p "$(dirname "$TO$path")"
    cp -a "$FROM$path" "$TO$path"
    log "config $path ($pkg): yours; the package's is $path.dpkg-dist"
  done
  state_dirs | while read -r d; do
    mkdir -p "$TO/var/lib/$d"
    cp -a "$FROM/var/lib/$d/." "$TO/var/lib/$d/"
    log "state /var/lib/$d"
  done
  manual_alternatives | while read -r name value; do
    [ -n "$value" ] || continue
    "$TD/update-alternatives" --set "$name" "$value" && log "alternative $name: $value"
  done
  if [ -n "$units" ] && [ -n "$usermgr" ]; then
    systemctl --user daemon-reload
    log "starting: $units"
    # shellcheck disable=SC2086
    systemctl --user start $units || log "a service did not start: systemctl --user status UNIT"
  fi
  log "next: check with sl-status, then tools/migrate.sh clean-old"
  ;;

clean-old)
  [ -x "$TO/.sl/bin/sl-status" ] || die "$TO is not set up: this would leave you without sudo-less"
  list=$(old_files)
  if [ "${1:-}" != --yes ]; then
    printf '%s\n' "$list"
    echo
    echo "$(printf '%s\n' "$list" | grep -c .) paths; tools/migrate.sh clean-old --yes removes them"
    exit 0
  fi
  for f in "$FROM/.sl/lib/prefix-view" "$FROM/lib/sudo-less/prefix-view"; do
    [ ! -x "$f" ] || PREFIX=$FROM "$f" --stop 2>/dev/null || :
  done
  # The old prefix's services that are not the new one's: stop them before
  # their units go.
  if systemctl --user show-environment >/dev/null 2>&1; then
    printf '%s\n' "$list" | while IFS= read -r f; do
      case $f in *.service|*.socket|*.timer|*.path) ;; *) continue ;; esac
      [ -f "$f" ] && [ ! -L "$f" ] && grep -qF '# sudo-less user unit' "$f" 2>/dev/null || continue
      systemctl --user disable --now "${f##*/}" 2>/dev/null && log "stopped ${f##*/}" || :
    done
  fi
  printf '%s\n' "$list" | while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ ! -d "$f" ] || [ -L "$f" ] || chmod -R u+w "$f" 2>/dev/null || :
    rm -rf -- "$f"
  done
  # Folders the packages' files in opt/ leave empty.
  [ ! -d "$FROM/opt" ] || find "$FROM/opt" -mindepth 1 -type d -empty -delete 2>/dev/null || :
  systemctl --user daemon-reload 2>/dev/null || :
  log "removed $(printf '%s\n' "$list" | grep -c .) paths from $FROM"
  ;;

*) sed -n '4,14p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
