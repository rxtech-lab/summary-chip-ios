#!/bin/bash
set -euo pipefail

: "${APPLE_ID:?APPLE_ID is required}"
: "${APPLE_ID_PWD:?APPLE_ID_PWD is required}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"

APP_PATH="./output/output.xcarchive/Products/Applications/summary-chip.app"
DMG_NAME="SummaryChip.dmg"

if [ ! -d "$APP_PATH" ]; then
  echo "Error: $APP_PATH not found"
  exit 1
fi

# Fail before notarizing if the archived app or embedded extension lost their
# entitlements (app groups / keychain sharing need the provisioning profile).
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
for bundle in "$APP_PATH" "$APP_PATH/Contents/PlugIns/MacSmartShare.appex"; do
  if ! codesign -d --entitlements - --xml "$bundle" 2>/dev/null | grep -q "com.apple.security.application-groups"; then
    echo "Error: $bundle is missing the application-groups entitlement"
    exit 1
  fi
done

# Remove existing DMG if it exists
rm -f ./*.dmg

# Create DMG. create-dmg exits non-zero when DMG signing fails (e.g. Apple's
# timestamp service is temporarily unavailable) even though the DMG was
# created, so retry a few times and fall back to the unsigned DMG.
for attempt in 1 2 3; do
  if create-dmg --overwrite "$APP_PATH"; then
    break
  fi
  echo "create-dmg failed (attempt $attempt)"
  if [ "$attempt" -lt 3 ]; then
    sleep 15
  fi
done

shopt -s nullglob
dmgs=(*.dmg)
shopt -u nullglob
if [ ${#dmgs[@]} -eq 0 ]; then
  echo "No DMG was created"
  exit 1
fi
mv "${dmgs[0]}" "$DMG_NAME"

echo "DMG created: $DMG_NAME"

# Notarize the DMG
xcrun notarytool submit "./$DMG_NAME" --verbose --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_ID_PWD" --wait

# Staple the ticket
xcrun stapler staple "$DMG_NAME"

echo "All operations completed successfully!"
