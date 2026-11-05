#!/bin/bash
set -euo pipefail

: "${SIGNING_CERTIFICATE_NAME:?SIGNING_CERTIFICATE_NAME is required}"
APP_PATH="${APP_PATH:-output/output.xcarchive/Products/Applications/Chippy.app}"
FRAMEWORK="$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B"

retry_codesign() {
  local attempt
  for attempt in 1 2 3; do
    if codesign --force --options runtime --timestamp --sign "$SIGNING_CERTIFICATE_NAME" "$@"; then
      return 0
    fi
    if [ "$attempt" -lt 3 ]; then sleep 15; fi
  done
  return 1
}

# Sign inside out. Preserve the Downloader's own entitlements and the app's
# archived provisioning entitlements; do not propagate app entitlements to helpers.
retry_codesign "$FRAMEWORK/XPCServices/Installer.xpc"
retry_codesign --preserve-metadata=entitlements "$FRAMEWORK/XPCServices/Downloader.xpc"
retry_codesign "$FRAMEWORK/Autoupdate"
retry_codesign "$FRAMEWORK/Updater.app"
retry_codesign "$APP_PATH/Contents/Frameworks/Sparkle.framework"
# The local agent runner must stay outside the sandbox and has no entitlements to preserve.
RUNNER="$APP_PATH/Contents/XPCServices/ChippyLocalAgentRunner.xpc"
retry_codesign "$RUNNER"
retry_codesign --preserve-metadata=entitlements "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

codesign -d --entitlements - --xml "$APP_PATH" 2>/dev/null |
  python3 -c 'import plistlib,sys; e=plistlib.loads(sys.stdin.buffer.read()); assert e.get("com.apple.security.app-sandbox"); assert e.get("com.apple.security.application-groups"); assert "com.rxlab.summary-chip-spki" in e.get("com.apple.security.temporary-exception.mach-lookup.global-name", [])'

# The runner launches agents, which can't work inside a sandbox, and it has to carry the hardened runtime.
# Output goes through variables because `grep -q` exiting early would fail the pipeline under pipefail.
runner_signature="$(codesign -d --verbose=2 "$RUNNER" 2>&1)"
grep -q "flags=.*runtime" <<<"$runner_signature"
runner_entitlements="$(codesign -d --entitlements - --xml "$RUNNER" 2>/dev/null || true)"
if grep -q "com.apple.security.app-sandbox" <<<"$runner_entitlements"; then
  echo "ChippyLocalAgentRunner must not be sandboxed" >&2
  exit 1
fi
