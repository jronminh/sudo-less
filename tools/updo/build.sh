#!/bin/sh
# Build the updo client and daemon into tools/updo/out/ (C99 + POSIX/Linux
# headers only; no libraries).
set -eu
cd "$(dirname "$0")"
mkdir -p out
CC="${CC:-cc}"
CFLAGS="${CFLAGS:--O2 -Wall -Wextra -D_FORTIFY_SOURCE=2 -fstack-protector-strong}"
$CC $CFLAGS -o out/updo updo.c
$CC $CFLAGS -o out/updod updod.c updo-conf.c
echo "built: $(pwd)/out/updo $(pwd)/out/updod"
