#!/bin/bash
# Packages build/Noty.app into a drag-to-Applications disk image.
#   ./scripts/make-dmg.sh [version]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Noty.app"
VERSION="${1:-${MARKETING_VERSION:-1.0.0}}"
DMG="$ROOT/build/Noty-${VERSION}.dmg"

[ -d "$APP" ] || { echo "no app at $APP — run ./build.sh first" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# A background-less window is fine; what matters is the drag target being obvious.
rm -f "$DMG"
hdiutil create \
    -volname "Noty" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    -fs HFS+ \
    -imagekey zlib-level=9 \
    "$DMG" >/dev/null

SIZE=$(stat -f%z "$DMG")
echo "✓ $DMG ($((SIZE / 1024 / 1024)) MB)"
