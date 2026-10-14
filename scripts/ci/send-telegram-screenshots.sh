#!/bin/bash
# Sends a PR's screenshots to a Telegram chat so they can be reviewed on a phone: one message with
# the repo, PR and run links, then each device's screens as photo albums (Telegram caps an album
# at 10 photos).
#
#   send-telegram-screenshots.sh <screenshots-dir>
#
# <screenshots-dir> holds one `screenshots-<device>` folder per device, as download-artifact lays
# them out. Reads TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, REPO, PR, PR_TITLE, PR_URL, PR_AUTHOR,
# HEAD_REF, BASE_REF, SHA, RUN_URL and STATUS from the environment.
set -euo pipefail

SCREENSHOTS_DIR=$1
API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"

html_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<< "$1"
}

# Fails loudly on a Telegram error without echoing the token-bearing URL.
telegram() {
  local method=$1
  shift
  local response
  response=$(curl -sS "$@" "${API}/${method}")
  if [ "$(jq -r .ok <<< "$response")" != "true" ]; then
    echo "Telegram ${method} failed: $(jq -r .description <<< "$response")" >&2
    return 1
  fi
}

message="📸 <b>App screenshots</b> · $(html_escape "$REPO")
<a href=\"${PR_URL}\">#${PR} $(html_escape "$PR_TITLE")</a>
by $(html_escape "$PR_AUTHOR") · <code>$(html_escape "$HEAD_REF")</code> → <code>$(html_escape "$BASE_REF")</code>
Commit <code>${SHA:0:7}</code> · $(html_escape "$STATUS")

<a href=\"${PR_URL}\">Open PR</a> · <a href=\"${RUN_URL}\">View run</a>"

telegram sendMessage \
  --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
  --data-urlencode "text=${message}" \
  --data-urlencode "parse_mode=HTML" \
  --data-urlencode "disable_web_page_preview=true"

for device_dir in "$SCREENSHOTS_DIR"/screenshots-*/; do
  [ -d "$device_dir" ] || continue
  device=$(basename "$device_dir")
  case ${device#screenshots-} in
    iphone) device="iPhone" ;;
    ipad) device="iPad" ;;
    *) device=${device#screenshots-} ;;
  esac
  mapfile -t files < <(find "$device_dir" -maxdepth 1 -name '*.png' | sort)
  total=${#files[@]}
  [ "$total" -gt 0 ] || continue
  for ((start = 0; start < total; start += 10)); do
    args=()
    media="[]"
    for ((i = start; i < total && i < start + 10; i++)); do
      screen=$(basename "${files[$i]}" .png)
      caption="${device} · ${screen#*-} ($((i + 1))/${total}) · #${PR}"
      media=$(jq -c --arg ref "attach://p$i" --arg caption "$caption" \
        '. + [{type: "photo", media: $ref, caption: $caption}]' <<< "$media")
      args+=(-F "p$i=@${files[$i]}")
    done
    if [ "$(jq length <<< "$media")" -eq 1 ]; then
      # sendMediaGroup needs at least two items.
      telegram sendPhoto -F "chat_id=${TELEGRAM_CHAT_ID}" \
        -F "photo=@${files[$start]}" --form-string "caption=$(jq -r '.[0].caption' <<< "$media")"
    else
      telegram sendMediaGroup -F "chat_id=${TELEGRAM_CHAT_ID}" --form-string "media=${media}" "${args[@]}"
    fi
  done
done
