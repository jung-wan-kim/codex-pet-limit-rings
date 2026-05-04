#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="CodexPetLimitRings.app"
PKG_NAME="Install Codex Pet Limit Rings.pkg"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/tools/CodexPetLimitRings-Info.plist" 2>/dev/null || echo dev)"
DIST_DIR="${CODEX_PET_LIMIT_RINGS_DIST:-$ROOT/dist}"
WORK_DIR="$ROOT/tmp/dmg"
APP="$WORK_DIR/$APP_NAME"
PKG="$WORK_DIR/CodexPetLimitRings-$VERSION.pkg"
STAGE="$WORK_DIR/stage"
DMG="$DIST_DIR/CodexPetLimitRings-$VERSION.dmg"
VOLNAME="Codex Pet Limit Rings $VERSION"

rm -rf "$WORK_DIR"
mkdir -p "$STAGE" "$DIST_DIR"

"$ROOT/tools/build-limit-rings.sh" "$APP" >/dev/null
"$ROOT/tools/build-limit-rings-pkg.sh" "$PKG" >/dev/null
cp "$PKG" "$STAGE/$PKG_NAME"
cp -R "$APP" "$STAGE/$APP_NAME"

rm -f "$STAGE/Applications"
if command -v osascript >/dev/null 2>&1; then
  osascript <<APPLESCRIPT >/dev/null 2>&1 || ln -s /Applications "$STAGE/Applications"
tell application "Finder"
  make alias file to POSIX file "/Applications" at POSIX file "$STAGE"
  set name of result to "Applications"
end tell
APPLESCRIPT
else
  ln -s /Applications "$STAGE/Applications"
fi

cat > "$STAGE/README.txt" <<README
Codex Pet Limit Rings

Install:
1. Double-click "Install Codex Pet Limit Rings.pkg".
2. Complete the macOS Installer prompts.
3. The installer copies the app to /Applications and starts the menu-bar companion for the current user.

Alternative manual install:
- Drag CodexPetLimitRings.app to the Applications folder shortcut, then open it manually.

The app is a companion overlay and does not patch Codex.
README


if command -v osascript >/dev/null 2>&1; then
  osascript <<APPLESCRIPT >/dev/null 2>&1 || true
tell application "Finder"
  set dmgFolder to POSIX file "$STAGE" as alias
  open dmgFolder
  set folderWindow to container window of dmgFolder
  set current view of folderWindow to icon view
  set toolbar visible of folderWindow to false
  set statusbar visible of folderWindow to false
  set bounds of folderWindow to {120, 120, 1040, 430}
  set viewOptions to icon view options of folderWindow
  set arrangement of viewOptions to not arranged
  set icon size of viewOptions to 96
  set text size of viewOptions to 14
  set position of item "$APP_NAME" of dmgFolder to {180, 145}
  set position of item "Applications" of dmgFolder to {440, 145}
  set position of item "$PKG_NAME" of dmgFolder to {700, 145}
  set position of item "README.txt" of dmgFolder to {900, 145}
  update dmgFolder without registering applications
  delay 0.2
  close folderWindow
end tell
APPLESCRIPT
fi

rm -f "$DMG"
hdiutil create \
  -volname "$VOLNAME" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG" >/dev/null

hdiutil verify "$DMG" >/dev/null

echo "$DMG"
