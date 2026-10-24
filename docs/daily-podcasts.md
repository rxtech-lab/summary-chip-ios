# Daily podcasts

The Feed's daily play button opens a dedicated player sheet. A separate generation sheet chooses the spoken language. An agent writes a conversational podcast from all readable summary chips on that activity day, independently of pagination and feed filters. Owned chips use their creation date; others use their last viewed date, matching the Feed. Trips, papers and clips are excluded. The current limit is 24 chips and 24 short spoken turns; larger days are explicitly refused rather than silently truncated.

The player overlays host names, exact spoken captions, a seek slider and playback controls on the cover using Liquid Glass. One continuous MP3 plays the whole episode, with timed caption and artwork changes and 15-second skip controls. A dedicated download sheet saves the original complete MP3, or renders a 1280×720 MP4 locally with the recording, timed artwork and burned-in captions. Regeneration has a native confirmation and may choose a different language. Generation and buffering use overlays; mobile interactions provide haptics.

## API contract

All `/api/v1` endpoints require the app's bearer token. All JSON responses use `Cache-Control: no-store`. Day boundaries are ISO 8601 instants describing one local calendar day, including 23/25-hour daylight-saving days. The app computes these boundaries using its calendar, rather than sending a UTC date.

`GET /api/v1/daily-podcasts?start=<instant>&end=<instant>` returns `{ "podcast": null }` when no episode exists, or `{ "podcast": DailyPodcast }`. It never invokes AI or spends points.

`POST /api/v1/daily-podcasts` accepts:

```json
{
  "day": { "start": "2030-04-01T00:00:00+08:00", "end": "2030-04-02T00:00:00+08:00" },
  "language": "en",
  "regenerate": false
}
```

Languages: `en`, `zh-Hans`, `zh-Hant`, `ja`, `ko`, `es`, `fr`, `de`. The response envelope is `{ "podcast": DailyPodcast }`. A saved episode is returned unchanged, including its original language, unless `regenerate` is explicitly true. Generation spends points for narration and speech; saved playback is free. App Store billing proof follows the same routing as trip tours. Request timeout: 300 seconds. Do not automatically replay an ambiguous regeneration request.

`DailyPodcast` contains `key`, `title`, `language`, `createdAt`, `day`, `chipIds`, `audioPath`, `durationSeconds`, `speakers: [{name, voice}]`, and caption cues in `segments: [{speaker, chipId, caption, startSeconds, endSeconds, voiceStartSeconds, voiceEndSeconds, pauseSeconds, imagePath, icon}]`. `voiceStartSeconds`/`voiceEndSeconds` bound the audible voice inside the turn and `pauseSeconds` lists its measured pauses (≥ 150 ms), all in episode seconds; they're omitted when a turn can't be analysed. `speaker` is a zero-based index. `caption` is the exact spoken turn. `imagePath` is an optional relative authenticated chip artwork URL, with `icon` as fallback.

`GET /api/v1/daily-podcasts/:key/audio?start=<instant>&end=<instant>` returns the complete persisted MP3 with `Content-Disposition: attachment` and `private, no-store`. It never generates speech. Audio is assembled by remuxing validated MPEG Layer III frames with a complete-file Xing seek header; all voices must use compatible sample rate and channel layout. The old per-segment route remains for legacy artifacts. Opening an older saved episode assembles its existing recordings once and saves the continuous track and timings without any AI calls. Storage is partitioned by the authenticated account; all source chips must still be readable for metadata or audio to be returned. Deleting or revoking a source blocks old episode access; explicit regeneration selects the remaining readable chips.

Errors use the standard `{error: {code, message, requestId}}` envelope:

| Status | Code | Meaning |
| --- | --- | --- |
| 400 | VALIDATION_ERROR | Invalid day or language |
| 401 | Standard auth errors | Sign in required |
| 402 | PODCAST_POINTS_EXHAUSTED | Top up before generation |
| 404 | NOT_FOUND | Missing episode, segment or source access |
| 422 | PODCAST_EMPTY / PODCAST_TOO_LARGE | No eligible chips / more than 24 |
| 503 | PODCAST_SPEECH_UNAVAILABLE | Speech model not configured |
| 503 | PODCAST_BILLING_NOT_CONFIGURED / PODCAST_BILLING_UNAVAILABLE | Points service unavailable |
| 502 | PODCAST_FAILED | Script, speech or storage failed |

## Theme music

Episodes are produced like a show rather than read back to back, following debate-bot's Lyria music beds. The agent picks a music mood for the day: `bright`, `calm`, `focused`, `warm` or `reflective`. Each mood has three instrumental Lyria clips: an intro theme, a loopable background bed and an outro. Prompts end with a short no-vocals line (long exclusion lists trip Lyria's prompt filter) and avoid words such as host, human or conversation that invite vocals; a clip whose returned lyrics text has sung sections (verse, chorus…) is re-rolled, as is a prompt Lyria randomly blocks (`promptFeedback.blockReason`), and if every attempt sings, the episode publishes without music. The recording is laid out as follows:

1. The intro plays alone for about five seconds, then ducks under the welcome and fades out.
2. The bed loops quietly (equal-power crossfades) under the conversation. Turns about the same chip are 0.35 s apart; a change of chip leaves a 1.6 s break where the bed swells.
3. The outro enters under the last turn, rises after the sign-off and rings out.

Music levels are relative to the voices' measured RMS loudness, and peaks are soft-limited. Mixing decodes MP3 to PCM with `mpg123-decoder` (WASM) and encodes one 44.1 kHz stereo 128 kbit/s MP3 with `@breezystack/lamejs`. There is no native binary. A 5½-minute, 24-turn episode mixes in about 7 s, with a peak of about 530 MB on Node. Caption cues are the exact spoken windows, so the intro, gaps and outro sit between cues. `DailyPodcast.music` records whether music was mixed in.

Prompts describe only the mood and role, never chip content. Each clip is therefore generated once and stored under `podcast-music/<model>/`, shared by every account. The first episode that needs a missing clip pays for it (`AI_MUSIC_USD_PER_CLIP`, default $0.04 for Lyria 3 Clip); later episodes reuse it for free. Music is generated in parallel with speech. If music is not configured (`GEMINI_API_KEY` unset or `AI_MUSIC_MODEL=off`), or if generation or mixing fails, the episode is published with voices only. Older episodes are not re-mixed.

## Storage and models

Uses the existing private S3-compatible `ObjectStore` (R2 configuration), `AI_TOUR_MODEL`, `AI_SPEECH_MODEL`, speech pricing and points billing. `AI_PODCAST_VOICES` optionally lists up to four comma-separated voice IDs supported by the configured speech model. It defaults to `AI_TOUR_VOICE`. The agent chooses one to four hosts from the available voices, with a single narrator as the default configuration.

Each generation gets an immutable UUID and persists its complete script and one MP3. Individual speech turns are only transient inputs to assembly; new episodes do not store separate audio parts. Only after all audio succeeds does `latest.json` switch to the new episode. A failed generation leaves the previous episode available. Concurrent taps in the same server process share one generation; there is no distributed cross-instance lock. Old versions remain private and are retained so an open player can finish playing during regeneration.

## Verification

Route integration tests use a migrated local database, memory object store and deterministic AI provider. They exercise date selection, authorization, persistence, free reuse, concurrency and failure recovery.

The committed Postman simulation tests narration through the real AI Gateway SDK over HTTP. Its fixture derives the gateway v4 wire response from the installed SDK. It is a local contract stand-in, not a model-quality test or live cloud verification. No owning workspace mock was used. Start and run:

```sh
cd server
postman simulation run postman/simulations/daily-podcast.sim.yaml --port 4907 --output ndjson
# In another terminal:
PODCAST_SIMULATION_URL=http://127.0.0.1:4907/gateway bun run test tests/integration/podcast-http.test.ts
bun run test tests/integration/daily-podcast.test.ts
```

The focused `DailyPodcastUITests` uses the app's offline preview fixture and synthetic WAV audio. It verifies the sheet flow, captions, controls, regeneration and saved reopening, independently of cloud AI/S3 credentials.

Native media tests render an MP4 and verify one audio track, one video track, duration and changing cover/caption frames on macOS and iOS. MP3 assembly tests include generated constant/variable bitrate tones and a legacy upgrade. Live provider voice quality and cloud storage remain separate from these local checks.

## Reading while listening

The active caption offers **Open Chip**, using its saved `chipId`. The app minimizes the full player and opens that chip in the Feed navigation. Playback belongs to `AppEnvironment`, so this navigation, tab changes and expanding the player reuse the same audio session and position. The compact Liquid Glass player shows the current artwork/title/caption and provides expand, play/pause and explicit close controls. Source-loading errors leave playback running and use a native alert. Dismissing the full player minimizes it; closing the compact player or signing out stops playback.

Live captions show one short phrase at a time with content-sized height. The speech model returns no word timestamps, so phrase timing is estimated by speaking weight (digits count as longer, punctuation as none) across the turn's audible voice, and sentence and clause ends snap to the nearest measured pause. Older episodes without voice timing fall back to the cue window. On Mac, a custom player control bar overlays the top of the artwork without a navigation title or bottom sheet toolbar. The More menu groups Publish to Web, Regenerate Podcast and Download Podcast on both platforms.

## Publish to web

**More → Publish to Web** opens a dedicated sheet on iOS and macOS that works like chip share links and reuses the same SummaryKit screens (`ShareLinksView` and `ShareLinkEditorSheet` with `ShareLinkStore.podcast`). An episode starts with no links. **Add Link** opens its own sheet, which takes an optional name (only the owner sees it) and a lifetime: 1, 3, 7, 30, 90 or 365 days, or Never. Each link can be copied, edited or deleted (swipe, context menu, or the editor's Delete button; deleting asks for confirmation). An episode can have up to 20 links. Podcast links always open for anyone holding them; there is no invite-only option, because the web player is signed out. Loading, saving and deleting show overlays, and errors use a native alert.

`GET /api/v1/daily-podcasts/:key/links` returns `{items}` with the authenticated owner's links for that episode, oldest first. Each item has the same shape as a chip share link: `{id, url, label, access: "anyone", ttlDays, expiresAt, isExpired, emails: [], createdAt, updatedAt}`. `POST` accepts `{day, label?, ttlDays?}`, using the episode's original day boundaries, and returns 201. If `ttlDays` is omitted, the link gets the server's default lifetime; null means it never expires. `PATCH /links/:linkId` accepts `{label?, ttlDays?}`; a new `ttlDays` restarts the lifetime from now, which also reopens an expired link. `DELETE /links/:linkId` returns 204. Invalid TTLs or unknown fields return 400. Creating a link for another account's recording, or changing another account's link, returns 404. Creating a 21st link returns 409 `TOO_MANY_SHARE_LINKS`. Sharing never calls AI or spends points.

Each `/podcast/:token` link opens a web player with native audio seeking, timed artwork and captions, and a transcript. A link always points to the episode it was created for. Regenerating starts a new episode with no links, and the old episode's links keep working while that recording is retained. `GET /api/public/podcasts/:token` exposes only the title, language, date, duration, public audio path and display cues; chip IDs, voice configuration and storage keys stay private. `/audio` supports full responses and single HTTP byte ranges (206, or 416 for ranges that can't be satisfied). `/art/:index` serves each cue's artwork.

The page and every metadata, audio and artwork request recheck the link's expiry and the source permissions. Media responses use `private, no-store` and never redirect to long-lived public storage URLs. Missing, expired and deleted links return 404. Audio a listener has already downloaded can't be recalled. Creating a link shares the recorded content of your own private chips without changing those chips' settings. Someone else's chip must have a live public primary link: being invited to a private chip gives you the right to read it, not to republish it (403 `PODCAST_SOURCE_PRIVATE`). If a source becomes unavailable, every link to the episode stops opening, but its owner can still list and delete those links.

Database migration `0034_podcast_share_links.sql` adds the `podcast_share_links` table (a random 12-character token per link) and drops the unreleased `podcast_publications` table from `0033`. Deploy the migration with the server before releasing the app UI.
