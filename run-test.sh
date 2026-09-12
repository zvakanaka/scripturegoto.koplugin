#!/bin/sh
# Launches the KOReader emulator AppImage build with an isolated settings
# dir (vendor/koreader-home) and our plugin symlinked in, for developing
# and manually testing scripturegoto.koplugin.
#
# Usage: ./run-test.sh [path-to-book-to-open]
# See test-books/README.md for the full dev environment and test fixtures.
set -e
cd "$(dirname "$0")"
export KO_HOME="$PWD/vendor/koreader-home"
mkdir -p "$KO_HOME"
exec ./vendor/squashfs-root/usr/lib/koreader/koreader.sh "${1:-$PWD/test-books/source-book.epub}"
