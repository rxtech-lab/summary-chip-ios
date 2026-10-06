#!/bin/bash
# Picks the newest simulator whose name matches a regex on the newest iOS runtime, erases it and
# boots it once, then prints its UDID. Picking by pattern means an Xcode update that drops last
# year's model does not leave CI pointing at a device that is gone.
#
#   udid=$(prepare-simulator.sh '^iPhone \d+ Pro$')
set -euo pipefail

PATTERN=$1

xcrun simctl shutdown all >/dev/null 2>&1 || true
xcrun simctl --set testing delete all >/dev/null 2>&1 || true

read -r udid name < <(xcrun simctl list devices available -j | PATTERN="$PATTERN" python3 -c '
import json, os, re, sys
pattern = re.compile(os.environ["PATTERN"])
def key(text):
    return [int(p) if p.isdigit() else p for p in re.split(r"(\d+)", text)]
found = []
for runtime, devices in json.load(sys.stdin)["devices"].items():
    if ".iOS-" not in runtime:
        continue
    for d in devices:
        if pattern.search(d["name"]):
            found.append((key(runtime), key(d["name"]), d["udid"], d["name"]))
if found:
    _, _, udid, name = max(found)
    print(udid, name)
') || true

if [ -z "${udid:-}" ]; then
  echo "No simulator matching '$PATTERN' is available on this runner" >&2
  exit 1
fi

echo "Using $name ($udid)" >&2
xcrun simctl erase "$udid" >&2
# Boot once so the first-boot data migration is done before xcodebuild drives the device.
xcrun simctl bootstatus "$udid" -b >&2
echo "$udid"
