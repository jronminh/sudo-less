#!/bin/bash
# patch-services-jar.sh - build a services.jar whose
# LaunchParamsUtil.getDefaultFreeformSize() guards the divide-by-zero that
# kills system_server in Waydroid multi-window mode (waydroid/waydroid#1446,
# see docs/waydroid-mesa-debug.md §14-15).
#
# Unprivileged: needs only java + baksmali/smali. It does NOT touch the live
# Waydroid install; deploy the result with
# admin/waydroid-install-framework-overlay.sh (run as the admin account).
#
# Usage:
#   patch-services-jar.sh [SRC_JAR] [OUT_JAR]
# Defaults:
#   SRC_JAR = /var/lib/waydroid/rootfs/system/framework/services.jar
#   OUT_JAR = ./services.patched.jar
#
# Toolchain (override by env):
#   BAKSMALI_JAR, SMALI_JAR  (default ./baksmali-2.5.2.jar / ./smali-2.5.2.jar)
#   Downloaded from bitbucket if absent.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
PATCH=$HERE/patches/LaunchParamsUtil-freeform-divzero.diff

SRC=${1:-/var/lib/waydroid/rootfs/system/framework/services.jar}
OUT=${2:-$PWD/services.patched.jar}
OUT=$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")
BAKSMALI_JAR=${BAKSMALI_JAR:-$PWD/baksmali-2.5.2.jar}
SMALI_JAR=${SMALI_JAR:-$PWD/smali-2.5.2.jar}
API=33   # Android 13 -> dex v039, matching the LineageOS 20 image

command -v java >/dev/null || {
  echo "java not found (e.g. deb2home openjdk-17-jre-headless)" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 not found" >&2; exit 1; }
[ -r "$SRC" ] || { echo "source jar not readable: $SRC" >&2; exit 1; }

fetch() { # fetch <url> <file>
  [ -s "$2" ] || { echo "downloading $(basename "$2")"; curl -sL -o "$2" "$1"; }
}
fetch https://bitbucket.org/JesusFreke/smali/downloads/baksmali-2.5.2.jar "$BAKSMALI_JAR"
fetch https://bitbucket.org/JesusFreke/smali/downloads/smali-2.5.2.jar "$SMALI_JAR"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

unzip -q "$SRC" classes2.dex -d "$WORK"
java -Xmx3g -jar "$BAKSMALI_JAR" d "$WORK/classes2.dex" -o "$WORK/smali"

# Idempotent: SRC may already be a patched jar (e.g. the live overlaid
# /var/lib/waydroid/rootfs copy), in which case there is nothing to apply.
TARGET=$WORK/smali/com/android/server/wm/LaunchParamsUtil.smali
if grep -q 'if-eqz p4, :cond_divzero_guard' "$TARGET"; then
  echo "guard already present in $SRC; repacking unchanged"
else
  ( cd "$WORK/smali" && patch -p1 <"$PATCH" )
fi

java -Xmx3g -jar "$SMALI_JAR" a -a "$API" "$WORK/smali" -o "$WORK/classes2.dex"

# Repack: copy every entry of the original jar unchanged, substituting the
# patched classes2.dex. Python's zipfile preserves each entry's own
# compression (the image stores its dex uncompressed) and needs no `zip`
# binary — which matters when the Java toolchain lives on a machine (e.g.
# Termux on the phone) that has none.
python3 - "$SRC" "$WORK/classes2.dex" "$OUT" <<'PY'
import sys, zipfile
src, dex, out = sys.argv[1:4]
patched = open(dex, 'rb').read()
with zipfile.ZipFile(src) as zin, zipfile.ZipFile(out, 'w') as zout:
    for item in zin.infolist():
        data = patched if item.filename == 'classes2.dex' else zin.read(item.filename)
        zout.writestr(item, data)   # reuse ZipInfo: keeps compression/mode/time
PY

echo "wrote $OUT"
sha256sum "$OUT"
