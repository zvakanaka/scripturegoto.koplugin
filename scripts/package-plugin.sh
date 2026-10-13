#!/bin/bash
# Packages a release of scripturegoto.koplugin:
#
#   dist/scripturegoto.koplugin.zip      for installing by hand
#   dist/scripturegoto.koplugin.tar.gz   for the self-updater
#   dist/version.json                    manifest for the update server
#
# The version is scripturegoto.koplugin/VERSION (YYYY.MM.DD-N). The
# self-updater only works when the plugin directory has update-server.txt
# (the manifest URL, first line) and update-ca.pem (the server's
# certificate); neither is in the repository, and without them the package
# is built with updates disabled.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN="$REPO/scripturegoto.koplugin"
DIST="$REPO/dist"
STAGE="$DIST/stage/scripturegoto.koplugin"
VERSION="$(tr -d '[:space:]' < "$PLUGIN/VERSION")"

rm -rf "$DIST"
mkdir -p "$STAGE"

(cd "$PLUGIN" && find . -name '*.lua' -print0 | cpio -0pdm --quiet "$STAGE")
cp "$PLUGIN/VERSION" "$REPO/LICENSE" "$STAGE/"
if [ -f "$PLUGIN/update-server.txt" ] && [ -f "$PLUGIN/update-ca.pem" ]; then
    cp "$PLUGIN/update-server.txt" "$PLUGIN/update-ca.pem" "$STAGE/"
else
    echo "note: no update-server.txt/update-ca.pem, the self-updater will be disabled"
fi

cd "$DIST/stage"
zip -qr "$DIST/scripturegoto.koplugin.zip" scripturegoto.koplugin
tar -czf "$DIST/scripturegoto.koplugin.tar.gz" scripturegoto.koplugin
cd "$DIST"
sha=$(sha256sum scripturegoto.koplugin.tar.gz | cut -d' ' -f1)
size=$(stat -c %s scripturegoto.koplugin.tar.gz)
url=""
[ -f "$PLUGIN/update-server.txt" ] && url="$(dirname "$(head -1 "$PLUGIN/update-server.txt")")/scripturegoto.koplugin.tar.gz"
printf '{\n  "version": "%s",\n  "url": "%s",\n  "sha256": "%s",\n  "size": %s,\n  "notes": ""\n}\n' \
    "$VERSION" "$url" "$sha" "$size" > version.json
rm -rf "$DIST/stage"
echo "scripturegoto.koplugin $VERSION: $(du -h scripturegoto.koplugin.zip | cut -f1) (.zip), $(du -h scripturegoto.koplugin.tar.gz | cut -f1) (.tar.gz)"
echo "manifest: $DIST/version.json (fill in notes before publishing)"
