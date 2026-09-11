#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${MACTOOLS_BUILD_DIR:-$ROOT_DIR/build}"
INSTALLED_APP="$HOME/Applications/MacTools.app"
EXTENSION_ID="com.leon4z.MacTools.FinderExtension"
EXTENSION_NAME="MacToolsFinderExtension.appex"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
BACKUP="$ROOT_DIR/local/install-$(date +%Y%m%d-%H%M%S)"
export MACTOOLS_SIGNING_IDENTITY="${MACTOOLS_SIGNING_IDENTITY:-MacTools Local Signing}"
"$ROOT_DIR/scripts/build.sh" >/dev/null
BUILT_APP="$BUILD_DIR/MacTools.app"
codesign --verify --deep --strict "$BUILT_APP"
mkdir -p "$HOME/Applications" "$BACKUP"
# Normal termination restores input leases and may refuse while a move is busy.
pkill -TERM -x MacTools 2>/dev/null || true
for attempt in 1 2 3 4 5; do
    if ! pgrep -x MacTools >/dev/null; then break; fi
    sleep 1
done
if pgrep -x MacTools >/dev/null; then
    echo "App is still running; finish active operations and quit before installing." >&2
    exit 1
fi
if [ -d "$INSTALLED_APP" ]; then
    for extension in "$INSTALLED_APP/Contents/PlugIns/"*.appex; do
        pluginkit -r "$extension" || true
    done
    "$LSREGISTER" -u "$INSTALLED_APP" >/dev/null 2>&1 || true
    mv "$INSTALLED_APP" "$BACKUP/MacTools.app.backup"
fi
if ! ditto "$BUILT_APP" "$INSTALLED_APP" || ! codesign --verify --deep --strict "$INSTALLED_APP"; then
    if [ -d "$INSTALLED_APP" ]; then mv "$INSTALLED_APP" "$BACKUP/failed-install.backup"; fi
    if [ -d "$BACKUP/MacTools.app.backup" ]; then
        ditto "$BACKUP/MacTools.app.backup" "$INSTALLED_APP"
        "$LSREGISTER" -f "$INSTALLED_APP"
        for extension in "$INSTALLED_APP/Contents/PlugIns/"*.appex; do pluginkit -a "$extension" || true; done
    fi
    exit 1
fi
# Only the installed extension should be registered.
pluginkit -r "$BUILT_APP/Contents/PlugIns/$EXTENSION_NAME" >/dev/null 2>&1 || true
"$LSREGISTER" -u "$BUILT_APP" >/dev/null 2>&1 || true
"$LSREGISTER" -f "$INSTALLED_APP"
pluginkit -a "$INSTALLED_APP/Contents/PlugIns/$EXTENSION_NAME"
pluginkit -e use -i "$EXTENSION_ID"
open "$INSTALLED_APP"
echo "Installed: $INSTALLED_APP"
echo "Rollback backup: $BACKUP"
pluginkit -m -A -D -v -i "$EXTENSION_ID"
