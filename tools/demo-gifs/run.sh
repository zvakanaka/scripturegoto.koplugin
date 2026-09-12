#!/bin/sh
# Regenerates all four docs/demo-*.gif files by driving a real (emulated)
# koreader through each usage flow and recording it. See README.md in this
# directory for how it works and its prerequisites.
set -e
cd "$(dirname "$0")"
REPO="$(cd ../.. && pwd)"

if [ ! -d "$REPO/vendor/squashfs-root" ]; then
    echo "vendor/squashfs-root not found - set up the dev environment first (see test-books/README.md)." >&2
    exit 1
fi

VOLUME_EPUBS_HOME="$REPO/vendor/koreader-home"
if ! grep -q "scripturegoto_volume_epubs" "$VOLUME_EPUBS_HOME/settings.reader.lua" 2>/dev/null; then
    echo "No scripturegoto_volume_epubs configured in $VOLUME_EPUBS_HOME/settings.reader.lua." >&2
    echo "Set nt/ot/bofm EPUBs via the plugin's own menu first (see test-books/README.md)." >&2
    exit 1
fi

CACHE_DIR="$VOLUME_EPUBS_HOME/scripturegoto"
mkdir -p "$CACHE_DIR"
for pair in "nt:new-testament-flat.json" "bofm:book-of-mormon-flat.json"; do
    file="${pair#*:}"
    if [ ! -f "$CACHE_DIR/$file" ]; then
        echo "Downloading $file (one-time, for the preview GIFs)..."
        curl -fsSL "https://raw.githubusercontent.com/bcbooks/scriptures-json/master/flat/$file" \
            -o "$CACHE_DIR/$file"
    fi
done

python3 build_demo_epub.py

pkill -9 -f "squashfs-root.*koreader" 2>/dev/null || true

for mode in jump preview hjump hpreview; do
    echo "Recording $mode..."
    python3 record.py "$mode" "$PWD/build" "$PWD/build/demo.epub"
done

echo "Assembling GIFs..."
python3 assemble.py

echo "Done - see $REPO/docs/demo-*.gif"
