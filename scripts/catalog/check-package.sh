#!/usr/bin/env bash
# Predict whether a Debian package will work when installed into a userspace
# prefix (~/.local) by the ported apt/dpkg — WITHOUT installing it.
#
#   ./scripts/catalog/check-package.sh PKG [PKG...]
#   ./scripts/catalog/check-package.sh --meta PKG      # index metadata only (no download)
#   ./scripts/catalog/check-package.sh --runtime PKG   # also classify the runtime tier
#
# Method (cache-only, nothing is executed or installed):
#   * apt index metadata (Section/Priority/Essential/Depends) via apt-cache show
#   * the .deb, fetched into apt's archive cache and read offline with dpkg-deb:
#       - control scripts (preinst/postinst/prerm/postrm) -> root-only commands
#       - file list -> system-integration paths
#   Repeat runs reuse the cached .deb (no network).
#
# Verdicts:
#   OK        nothing that should stop it working in the prefix
#   RISKY     installs, but ships/uses system integration (may partly misbehave)
#   UNLIKELY  a hard blocker: root-only postinst step, python app, service deps
#
# --runtime adds a line per package saying how it must be run (see docs/paths.md
# and docs/standard.md's tier contract):
#   direct    relocatable: PATH (+ LD_LIBRARY_PATH) is enough
#   env       an interpreter's own default module search path misses $PREFIX
#             (perl's @INC, ruby's $LOAD_PATH, java's classpath) — set the
#             matching env var (see the `interp=` hint); no root, no namespace
#   overlay   binaries reference /etc or /usr/share|lib|libexec by absolute
#             path, or a script's shebang names an interpreter not on this
#             host (would only land under $PREFIX) — run it through
#             tools/prefix-run.sh (or a complete rootfs)
#   never     a hard blocker above; not runnable this way
#   unknown   no .deb available to scan (--meta, or download failed)
set -uo pipefail
source "$(dirname "$0")/../common.sh"
set +e  # common.sh enables errexit; this checker is deliberately lenient

META_ONLY=0
RUNTIME=0
while :; do
  case "${1:-}" in
    --meta)    META_ONLY=1; shift ;;
    --runtime) RUNTIME=1; shift ;;
    *)         break ;;
  esac
done
[ $# -gt 0 ] || { echo "usage: $0 [--meta] [--runtime] PKG..." >&2; exit 2; }

APT="$PREFIX/bin/apt-get"
APT_CACHE="$PREFIX/bin/apt-cache"
DPKG_DEB="$(command -v dpkg-deb || echo "$PREFIX/bin/dpkg-deb")"
ARCHIVES="$PREFIX/var/cache/apt/archives"

# --- signals -----------------------------------------------------------------
# HARD: a postinst/preinst step that needs root and will fail, with no fix
# this repo ships.
HARD_SCRIPT='systemctl|invoke-rc.d|update-rc.d|/etc/init.d|adduser|useradd|groupadd|debconf|ldconfig|chroot|dpkg-statoverride|update-ca-certificates|update-crypto-policies'
HARD_FILES='/etc/pam.d/|/usr/share/pam-configs/|/lib/modules/|/usr/lib/security/'
HARD_DEPS='init-system-helpers|adduser|debconf|initramfs-tools|sysvinit-core|passwd|login'

# SOFT: commonly non-fatal (Debian wraps these, or they only warn), system
# integration that doesn't stop the binaries running, or a blocker this repo
# already ships a fix for (py3compile: shims/py3compile + install-config.sh's
# .pth puts $PREFIX/usr/lib/python3/dist-packages on sys.path — see #5).
SOFT_SCRIPT='update-alternatives|update-menus|update-desktop-database|install-info|update-mime|update-mime-database|gtk-update-icon-cache|update-fonts|update-xmlcatalog|update-catalog|update-dictcommon|update-icon-caches|py3compile'
SOFT_FILES='/usr/lib/systemd/|/lib/systemd/|/etc/init.d/|/usr/libexec/|/usr/lib/udev/|/etc/dbus-1/|/usr/share/polkit-1/|/usr/lib/tmpfiles.d/|/etc/default/|/usr/share/dbus-1/|/etc/xdg/autostart/|/usr/lib/python3/dist-packages/|/usr/lib/python3/'

# apt-cache/apt-get download need the package index; populate it if missing.
if ! compgen -G "$PREFIX/var/lib/apt/lists/*_Packages*" >/dev/null; then
  log "no package lists; running apt-get update"
  "$APT" update
fi
mkdir -p "$ARCHIVES"

matches() { { grep -Eoi "$1" <<<"$2" 2>/dev/null || true; } | sort -u | paste -sd, -; }

check_one() {
  local pkg="$1" hard=() soft=() deb=""
  local meta section essential depends
  meta="$("$APT_CACHE" show "$pkg" 2>/dev/null)" || { echo "$pkg: NOT IN REPO"; return; }
  section="$(sed -n 's/^Section: //p' <<<"$meta" | head -1)"
  essential="$(sed -n 's/^Essential: //p' <<<"$meta" | head -1)"
  depends="$(sed -n 's/^\(Pre-\)\?Depends: //p' <<<"$meta" | paste -sd, -)"

  [[ "$essential" == yes ]] && hard+=("Essential package") || true
  local d; d="$(matches "$HARD_DEPS" "$depends")"
  if [ -n "$d" ]; then hard+=("deps: $d"); fi

  if [ "$META_ONLY" -eq 0 ]; then
    deb="$(ls "$ARCHIVES/${pkg}"_*.deb 2>/dev/null | head -1 || true)"
    if [ -z "$deb" ]; then
      ( cd "$ARCHIVES" && "$APT" download "$pkg" >/dev/null 2>&1 ) || true
      deb="$(ls "$ARCHIVES/${pkg}"_*.deb 2>/dev/null | head -1 || true)"
    fi
    if [ -n "$deb" ]; then
      local scripts files
      rm -rf "$WORK/ctrl"
      "$DPKG_DEB" -e "$deb" "$WORK/ctrl" >/dev/null 2>&1
      scripts="$(cat "$WORK"/ctrl/{preinst,postinst,prerm,postrm} 2>/dev/null || true)"
      files="$("$DPKG_DEB" -c "$deb" 2>/dev/null || true)"
      local s
      s="$(matches "$HARD_SCRIPT" "$scripts")"; if [ -n "$s" ]; then hard+=("script: $s"); fi
      s="$(matches "$SOFT_SCRIPT" "$scripts")"; if [ -n "$s" ]; then soft+=("script: $s"); fi
      s="$(matches "$HARD_FILES" "$files")";   if [ -n "$s" ]; then hard+=("paths: $s"); fi
      s="$(matches "$SOFT_FILES" "$files")";   if [ -n "$s" ]; then soft+=("paths: $s"); fi
    else
      soft+=("not downloadable")
    fi
  fi

  if [ "${#hard[@]}" -gt 0 ]; then
    printf '%-16s %-9s %s\n' "$pkg" "UNLIKELY" "${hard[*]}"
  elif [ "${#soft[@]}" -gt 0 ]; then
    printf '%-16s %-9s %s\n' "$pkg" "RISKY" "${soft[*]}"
  else
    printf '%-16s %-9s section=%s\n' "$pkg" "OK" "${section:-?}"
  fi

  if [ "$RUNTIME" -eq 1 ]; then
    local rt="" ev=""
    if [ "${#hard[@]}" -gt 0 ]; then
      rt="never"
    elif [ -z "$deb" ]; then
      rt="unknown"   # --meta, or the .deb could not be fetched
    else
      local blob="$WORK/blob"
      "$DPKG_DEB" --fsys-tarfile "$deb" 2>/dev/null \
        | tar -xO --wildcards './usr/bin/*' './usr/sbin/*' './usr/libexec/*' 2>/dev/null \
        | head -c 20000000 > "$blob" || true

      # Absolute /etc or /usr/share|lib|libexec paths compiled into binaries.
      ev="$(grep -aoE '/(usr/(share|lib|libexec)|etc)/[A-Za-z0-9._+-]+' "$blob" \
        | sort -u | head -20 || true)"

      # Shebangs pointing at an interpreter that doesn't exist on this host:
      # it would only land under $PREFIX, so the absolute shebang is dead
      # unless run through prefix-run's overlay (e.g. yard's #!/usr/bin/ruby
      # when ruby isn't seeded).
      local shebang missing=""
      while IFS= read -r shebang; do
        [ -n "$shebang" ] || continue
        [ -e "$shebang" ] || missing="$missing $shebang"
      done < <(grep -aoE '^#!/usr/(bin|local/bin)/[A-Za-z0-9_.+-]+' "$blob" | sed 's/^#!//' | sort -u)

      # Interpreter module-search-path signals: the package ships files under
      # a path the interpreter's own default search path won't see from
      # $PREFIX (perl's @INC, ruby's $LOAD_PATH, java's classpath) — same bug
      # class as python's PYTHONPATH gap, but invisible to a binary-content
      # scan since `use Foo::Bar;` never spells out the absolute path.
      local interp="" s
      s="$(matches '/usr/share/perl5/|/usr/lib/[^ ]*/perl5/' "$files")"
      [ -n "$s" ] && interp="perl:PERL5LIB"
      s="$(matches '/usr/lib/ruby/|/var/lib/gems/' "$files")"
      [ -n "$s" ] && interp="${interp:+$interp,}ruby:GEM_PATH+RUBYLIB"
      s="$(matches '/usr/share/java/' "$files")"
      [ -n "$s" ] && interp="${interp:+$interp,}java:CLASSPATH"

      if [ -n "$missing" ]; then
        rt="overlay"
        ev="shebang:${missing# } ${ev:+paths:$(tr '\n' ',' <<<"$ev" | sed 's/,$//')}"
      elif [ -n "$ev" ]; then
        rt="overlay"
        ev="paths:$(tr '\n' ',' <<<"$ev" | sed 's/,$//')"
      elif [ -n "$interp" ]; then
        rt="env"
        ev="interp=$interp"
      else
        rt="direct"
      fi
      ev="$(printf '%s' "$ev" | tr '\n' ' ' | sed 's/ *$//')"
    fi
    printf '%-16s runtime=%-8s %s\n' "$pkg" "$rt" "$ev"
  fi
}

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
for p in "$@"; do check_one "$p"; done
