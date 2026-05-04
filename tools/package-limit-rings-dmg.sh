#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="CodexPetLimitRings.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/tools/CodexPetLimitRings-Info.plist" 2>/dev/null || echo dev)"
DIST_DIR="${CODEX_PET_LIMIT_RINGS_DIST:-$ROOT/dist}"
WORK_DIR="$ROOT/tmp/dmg"
APP="$WORK_DIR/$APP_NAME"
STAGE="$WORK_DIR/stage"
DMG="$DIST_DIR/CodexPetLimitRings-$VERSION.dmg"
VOLNAME="Codex Pet Limit Rings $VERSION"

rm -rf "$WORK_DIR"
mkdir -p "$STAGE" "$DIST_DIR"

"$ROOT/tools/build-limit-rings.sh" "$APP" >/dev/null
cp -R "$APP" "$STAGE/$APP_NAME"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/README.txt" <<README
Codex Pet Limit Rings

Install:
1. Drag CodexPetLimitRings.app to the Applications folder shortcut.
2. Open CodexPetLimitRings.app from Applications.
3. Use the menu-bar ring icon to show/hide rings, refresh usage, reset position, or quit.

The app is a companion overlay and does not patch Codex.
README

rm -f "$DMG"
hdiutil create \
  -volname "$VOLNAME" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG" >/dev/null

hdiutil verify "$DMG" >/dev/null

echo "$DMG"
