#!/bin/bash
# Downloads the Sparkle binary framework into ./Sparkle (gitignored).
# Sparkle ships as a notarised binary release; there is nothing to compile.
set -euo pipefail

VERSION="${SPARKLE_VERSION:-2.9.6}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Sparkle"

if [ -d "$DEST/Sparkle.framework" ] && [ -z "${FORCE:-}" ]; then
    echo "✓ Sparkle $VERSION already present at $DEST"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

URL="https://github.com/sparkle-project/Sparkle/releases/download/${VERSION}/Sparkle-${VERSION}.tar.xz"
echo "→ downloading Sparkle ${VERSION}"
curl -fsSL -o "$TMP/sparkle.tar.xz" "$URL"

mkdir -p "$TMP/x"
tar -xJf "$TMP/sparkle.tar.xz" -C "$TMP/x"

rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$TMP/x/Sparkle.framework" "$DEST/"
[ -d "$TMP/x/bin" ] && cp -R "$TMP/x/bin" "$DEST/"

echo "✓ Sparkle ${VERSION} → $DEST"
