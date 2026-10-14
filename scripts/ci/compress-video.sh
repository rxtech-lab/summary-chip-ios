#!/bin/bash
# Shrinks a simulator screen recording for sending to Telegram (bots can upload up to 50 MB): the
# longer side down to 1280 px, H.264 in an MP4. Uses ffmpeg when the runner has it, else macOS's
# avconvert, else keeps the recording as it is.
#
#   compress-video.sh <recording.mov> <output.mp4>
set -euo pipefail

INPUT=$1
OUTPUT=$2

if [ ! -s "$INPUT" ]; then
  echo "No recording at $INPUT" >&2
  exit 0
fi
mkdir -p "$(dirname "$OUTPUT")"

if command -v ffmpeg > /dev/null; then
  ffmpeg -y -loglevel error -i "$INPUT" \
    -vf "scale='if(gt(iw,ih),min(1280,iw),-2)':'if(gt(iw,ih),-2,min(1280,ih))'" \
    -c:v libx264 -preset veryfast -crf 30 -pix_fmt yuv420p -an -movflags +faststart "$OUTPUT"
elif ! avconvert --preset Preset1280x720 --source "$INPUT" --output "$OUTPUT" --replace > /dev/null; then
  echo "Could not compress the recording; keeping it as recorded." >&2
  cp "$INPUT" "$OUTPUT"
fi
ls -lh "$OUTPUT"
