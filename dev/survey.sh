#!/usr/bin/env bash
# survey.sh — install and run a list of Debian packages, each in a fresh copy
# of a configured prefix, and record where each one fails: while installing
# or while running, and why. docs/survey-2026-09.md and docs/survey-2026-09b.md
# are its results.
#
#   BASE=~/fresh/.local OUT=~/survey dev/survey.sh LIST.tsv
#   OUT=~/survey dev/survey.sh --reclassify   redo the install column from
#                                             the logs (after changing
#                                             install_failure)
#
# LIST.tsv: "section<TAB>package" lines (a header line starting with
# "section" is skipped). BASE is a prefix set up by bootstrap.sh (or
# apt-dpkg/install.sh) with `apt-get update` done; it is copied for every
# package, so one broken package cannot affect the next, and never written
# to. The apt lists are read from BASE and the .deb files kept in
# OUT/archives, shared between packages.
#
# OUT/results.tsv gets one line per package:
#   section package install detail run programs
# install: ok, skew (apt cannot satisfy the dependencies with the host's
#   packages), script (a maintainer script failed), unpack, network, gone
#   (not in the archive), other
# run: none (no program on PATH), ok, partial, fail, untested (every program
#   needs a display or a terminal, or hangs)
# programs: NAME:HOW:RESULT,... where HOW is view (a prefix-wrap script) or
#   direct, and RESULT is ok, fail, miss (failed directly but works in the
#   run view: prefix-wrap missed it), gui, tty or hang.
# OUT/logs/PKG.log keeps the apt output and each program's output.
set -uo pipefail

LIST=${1:?usage: BASE=PREFIX OUT=DIR $0 LIST.tsv}
: "${OUT:?OUT: a directory for results}"
if [ "$LIST" != --reclassify ]; then
  : "${BASE:?BASE: a configured prefix}"
  BASE=$(realpath "$BASE")
fi
mkdir -p "$OUT/logs" "$OUT/archives/partial"
OUT=$(realpath "$OUT")
W=$OUT/work
RES=$OUT/results.tsv
[ -s "$RES" ] || printf 'section\tpackage\tinstall\tdetail\trun\tprograms\n' > "$RES"
MAXPROG=${MAXPROG:-6}

clean_work() {
  if [ -d "$W" ]; then
    [ ! -x "$W/pfx/lib/sudo-less/prefix-view" ] ||
      PREFIX=$W/pfx "$W/pfx/lib/sudo-less/prefix-view" --stop 2>/dev/null
    chmod -R u+rwx "$W" 2>/dev/null
    rm -rf "$W"
  fi
}

# A fresh prefix at $W/pfx: BASE without its apt lists and cache, with the
# configuration pointing at the copy.
fresh_prefix() {
  clean_work
  mkdir -p "$W/pfx" "$W/home"
  tar -C "$BASE" --exclude=./var/lib/apt/lists --exclude=./var/cache/apt \
      --exclude=./.sudo-less/view/work -cf - . | tar -C "$W/pfx" -xf -
  mkdir -p "$W/pfx/var/lib/apt/lists" "$W/pfx/var/cache/apt"
  grep -rlF -- "$BASE" "$W/pfx/etc" "$W/pfx/share/sudo-less" 2>/dev/null |
    xargs -r sed -i "s|$BASE|$W/pfx|g"
}

# Why apt-get install failed, from its output in $1.
install_failure() {
  local log=$1 l
  if grep -q 'Unable to locate package\|has no installation candidate' "$log"; then
    echo "gone"
  elif grep -q 'Failed to fetch\|Temporary failure resolving\|Connection timed out' "$log"; then
    echo "network $(grep -m1 -o 'Failed to fetch [^ ]*' "$log")"
  elif grep -qi 'held broken packages\|unmet dependencies\|Unable to correct problems\|Unable to satisfy dependencies' "$log"; then
    # apt 3's solver names the two versions it could not reconcile.
    l=$(grep -m1 -A1 'is not selected for install because' "$log" |
      sed 's/^ *//; s/^[0-9]*\. //' | paste -sd' ')
    [ -n "$l" ] || l=$(grep -m1 -E 'Depends: .*(but|is not)' "$log" | sed 's/^ *//')
    echo "skew ${l:-$(grep -m1 'Unable to correct\|Unmet' "$log")}"
  elif grep -qE 'script subprocess (returned error|failed)|subprocess .* returned error exit status' "$log"; then
    l=$(grep -m1 -E '(script|subprocess) .*(returned error|failed with exit)' "$log" -B6 |
      grep -v '^dpkg: error processing\|^Setting up\|^Preparing\|^Unpacking' |
      tr '\n' ' ' | tr -s ' ' | cut -c1-300)
    echo "script $l"
  elif grep -q 'error processing archive' "$log"; then
    echo "unpack $(grep -m1 -A2 'error processing archive' "$log" | tr '\n' ' ' | cut -c1-300)"
  else
    echo "other $(tail -3 "$log" | tr '\n' ' ' | cut -c1-300)"
  fi
}

# Whether the output in $2 of a program run that exited with $1 shows it works.
run_ok() {
  local rc=$1 out=$2
  if grep -qiE 'error while loading shared libraries|bad interpreter|No such file or directory|ModuleNotFoundError|ImportError|Can.t locate .* in @INC|cannot load such file|LoadError|ClassNotFoundException|Could not find or load main class|Cannot find module|not found in (the )?(path|search)' "$out"; then
    return 1
  fi
  [ "$rc" = 0 ] && return 0
  # Many programs exit non-zero on --version/--help but print a usage.
  [ "$rc" != 124 ] && [ "$rc" != 126 ] && [ "$rc" != 127 ] &&
    grep -qiE 'usage|version|options|--help' "$out"
}

# Run program $1 with --version, then --help. Prints ok, fail, gui, tty or hang.
try_program() {
  local out=$W/run.out rc a
  for a in --version --help; do
    timeout -k 2 10 "$@" "$a" </dev/null >"$out" 2>&1; rc=$?
    if run_ok "$rc" "$out"; then echo ok; return; fi
  done
  if grep -qiE 'cannot open display|could not connect to display|no display|qt\.qpa|Gtk-WARNING|Failed to initialize GTK|WAYLAND_DISPLAY|DISPLAY' "$out"; then
    echo gui
  elif grep -qiE 'not a terminal|tty|terminal|curses|TERM' "$out"; then
    echo tty
  elif [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
    echo hang
  else
    echo fail
  fi
}

survey_one() {
  local section=$1 pkg=$2 log=$OUT/logs/$2.log inst detail="" run=none progs="" p n how r
  local ok=0 bad=0 unt=0
  fresh_prefix
  (
    export PREFIX=$W/pfx HOME=$W/home
    export APT_CONFIG=$PREFIX/etc/apt/apt.conf.d/00local-prefix
    export PATH=$PREFIX/sbin:$PREFIX/bin:$PREFIX/usr/bin:/usr/local/bin:/usr/bin:/bin
    unset DISPLAY WAYLAND_DISPLAY DPKG_ADMINDIR
    timeout 1800 apt-get install -y --no-install-recommends \
      -o Dir::State::Lists="$BASE/var/lib/apt/lists" \
      -o Dir::Cache::Archives="$OUT/archives" "$pkg"
  ) >"$log" 2>&1
  local rc=$?
  if [ $rc = 0 ] &&
     PREFIX=$W/pfx "$W/pfx/bin/dpkg-query" -W -f '${db:Status-Abbrev}' "$pkg" 2>/dev/null |
       grep -q '^ii'; then
    inst=ok
  else
    detail=$(install_failure "$log"); inst=${detail%% *}
    [ "$inst" != "$detail" ] && detail=${detail#* } || detail=""
  fi

  if [ "$inst" = ok ]; then
    n=0
    while IFS= read -r p; do
      [ $n -lt "$MAXPROG" ] || break
      [ -x "$W/pfx$p" ] && [ ! -d "$W/pfx$p" ] || continue
      n=$((n + 1))
      p=${p##*/}
      if [ -f "$W/pfx/bin/$p" ] || [ -f "$W/pfx/sbin/$p" ]; then how=view; else how=direct; fi
      r=$(
        export PREFIX=$W/pfx HOME=$W/home
        export PATH=$PREFIX/sbin:$PREFIX/bin:$PREFIX/usr/bin:$PREFIX/usr/games:/usr/local/bin:/usr/bin:/bin
        unset DISPLAY WAYLAND_DISPLAY
        echo "=== $p ($how)" >>"$log"
        r=$(try_program "$p")
        cat "$W/run.out" >>"$log"
        if [ "$how" = direct ] && [ "$r" = fail ]; then
          r2=$(try_program "$PREFIX/lib/sudo-less/prefix-view" --run "$p")
          echo "=== $p (retry in the run view: $r2)" >>"$log"
          cat "$W/run.out" >>"$log"
          [ "$r2" != ok ] || r=miss
        fi
        echo "$r"
      )
      progs+="${progs:+,}$p:$how:$r"
      case $r in ok) ok=$((ok + 1)) ;; fail|miss) bad=$((bad + 1)) ;; *) unt=$((unt + 1)) ;; esac
    done < <(PREFIX=$W/pfx "$W/pfx/bin/dpkg-query" -L "$pkg" 2>/dev/null |
               grep -E '^/(usr/)?(s?bin|games)/[^/]+$')
    if [ $((ok + bad + unt)) -eq 0 ]; then run=none
    elif [ $bad -eq 0 ] && [ $ok -gt 0 ]; then run=ok
    elif [ $bad -eq 0 ]; then run=untested
    elif [ $ok -gt 0 ]; then run=partial
    else run=fail; fi
  else
    run=-
  fi
  detail=$(printf '%s' "$detail" | tr '\t\n' '  ')
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$section" "$pkg" "$inst" "$detail" "$run" "$progs" >> "$RES"
  printf '%-14s %-36s %-7s %-8s %s\n' "$section" "$pkg" "$inst" "$run" "${progs:-$detail}" | cut -c1-200
}

if [ "$LIST" = --reclassify ]; then
  while IFS=$'\t' read -r section pkg inst detail run progs; do
    if [ "$inst" != install ] && [ "$inst" != ok ]; then
      detail=$(install_failure "$OUT/logs/$pkg.log" | tr '\t\n' '  ')
      inst=${detail%% *}
      [ "$inst" != "$detail" ] && detail=${detail#* } || detail=""
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$section" "$pkg" "$inst" "$detail" "$run" "$progs"
  done < "$RES" > "$RES.new" && mv -f "$RES.new" "$RES"
  exit
fi

while IFS=$'\t' read -r section pkg _; do
  case $section in section|'') continue ;; esac
  if cut -f2 "$RES" | grep -qxF -- "$pkg"; then continue; fi   # resumable
  survey_one "$section" "$pkg"
done < "$LIST"
clean_work
