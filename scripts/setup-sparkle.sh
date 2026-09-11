#!/usr/bin/env bash
# Download a pinned official Sparkle binary distribution into ignored local data.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="2.9.6"
SHA256="52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192"
DEST="$ROOT_DIR/local/dependencies/Sparkle-$VERSION"
if [ -f "$DEST/.verified-$SHA256" ] && [ -d "$DEST/Sparkle.framework" ]; then
    echo "$DEST"
    exit 0
fi
mkdir -p "$ROOT_DIR/local/dependencies"
TEMP="$(mktemp -d "$ROOT_DIR/local/dependencies/sparkle-download.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
curl --fail --location --proto '=https' --tlsv1.2 --retry 2 \
    "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz" \
    --output "$TEMP/Sparkle.tar.xz" >&2
printf '%s  %s\n' "$SHA256" "$TEMP/Sparkle.tar.xz" | shasum -a 256 -c - >&2
mkdir "$TEMP/unpacked"
tar -xf "$TEMP/Sparkle.tar.xz" -C "$TEMP/unpacked"
test -d "$TEMP/unpacked/Sparkle.framework"
mkdir -p "$DEST"
ditto "$TEMP/unpacked" "$DEST"
touch "$DEST/.verified-$SHA256"
echo "$DEST"
