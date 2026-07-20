#!/usr/bin/env bash
# Build and run the RectZones test suite.
#
# A separate clang target from the app: same compiler, same flags, but it links
# only src/rzcore.m and Foundation. That keeps the app's build byte-for-byte
# untouched — reproducibility is a required CI check — and means the tests need
# no display, no Accessibility grant and no running app.
#
# Linking against Foundation alone is also load-bearing as a check in itself: if
# something in rzcore.m ever reaches for AppKit or the window server, this stops
# linking, which is the point.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${TMPDIR:-/tmp}/rectzones-tests"

clang -O2 -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Werror \
  -I "$DIR/src" \
  "$DIR/tests/rzcore_tests.m" "$DIR/src/rzcore.m" \
  -o "$BIN" \
  -framework Foundation

"$BIN"
