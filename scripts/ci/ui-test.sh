#!/bin/bash
# Runs UI tests for one platform and writes a result bundle.
#
#   ui-test.sh ios   <result.xcresult> <xcodebuild selectors…>   (needs SIMULATOR_ID)
#   ui-test.sh macos <result.xcresult> <xcodebuild selectors…>
#
# e.g. ui-test.sh ios out.xcresult -only-testing:summary-chipUITests/ScreenshotTests
#
# CI has no Apple ID for automatic signing. The simulator runs unsigned builds, and the Mac build
# is signed ad hoc without the entitlements that need a provisioning profile (app group, keychain
# group, associated domains). The UI tests run against the in-memory `--preview-*` fixtures, so
# they never reach the shared keychain or app group.
set -euo pipefail

PLATFORM=$1
RESULT_BUNDLE=$2
shift 2

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DERIVED_DATA=${DERIVED_DATA_PATH:-${RUNNER_TEMP:-/tmp}/summary-chip-ui-tests-$PLATFORM}

case "$PLATFORM" in
  ios)
    if [ -z "${SIMULATOR_ID:-}" ]; then
      echo "SIMULATOR_ID is not set" >&2
      exit 2
    fi
    ARGS=(-scheme summary-chip -destination "id=$SIMULATOR_ID" CODE_SIGNING_ALLOWED=NO)
    ;;
  macos)
    # Without this the runner waits for someone to authenticate and times out
    # ("Timed out while enabling automation mode").
    if automationmodetool 2>&1 | grep -q "requires user authentication"; then
      echo "::error::UI automation needs authentication on this Mac. Run once on the runner: sudo automationmodetool enable-automationmode-without-authentication" >&2
      exit 1
    fi
    ARGS=(
      -scheme summary-chip-macOS -destination "platform=macOS"
      CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=
      CODE_SIGN_ENTITLEMENTS= REGISTER_APP_GROUPS=NO
    )
    # Self-hosted runners keep the app's defaults (Sparkle's settings among them) and saved windows
    # between runs; start every CI run from a clean slate.
    if [ -n "${CI:-}" ]; then
      defaults delete com.rxlab.summary-chip >/dev/null 2>&1 || true
      rm -rf "$HOME/Library/Saved Application State/com.rxlab.summary-chip.savedState"
    fi
    ;;
  *)
    echo "Unknown platform '$PLATFORM' (expected ios or macos)" >&2
    exit 2
    ;;
esac

rm -rf "$RESULT_BUNDLE"
xcodebuild \
  -project "$ROOT/summary-chip.xcodeproj" \
  "${ARGS[@]}" \
  -derivedDataPath "$DERIVED_DATA" \
  -resultBundlePath "$RESULT_BUNDLE" \
  -parallel-testing-enabled NO \
  -collect-test-diagnostics never \
  -retry-tests-on-failure \
  -test-iterations "${TEST_ITERATIONS:-2}" \
  "$@" \
  test
