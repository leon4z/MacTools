#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${FRC_BUILD_DIR:-$ROOT_DIR/build}"
INSTALLED_APP="$HOME/Applications/MacTools.app"
LEGACY_APP="$HOME/Applications/FinderRightClick.app"
EXTENSION_ID="local.leon.FinderRightClick.Extension"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
BACKUP="$ROOT_DIR/local/install-$(date +%Y%m%d-%H%M%S)"
# Local installs must never silently fall back to an unstable ad-hoc identity.
export MACTOOLS_SIGNING_IDENTITY="${MACTOOLS_SIGNING_IDENTITY:-MacTools Local Signing}"
"$ROOT_DIR/scripts/build.sh" >/dev/null
BUILT_APP="$BUILD_DIR/MacTools.app"
codesign --verify --deep --strict "$BUILT_APP"
mkdir -p "$HOME/Applications" "$BACKUP"
# MacTools handles SIGTERM by terminating through AppKit and restoring leases.
# Refuse to replace a process which is still busy or has not exited.
pkill -TERM -x MacTools 2>/dev/null || true
pkill -TERM -x FinderRightClick 2>/dev/null || true
for attempt in 1 2 3 4 5; do
    if ! pgrep -x MacTools >/dev/null && ! pgrep -x FinderRightClick >/dev/null; then break; fi
    sleep 1
done
if pgrep -x MacTools >/dev/null || pgrep -x FinderRightClick >/dev/null; then
    echo "App is still running; finish active operations and quit before installing." >&2
    exit 1
fi
for previous in "$INSTALLED_APP" "$LEGACY_APP"; do
    if [ -d "$previous" ]; then
        pluginkit -r "$previous/Contents/PlugIns/FinderRightClickExtension.appex" || true
        "$LSREGISTER" -u "$previous" >/dev/null 2>&1 || true
        mv "$previous" "$BACKUP/$(basename "$previous").backup"
    fi
done
if ! ditto "$BUILT_APP" "$INSTALLED_APP" || ! codesign --verify --deep --strict "$INSTALLED_APP"; then
    if [ -d "$INSTALLED_APP" ]; then mv "$INSTALLED_APP" "$BACKUP/failed-install.backup"; fi
    for name in MacTools FinderRightClick; do
        if [ -d "$BACKUP/$name.app.backup" ]; then
            ditto "$BACKUP/$name.app.backup" "$HOME/Applications/$name.app"
            pluginkit -a "$HOME/Applications/$name.app/Contents/PlugIns/FinderRightClickExtension.appex" || true
        fi
    done
    exit 1
fi
# Only the installed extension should be registered.
pluginkit -r "$BUILT_APP/Contents/PlugIns/FinderRightClickExtension.appex" >/dev/null 2>&1 || true
"$LSREGISTER" -u "$BUILT_APP" >/dev/null 2>&1 || true
"$LSREGISTER" -f "$INSTALLED_APP"
pluginkit -a "$INSTALLED_APP/Contents/PlugIns/FinderRightClickExtension.appex"
pluginkit -e use -i "$EXTENSION_ID"
open "$INSTALLED_APP"
echo "Installed: $INSTALLED_APP"
echo "Rollback backup: $BACKUP"
pluginkit -m -A -D -v -i "$EXTENSION_ID"
