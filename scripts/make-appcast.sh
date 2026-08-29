#!/bin/bash
# Writes appcast.xml for one release. Sparkle reads this to discover updates.
#   VERSION=1.0.1 BUILD=3 ./scripts/make-appcast.sh <dmg> <ed-key-file> <download-url>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DMG="$1"; KEYFILE="$2"; URL="$3"
VERSION="${VERSION:?set VERSION}"
BUILD="${BUILD:?set BUILD}"
NOTES="${NOTES:-}"

SIGNED=$("$ROOT/Sparkle/bin/sign_update" "$DMG" "$KEYFILE")   # sparkle:edSignature="…" length="…"
PUBDATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")

cat > "$ROOT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Noty</title>
    <link>https://raw.githubusercontent.com/aimen08/noty/main/appcast.xml</link>
    <description>Sticky notes that live at the edge of your screen.</description>
    <language>en</language>
    <item>
      <title>${VERSION}</title>
      <pubDate>${PUBDATE}</pubDate>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <description><![CDATA[${NOTES}]]></description>
      <enclosure url="${URL}" type="application/octet-stream" ${SIGNED} />
    </item>
  </channel>
</rss>
XML

echo "✓ appcast.xml → ${VERSION} (build ${BUILD})"
