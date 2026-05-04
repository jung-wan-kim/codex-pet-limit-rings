#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/tools/CodexPetLimitRings-Info.plist" 2>/dev/null || echo dev)"
OUT="${1:-$ROOT/dist/CodexPetLimitRings-$VERSION.pkg}"
SIGN_IDENTITY="${CODEX_PET_LIMIT_RINGS_PKG_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${CODEX_PET_LIMIT_RINGS_NOTARY_PROFILE:-}"
WORK_DIR="$ROOT/tmp/pkg"
PAYLOAD="$WORK_DIR/payload"
SCRIPTS="$WORK_DIR/scripts"
APP="$PAYLOAD/Applications/CodexPetLimitRings.app"
IDENTIFIER="local.codex.pet-limit-rings.installer"
LABEL="com.codex-pet.limit-rings"
BIN="/Applications/CodexPetLimitRings.app/Contents/MacOS/CodexPetLimitRings"

rm -rf "$WORK_DIR"
mkdir -p "$PAYLOAD/Applications" "$SCRIPTS" "$(dirname "$OUT")"

"$ROOT/tools/build-limit-rings.sh" "$APP" >/dev/null

cat > "$SCRIPTS/postinstall" <<POSTINSTALL
#!/bin/bash
set -euo pipefail

LABEL="$LABEL"
BIN="$BIN"
APP="/Applications/CodexPetLimitRings.app"

console_user="\$(/usr/bin/stat -f %Su /dev/console 2>/dev/null || true)"
if [ -z "\$console_user" ] || [ "\$console_user" = "root" ] || [ "\$console_user" = "_mbsetupuser" ]; then
  exit 0
fi

uid="\$(/usr/bin/id -u "\$console_user" 2>/dev/null || true)"
home_dir="\$(/usr/bin/dscl . -read "/Users/\$console_user" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print \$2}')"
if [ -z "\$uid" ] || [ -z "\$home_dir" ] || [ ! -d "\$home_dir" ]; then
  exit 0
fi

agent_dir="\$home_dir/Library/LaunchAgents"
agent="\$agent_dir/\$LABEL.plist"
log_dir="\$home_dir/Library/Logs"

/bin/mkdir -p "\$agent_dir" "\$log_dir"
/usr/sbin/chown "\$console_user" "\$agent_dir" "\$log_dir" 2>/dev/null || true

/bin/cat > "\$agent" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>\$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>\$BIN</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
  <key>StandardOutPath</key>
  <string>\$log_dir/CodexPetLimitRings.log</string>
  <key>StandardErrorPath</key>
  <string>\$log_dir/CodexPetLimitRings.err.log</string>
</dict>
</plist>
PLIST

/usr/sbin/chown "\$console_user" "\$agent" 2>/dev/null || true
/bin/chmod 644 "\$agent"

/bin/launchctl bootout "gui/\$uid" "\$agent" >/dev/null 2>&1 || true
/usr/bin/pkill -TERM -f "CodexPetLimitRings.app/Contents/MacOS/CodexPetLimitRings" >/dev/null 2>&1 || true
/bin/launchctl bootstrap "gui/\$uid" "\$agent" >/dev/null 2>&1 || true
/bin/launchctl kickstart -k "gui/\$uid/\$LABEL" >/dev/null 2>&1 || true

if [ -d "\$APP" ]; then
  /usr/sbin/chown -R root:wheel "\$APP" 2>/dev/null || true
fi

exit 0
POSTINSTALL
chmod +x "$SCRIPTS/postinstall"

rm -f "$OUT"
PKG_OUT="$OUT"
if [ -n "$SIGN_IDENTITY" ]; then
  PKG_OUT="$WORK_DIR/CodexPetLimitRings-$VERSION.unsigned.pkg"
fi

pkgbuild \
  --root "$PAYLOAD" \
  --scripts "$SCRIPTS" \
  --identifier "$IDENTIFIER" \
  --version "$VERSION" \
  --install-location / \
  "$PKG_OUT" >/dev/null

if [ -n "$SIGN_IDENTITY" ]; then
  productsign --sign "$SIGN_IDENTITY" "$PKG_OUT" "$OUT" >/dev/null
  pkgutil --check-signature "$OUT" >/dev/null
else
  pkgutil --check-signature "$OUT" >/dev/null 2>&1 || true
fi

if [ -n "$NOTARY_PROFILE" ]; then
  xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY_PROFILE" --wait >/dev/null
  xcrun stapler staple "$OUT" >/dev/null
fi

echo "$OUT"
