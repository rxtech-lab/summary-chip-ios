#!/bin/bash
set -euo pipefail

# Pin the macOS Developer ID provisioning profiles on the app and share
# extension targets.
#
# The profile must be scoped per target: a command-line
# PROVISIONING_PROFILE_SPECIFIER applies to every target in the graph,
# including SPM package targets that don't support profiles, which fails the
# archive. The checked-in project uses Automatic signing for local builds and
# Xcode Cloud (iOS), so this only rewrites the working copy on the CI runner;
# nothing is committed back. The setting is sdk-conditioned so the iOS slice of
# the multi-platform app target is untouched.
#
# Required env:
#   APP_PROFILE_SPECIFIER        profile Name for com.rxlab.summary-chip
#   EXTENSION_PROFILE_SPECIFIER  profile Name for com.rxlab.summary-chip.MacSmartShare

: "${APP_PROFILE_SPECIFIER:?APP_PROFILE_SPECIFIER is required}"
: "${EXTENSION_PROFILE_SPECIFIER:?EXTENSION_PROFILE_SPECIFIER is required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_FILE="${PROJECT_FILE:-$SCRIPT_DIR/../../summary-chip.xcodeproj/project.pbxproj}"

if [ ! -f "$PROJECT_FILE" ]; then
  echo "Error: $PROJECT_FILE not found"
  exit 1
fi

TMP_FILE=$(mktemp)

awk \
  -v app_profile="$APP_PROFILE_SPECIFIER" \
  -v ext_profile="$EXTENSION_PROFILE_SPECIFIER" '
BEGIN {
    in_build_settings = 0
    block = ""
    profile = ""
    app_count = 0
    ext_count = 0
}

/^[[:space:]]*buildSettings = \{[[:space:]]*$/ {
    in_build_settings = 1
    block = $0 ORS
    profile = ""
    next
}

in_build_settings {
    if (index($0, "PRODUCT_BUNDLE_IDENTIFIER = \"com.rxlab.summary-chip\";") > 0) {
        profile = app_profile
        app_count++
    } else if (index($0, "PRODUCT_BUNDLE_IDENTIFIER = \"com.rxlab.summary-chip.MacSmartShare\";") > 0) {
        profile = ext_profile
        ext_count++
    }
    if ($0 ~ /^[[:space:]]*\};[[:space:]]*$/) {
        if (profile != "") {
            block = block "\t\t\t\t\"PROVISIONING_PROFILE_SPECIFIER[sdk=macosx*]\" = \"" profile "\";" ORS
        }
        printf "%s%s", block, $0 ORS
        in_build_settings = 0
        block = ""
        profile = ""
        next
    }
    block = block $0 ORS
    next
}

{ print }

END {
    if (in_build_settings) {
        printf "%s", block
    }
    if (app_count == 0 || ext_count == 0) {
        print "Error: could not find app (" app_count ") or extension (" ext_count ") build settings" > "/dev/stderr"
        exit 1
    }
}
' "$PROJECT_FILE" > "$TMP_FILE"

mv "$TMP_FILE" "$PROJECT_FILE"

echo "Pinned provisioning profiles:"
echo "  com.rxlab.summary-chip              -> $APP_PROFILE_SPECIFIER"
echo "  com.rxlab.summary-chip.MacSmartShare -> $EXTENSION_PROFILE_SPECIFIER"
