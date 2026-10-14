#!/bin/bash
# Shrinks a simulator screen recording until Telegram accepts it (bots can upload up to 50 MB): an
# H.264 MP4 whose bitrate fits the video's length into a 45 MB budget (compress-video.swift, with
# AVFoundation, so the runner needs nothing installed). Should the encoder overshoot, it tries again
# with a smaller budget; if every try fails the recording is kept as it is, and Telegram gets a link
# to the run instead.
#
#   compress-video.sh <recording.mov> <output.mp4>
set -euo pipefail

INPUT=$1
OUTPUT=$2
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/compress-video.swift"

if [ ! -s "$INPUT" ]; then
  echo "No recording at $INPUT" >&2
  exit 0
fi
mkdir -p "$(dirname "$OUTPUT")"

for budget in 47185920 36700160 26214400; do
  if xcrun swift "$SCRIPT" "$INPUT" "$OUTPUT" "$budget"; then
    exit 0
  fi
done
echo "Could not fit the recording under 50 MB; keeping it as recorded." >&2
cp "$INPUT" "$OUTPUT"
