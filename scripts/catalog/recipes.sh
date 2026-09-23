#!/usr/bin/env bash
# recipes.sh — list, show and verify sudo-less package recipes.
#
#   scripts/catalog/recipes.sh list
#   scripts/catalog/recipes.sh show PKG
#   scripts/catalog/recipes.sh verify [PKG...]     # default: every recipe
#
# A recipe is a plain-text key/value file under recipes/; the schema and the
# tier contract are in docs/standard.md.
set -euo pipefail
source "$(dirname "$0")/../common.sh"

RECIPES="${RECIPES:-$REPO/recipes}"

have() { command -v "$1" >/dev/null 2>&1; }

# A session to pass through: DISPLAY with its X11 socket, or WAYLAND_DISPLAY
# with its socket under $XDG_RUNTIME_DIR. Mirrors tools/prefix-run.sh's own
# check — kept as a small duplicate rather than a shared dependency, same as
# have() above.
session_ok() {
  if [ -n "${DISPLAY:-}" ] && [ -S "/tmp/.X11-unix/X${DISPLAY#:}" ]; then
    return 0
  fi
  if [ -n "${WAYLAND_DISPLAY:-}" ] && [ -n "${XDG_RUNTIME_DIR:-}" ] \
     && [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]; then
    return 0
  fi
  return 1
}

# field FILE KEY — print every value for KEY (one per line)
field() { sed -n "s/^$2[[:space:]]\{1,\}//p" "$1"; }

all_recipes() { find "$RECIPES" -maxdepth 1 -name '*.recipe' | sort; }

recipe_file() { # PKG
  local f="$RECIPES/$1.recipe"
  [ -f "$f" ] || die "no recipe for '$1' (try: recipes.sh list)"
  printf '%s' "$f"
}

tier_ok() { # TIER -> 0 ok, 1 missing prerequisites, 2 never
  case "$1" in
    direct|env) return 0 ;;
    overlay)    have bwrap || "$REPO/tools/prefix-run.sh" --mode overlay-native --print true >/dev/null 2>&1 ;;
    gui)        have bwrap && session_ok ;;
    never)      return 2 ;;
    *)          return 1 ;;
  esac
}

list_recipes() {
  [ -d "$RECIPES" ] || die "no recipes directory: $RECIPES"
  local f pkg inst tier
  for f in $(all_recipes); do
    pkg="$(field "$f" package)"; inst="$(field "$f" install)"; tier="$(field "$f" tier)"
    printf '%-16s %-9s tier=%s\n' "${pkg:-?}" "${inst:-?}" "${tier:-?}"
  done
}

verify_one() { # PKG -> 0 pass, 1 fail, 2 skip
  local pkg="$1" f tier line sh vcmd tok=0
  f="$(recipe_file "$pkg")"
  tier="$(field "$f" tier)"

  tier_ok "$tier" || tok=$?
  if [ "$tok" -eq 2 ]; then
    printf '%-16s FAIL  tier=never: %s\n' "$pkg" "$(field "$f" note | head -1)"
    return 1
  elif [ "$tok" -ne 0 ]; then
    printf '%-16s SKIP  tier=%s prerequisites missing\n' "$pkg" "$tier"
    return 2
  fi

  local missing=""
  while read -r sh; do
    [ -n "$sh" ] || continue
    [ -e "$PREFIX/bin/$sh" ] || missing="$missing $sh"
  done < <(field "$f" shim)
  if [ -n "$missing" ]; then
    printf '%-16s FAIL  missing shim(s):%s\n' "$pkg" "$missing"
    return 1
  fi

  while read -r line; do
    [ -n "$line" ] || continue
    export "${line//\$PREFIX/$PREFIX}"
  done < <(field "$f" env)

  vcmd="$(field "$f" verify | head -1)"
  if [ -z "$vcmd" ]; then
    printf '%-16s PASS  (no verify command)\n' "$pkg"
    return 0
  fi

  # tier=direct claims PATH alone is enough — a real risk on a desktop
  # where the same tool is already seeded/on the system: verify would then
  # silently pass via the *system* copy on PATH, never the prefix's own,
  # and the claim goes unproven (this is exactly how jq.recipe's tier was
  # wrong for a whole release — the fix was LD_LIBRARY_PATH, tier env).
  # Catch it: for a bare command name (no $VAR, no explicit path), confirm
  # it resolves under $PREFIX before trusting the verify result.
  if [ "$tier" = direct ]; then
    local cmd="${vcmd%% *}"
    case "$cmd" in
      */*|'$'*) ;; # explicit path or $VAR-prefixed: trust it, resolves itself
      *)
        local resolved; resolved="$(command -v "$cmd" 2>/dev/null || true)"
        case "$resolved" in
          "$PREFIX"/*) ;; # genuinely the prefix's own copy
          *)
            printf '%-16s FAIL  tier=direct but "%s" resolves to %s, not under %s (seeded/system fallback, not actually relocated — see docs/standard.md)\n' \
              "$pkg" "$cmd" "${resolved:-<not found>}" "$PREFIX"
            return 1
            ;;
        esac
        ;;
    esac
  fi

  if bash -c "$vcmd" >/dev/null 2>&1; then
    printf '%-16s PASS  %s\n' "$pkg" "$vcmd"
    return 0
  fi
  printf '%-16s FAIL  %s\n' "$pkg" "$vcmd"
  return 1
}

usage() {
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

[ $# -gt 0 ] || usage 2
cmd="$1"; shift

case "$cmd" in
  list)
    list_recipes
    ;;
  show)
    [ $# -eq 1 ] || die "usage: recipes.sh show PKG"
    cat "$(recipe_file "$1")"
    ;;
  verify)
    pkgs=()
    if [ $# -gt 0 ]; then
      pkgs=("$@")
    else
      [ -d "$RECIPES" ] || die "no recipes directory: $RECIPES"
      while IFS= read -r f; do
        pkgs+=("$(basename "${f%.recipe}")")
      done < <(all_recipes)
    fi
    [ "${#pkgs[@]}" -gt 0 ] || die "no recipes found in $RECIPES"
    fails=0
    for p in "${pkgs[@]}"; do
      verify_one "$p" || fails=$((fails + 1))
    done
    [ "$fails" -eq 0 ] || { echo "recipes: $fails failed" >&2; exit 1; }
    ;;
  -h|--help)
    usage 0
    ;;
  *)
    die "unknown command: $cmd (list|show|verify)"
    ;;
esac
