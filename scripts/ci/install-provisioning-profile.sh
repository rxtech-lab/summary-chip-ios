#!/bin/bash
set -euo pipefail

# Decode a base64 provisioning profile, install it, and print its Name.
#
# Usage: install-provisioning-profile.sh <ENV_VAR_NAME>
# The env var named by the first argument must hold the base64 profile.

VAR_NAME="${1:-}"
if [ -z "$VAR_NAME" ]; then
  echo "Usage: $0 <ENV_VAR_NAME>" >&2
  exit 1
fi

PROFILE_B64="${!VAR_NAME:-}"
if [ -z "$PROFILE_B64" ]; then
  echo "::error::$VAR_NAME is required." >&2
  exit 1
fi

TMP_DIR="${RUNNER_TEMP:-/tmp}"
PROFILE_PATH="$TMP_DIR/$VAR_NAME.provisionprofile"
PROFILE_PLIST="$TMP_DIR/$VAR_NAME.plist"
PROFILE_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"

mkdir -p "$PROFILE_DIR"
printf '%s' "$PROFILE_B64" | base64 -D > "$PROFILE_PATH"
openssl cms -inform DER -verify -noverify -in "$PROFILE_PATH" -out "$PROFILE_PLIST" 2>/dev/null

PROFILE_UUID=$(/usr/libexec/PlistBuddy -c "Print UUID" "$PROFILE_PLIST")
PROFILE_NAME=$(/usr/libexec/PlistBuddy -c "Print Name" "$PROFILE_PLIST")

cp "$PROFILE_PATH" "$PROFILE_DIR/$PROFILE_UUID.provisionprofile"
echo "Installed '$PROFILE_NAME' ($PROFILE_UUID) from $VAR_NAME" >&2

echo "$PROFILE_NAME"
