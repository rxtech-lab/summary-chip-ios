# Daily podcasts

The Feed's daily play button opens a dedicated player sheet. A separate generation sheet chooses the spoken language and source chips. All eligible chips are selected by default. An agent considers all selected readable summary chips on that activity day, independently of pagination and feed filters, ranks stories by importance, and omits repetitive or low-value stories. Only chosen stories become linked chips and video headings. User-triggered podcasts use the selected length as an approximate target, defaulting to six minutes. Longer scripts or recordings are accepted without shortening retries or dropping music. Automatic recaps retain their shorter three-minute budget. Owned chips use their creation date; others use their last viewed date, matching the Feed. Trips, papers, clips and generated podcast chips are excluded. Custom library podcasts retain their all-selected-chip behavior.

The player overlays host names, exact spoken captions, a seek slider and playback controls on the cover using Liquid Glass. One continuous MP3 plays the whole episode, with timed caption and artwork changes and 15-second skip controls. A dedicated download sheet saves the original complete MP3, or downloads a cloud-rendered HD MP4 with the recording, timed artwork and selectable captions. 4K exports render on device. New Version opens a creation sheet and keeps previous versions. Manage Versions opens a dedicated sheet for playback, setting the default, or removal with native confirmation. Generation and buffering use overlays; mobile interactions provide haptics.

New episodes include an AI-written summary of fewer than 200 words, grounded in the stories actually narrated. The player’s Podcast Summary toolbar button opens a dedicated reading sheet on iOS and macOS. The summary stays in the original episode language when playback is translated. For older episodes without a summary, opening the sheet generates and saves one from the recorded transcript, with an overlay, retry alert, and mobile feedback. Audio and video are preserved. Word limits use locale-aware segmentation, including unspaced Chinese and Japanese text.

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

Languages: `en`, `zh-Hans`, `zh-Hant`, `ja`, `ko`, `es`, `fr`, `de`. The response envelope is `{ "podcast": DailyPodcast }`. For backward compatibility, a saved episode is returned unchanged when `regenerate` is false and `chipIds` is omitted. Supplying `chipIds` or `regenerate: true` creates another version. Generation spends points for narration and speech; saved playback is free. App Store billing proof follows the same routing as trip tours. Request timeout: 300 seconds. Do not automatically replay an ambiguous regeneration request.

`DailyPodcast` contains `key`, `title`, `summary` (absent on legacy episodes), `language`, `createdAt`, `day`, `chipIds`, `audioPath`, `durationSeconds`, `speakers: [{name, voice}]`, and caption cues in `segments: [{speaker, chipId, caption, startSeconds, endSeconds, voiceStartSeconds, voiceEndSeconds, pauseSeconds, imagePath, icon}]`. `voiceStartSeconds`/`voiceEndSeconds` bound the audible voice inside the turn and `pauseSeconds` lists its measured pauses (≥ 150 ms), all in episode seconds; they're omitted when a turn can't be analysed. `speaker` is a zero-based index. `caption` is the exact spoken turn. `imagePath` is an optional relative authenticated chip artwork URL, with `icon` as fallback.

`GET /api/v1/daily-podcasts/:key/audio?start=<instant>&end=<instant>` returns the complete persisted MP3 with `Content-Disposition: attachment` and `private, no-store`. It never generates speech. Audio is assembled by remuxing validated MPEG Layer III frames with a complete-file Xing seek header; all voices must use compatible sample rate and channel layout. The old per-segment route remains for legacy artifacts. Episode reads never upgrade legacy audio or read episode JSON from object storage. Storage is partitioned by the authenticated account; all source chips must still be readable for metadata or audio to be returned. Deleting or revoking a source blocks old episode access; explicit regeneration selects the remaining readable chips.

Errors use the standard `{error: {code, message, requestId}}` envelope:

| Status | Code | Meaning |
| --- | --- | --- |
| 400 | VALIDATION_ERROR | Invalid day or language |
| 401 | Standard auth errors | Sign in required |
| 402 | PODCAST_POINTS_EXHAUSTED | Top up before generation |
| 404 | NOT_FOUND | Missing episode, segment or source access |
| 422 | PODCAST_EMPTY | No eligible chips |
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

On iOS and macOS, playback and MP3/MP4 export share a disk cache of complete episode audio in the app's Caches directory. Each recording expires seven days after download; listening again does not extend its lifetime. Expired files are pruned when audio is requested or cache storage is measured. Cache misses download the saved recording without generating audio. Failed or cancelled downloads are not cached, and disk-write failures leave playback available. Cache storage is included in Settings; Clear Cache and sign-out remove recordings, and removing a daily version evicts its audio. The OS may reclaim cached files earlier. Locally downloaded audio remains available until expiry or clearing even if source access is subsequently revoked on the server; metadata and new downloads still require server authorization.

Uses the existing private S3-compatible `ObjectStore` (R2 configuration), `AI_PODCAST_MODEL`, `AI_SPEECH_MODEL`, speech pricing and points billing. `AI_PODCAST_MODEL` independently selects the script and translation model (default `anthropic/claude-haiku-5.5`), including video label translation; points use that model's pricing. Scripts and spoken translations use direct statements and avoid rhetorical constructions such as “不代表……而是……” and “不是……而是……” or their equivalents in other languages. `AI_PODCAST_VOICES` optionally lists up to four comma-separated voice IDs supported by the configured speech model. It defaults to `AI_TOUR_VOICE`. The agent chooses one to four hosts from the available voices, with a single narrator as the default configuration.

Each generation gets an immutable UUID and persists its complete script and one MP3. Individual speech turns are only transient inputs to assembly; new episodes do not store separate audio parts. Only after all audio succeeds does `latest.json` switch to the new episode. A failed generation leaves the previous episode available. Concurrent requests for the same day, language and chip selection in the same server process share one generation; there is no distributed cross-instance lock. Old versions remain private and are retained so an open player can finish playing during regeneration.

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

Native media tests render an MP4 and verify one audio track, one video track, duration and changing motion frames and a selectable subtitle track on macOS and iOS. MP3 assembly tests include generated constant/variable bitrate tones and a legacy upgrade. Live provider voice quality and cloud storage remain separate from these local checks.

## Reading while listening

The active caption offers **Open Chip**, using its saved `chipId`. The app minimizes the full player and opens that chip in the Feed navigation. Playback belongs to `AppEnvironment`, so this navigation, tab changes and expanding the player reuse the same audio session and position. The compact Liquid Glass player shows the current artwork/title/caption and provides expand, play/pause and explicit close controls. Source-loading errors leave playback running and use a native alert. Dismissing the full player minimizes it; closing the compact player or signing out stops playback.

Live captions show one short phrase at a time with content-sized height. The speech model returns no word timestamps, so phrase timing is estimated by speaking weight (digits count as longer, punctuation as none) across the turn's audible voice, and sentence and clause ends snap to the nearest measured pause. Older episodes without voice timing fall back to the cue window. On Mac, a custom player control bar overlays the top of the artwork without a navigation title or bottom sheet toolbar. The More menu groups Publish to Web, New Version, Manage Versions and Download Podcast on both platforms.

## Publish to web

**More → Publish to Web** opens a dedicated sheet on iOS and macOS that works like chip share links and reuses the same SummaryKit screens (`ShareLinksView` and `ShareLinkEditorSheet` with `ShareLinkStore.podcast`). An episode starts with no links. **Add Link** opens its own sheet, which takes an optional name (only the owner sees it) and a lifetime: 1, 3, 7, 30, 90 or 365 days, or Never. Each link can be copied, edited or deleted (swipe, context menu, or the editor's Delete button; deleting asks for confirmation). An episode can have up to 20 links. Podcast links always open for anyone holding them; there is no invite-only option, because the web player is signed out. Loading, saving and deleting show overlays, and errors use a native alert.

`GET /api/v1/daily-podcasts/:key/links` returns `{items}` with the authenticated owner's links for that episode, oldest first. Each item has the same shape as a chip share link: `{id, url, label, access: "anyone", ttlDays, expiresAt, isExpired, emails: [], createdAt, updatedAt}`. `POST` accepts `{day, label?, ttlDays?}`, using the episode's original day boundaries, and returns 201. If `ttlDays` is omitted, the link gets the server's default lifetime; null means it never expires. `PATCH /links/:linkId` accepts `{label?, ttlDays?}`; a new `ttlDays` restarts the lifetime from now, which also reopens an expired link. `DELETE /links/:linkId` returns 204. Invalid TTLs or unknown fields return 400. Creating a link for another account's recording, or changing another account's link, returns 404. Creating a 21st link returns 409 `TOO_MANY_SHARE_LINKS`. Sharing never calls AI or spends points.

Each `/podcast/:token` link opens a web player with native audio seeking, timed artwork and captions, and a transcript. A link always points to the episode it was created for. Regenerating starts a new episode with no links, and the old episode's links keep working while that recording is retained. `GET /api/public/podcasts/:token` exposes only the title, language, date, duration, public audio path and display cues; chip IDs, voice configuration and storage keys stay private. `/audio` supports full responses and single HTTP byte ranges (206, or 416 for ranges that can't be satisfied). `/art/:index` serves each cue's artwork.

The page and every metadata, audio and artwork request recheck the link's expiry and the source permissions. Media responses use `private, no-store` and never redirect to long-lived public storage URLs. Missing, expired and deleted links return 404. Audio a listener has already downloaded can't be recalled. Creating a link shares the recorded content of your own private chips without changing those chips' settings. Someone else's chip must have a live public primary link: being invited to a private chip gives you the right to read it, not to republish it (403 `PODCAST_SOURCE_PRIVATE`). If a source becomes unavailable, every link to the episode stops opening, but its owner can still list and delete those links.

Database migration `0034_podcast_share_links.sql` adds the `podcast_share_links` table (a random 12-character token per link) and drops the unreleased `podcast_publications` table from `0033`. Deploy the migration with the server before releasing the app UI.

## Selecting chips, library episodes and daily versions

`POST /api/v1/daily-podcasts` also accepts `chipIds?: string[]` and `library?: boolean` (default false). An omitted daily selection means all eligible chips; an explicit empty selection returns 400. Every selected daily ID must remain readable and belong to that activity day, or generation fails with 422 `PODCAST_SELECTION` before billing/AI. Duplicate IDs are treated as one source. Each successful daily creation becomes the default and preserves earlier versions.

**New → New Podcast** and a summary's **Create Podcast** action open a dedicated sheet. **Chips** opens a searchable picker using the paginated library API restricted to `kind=summary`, with source filters. Selection survives searches and paging. A summary action preselects that chip. Creation sends `library: true` and explicit `chipIds`; sources may come from any activity day. It creates a private library chip with `kind=podcast` and returns its ID as `DailyPodcast.summaryId`. This episode does not change a daily default or appear in daily versions. `GET /api/v1/summaries/:id/podcast` returns the owner's persisted episode, rechecking the chip and every source. Opening its detail uses the existing podcast design and the app-owned audio player, which keeps playing during navigation.

New owner-authenticated endpoints (no AI or points):

- `GET /api/v1/daily-podcasts/versions?start=…&end=…` returns `{items: [{podcast: DailyPodcast, isDefault: boolean}]}`, newest first. Unreadable recordings are omitted. Documents are read directly from the database, with source permissions checked in batches across versions.
- The same URL with `chips=true` returns `{items: [{id, title, source}]}` for all readable eligible daily source chips, independent of feed filters/paging.
- `GET /api/v1/daily-podcasts/:key?start=…&end=…` opens a persisted recording.
- `PATCH` at that URL selects a daily default and returns `{podcast}`. The app switches the shared player to it and plays. Library episodes cannot become daily defaults (422 `PODCAST_LIBRARY`).
- `DELETE` at that URL removes a daily version and returns `{deleted: true}`. Its recording becomes inaccessible and its share links are revoked. If it was the default, the newest remaining readable version becomes default; no versions means `{podcast: null}`. Removed versions are retained as database tombstones.

Migration `0035_podcast_versions.sql` adds the owner/day episode catalogue and its link to library chips. Deploy it with the server before shipping the app. Recordings still live in private object storage. Default changes use a database batch. The database is the sole source for episode documents and defaults; legacy object-storage JSON is neither read, written nor imported. No legacy migration is performed. The in-process generation lock does not deduplicate across server instances.

## Motion video

Creation offers **Audio + video** (default) and **Audio only**. `POST /api/v1/daily-podcasts` accepts optional `includeVideo`; false skips the design model and its cost. Omission preserves the previous automatic-design behavior. Video design starts after speech has been transcribed and mixed, so it sees each turn's real timing and transcribed phrases. It runs on the server in the background (see [Background video design](#background-video-design)), so the generation sheet offers **Continue in Background** while it works; if the user waits, the sheet waits for the cloud render and downloads it before opening the native video player. HD rendering continues while the app is closed. Higher-resolution exports need the app in the foreground. Local failures retain the saved episode for Retry Video without regenerating audio/design. If design was unavailable, audio is retained and an explicit Retry Video can request a paid design.

Playback uses the motion MP4 whenever an episode has a video design, requesting a cloud HD render and caching its R2 download if needed. Audio-only saved episodes expose **Generate Video** in More. **Regenerate Podcast** opens the same generation sheet with Podcast / Video only options; **Download Podcast** offers MP3 and, when a design exists, MP4. There is no separate creation sheet or static-slide export fallback.

### Phrase timing and frame checks

The video agent receives every turn's real turn and voice windows and its transcribed phrases (the caption cues) with their start and end times. The server stores them with the composition as `src/phrases.json`: each turn's phrases as `[start, end]` fractions of its voice window. Fractions, not seconds, so a translation replays the same staging proportionally against its own recording; compositions from before this file get `[]`, and every turn is then a single phrase. The scaffold's `usePhrases()` extends `useNarration()` with `phrase`, `at(k)` (0–1 across phrase k) and `cue(k, seconds)` (0–1 over `seconds`, starting 0.15 s before phrase k so the picture leads the voice). Validation requires `usePhrases()`, and each storyboard turn maps phrase indexes to the actions that land on them. A story is a run of turns about one chip. At every story change the composition plays a designed bridge timed by the scaffold's `useStoryTransition()`: it starts when the outgoing voice ends and finishes as the incoming voice begins, lasting 0.9–1.6 s. The helper returns `progress`, `from`/`to` segments, `story`, `storyCount` and the bridge index. The prompt asks for an exit, a full-width bridge graphic and an entrance, a chapter marker and a story progress rail. When an episode has more than one story, validation requires `useStoryTransition()` and a `storyTransition` description on the first storyboard turn of every new story.

The agent can preview single frames with `render_frame` (16 per run). The server bundles the draft, runs it in a bounded QuickJS worker (`lib/podcast-video/frame-worker.mjs`) against a small React/Remotion stand-in, lays out the HTML with Satori, splices inline SVGs back at their measured boxes (Satori can't draw SVG text), and paints a PNG with Resvg. The tool returns the image plus measured text boxes. `submit_video` renders the settled end of every phrase, each turn's entrance, the title card and the outro (up to 48 frames). It rejects runtime errors and overlapping text, text over artwork, text cut off by the canvas, and text in the bottom 100 px subtitle band while a voice plays. On the last attempt only runtime errors still reject. Artwork is a crossed placeholder; CSS files are not applied; layout treats block elements as flex columns, so the preview approximates WebKit. CJK text uses Noto Sans SC/TC/JP/KR subsets fetched from Google Fonts for exactly the characters on screen (Han follows the episode language, kana and Hangul pick JP and KR) and cached in memory. If that fetch fails, CJK widths are estimated and the report says so.

Narration is never supplied as visible text to new compositions. The prompt calls for topic-specific motion explanations (animated flows, progressive paths, moving objects and transformations), and validation rejects caption helpers/transcript access. The MP4 receives a selectable tx3g subtitle track timed to voice windows and pauses; captions are not rasterized into frames. Legacy caption helpers receive empty narration when re-rendered. Previously downloaded/published MP4s are unchanged until regenerated and republished.

HD video uses Vercel Workflow and a snapshot-backed Sandbox container with Remotion/Chromium and FFmpeg. The vendored `Packages/RxRemotion` handles 1440p and 4K exports in WebKit and AVFoundation. The app injects actual segment timing, artwork and chip titles. Only on-device exports require the app to stay open; action progress appears in an overlay. Completed renders are cached per episode and design, included in Settings cache storage, and removed by Clear Cache or sign-out. A failed render does not publish a partial movie.

Publish Video renders if needed, uploads the MP4 using an authenticated presigned upload ticket, then confirms publication. Existing web share links play that video. Remove Published Video asks for native confirmation and returns those links to audio. Creating a new design also removes the previous publication. The sheet updates episode metadata without resetting the audio playback position.

The owner video API is under `/api/v1/daily-podcasts/:key/video`: GET reads composition source with the saved day boundaries; POST creates a replacement; POST `/upload` issues a ticket for the current `videoId` and `byteSize`; POST `/publication` confirms it; DELETE `/publication` removes it. Stale design IDs return 409. Public video requests validate the share link and source access before issuing a storage redirect; the resulting URL remains valid for up to one hour, including after link revocation.

`GET /video/publication?start&end&language=xx` authenticates the owner and returns
`{videoId, downloadUrl}` for the current published composition, with `Cache-Control: no-store`.
The signed URL lasts one hour. Missing publications, replaced compositions, foreign episodes
and missing translations return 404; no public share link is required. Native playback and
video exports reuse a cached MP4 first, otherwise download the matching published MP4 to
that cache, and request private cloud renders for HD playback/export. 4K export renders from the saved source on device. The client checks
the video ID and downloaded byte size. Download errors are surfaced without starting a render.
Deploy the server endpoint before releasing the updated app.

Local validation for the motion-video integration includes eight server lifecycle/agent tests with deterministic providers and a native one-second render test on macOS and iOS Simulator. The native check verifies one audio track, one video track, duration, dimensions and changing frames. It caught an iOS viewport mismatch, fixed by keeping the WebView as a sized child of the window controller and declaring a mobile viewport. These checks do not establish live model quality, physical-device render performance or production uploads.

### Live generation progress

`POST /api/v1/daily-podcasts` accepts `Accept: text/event-stream`. Authentication,
input validation and billing-environment validation happen before the stream opens.
Clients omitting this header continue to receive `{ "podcast": ... }` JSON.
Each SSE event is a single JSON `data:` line:

- `{"type":"progress","progress":{"stage":"speech","percent":45,"completedSegments":1,"totalSegments":2}}`
- `{"type":"complete","podcast":{...}}` is the terminal successful result.
- `{"type":"error","status":502,"error":{"code":"PODCAST_FAILED","message":"...","requestId":"..."}}` is a terminal failure after HTTP headers were sent.

Stages are preparing (0%), script (5%), speech (20–70%, based on completed voice
segments), music (70%), mixing/caption alignment (75%), saving (95%), video-design (97%, when the background design starts)
and complete (100%). The stream completes once the recording is saved; the episode's `videoDesign` then reports the video. These are estimated work weights, not elapsed-time estimates;
AI calls can leave a stage unchanged for a while. Music starts alongside speech;
video design follows mixing, because it is staged on the transcribed phrases. Optional fallbacks still
allow the recording to finish. 100% follows successful saving and billing settlement.
Comments every ten seconds keep idle streams active. Concurrent requests within the
same server process share generation and replay the latest progress to new observers.
Disconnecting stops delivery, not the underlying generation; clients never automatically
retry an interrupted paid POST. Reopen the podcast to check whether it was saved.

The app shows live progress in the existing full-height generation sheet's overlay,
with a numeric percentage and exact voice-segment count. It accepts legacy JSON from
the same request when talking to an older server (spinner only), without resubmitting.

Video design creation (`POST /api/v1/daily-podcasts/:key/video`) starts a background design and
returns `{podcast}` at once with its `videoDesign`. Current apps poll the episode (`GET /api/v1/daily-podcasts/:key`, free)
every three seconds. Older apps that send `Accept: text/event-stream` get the same envelope: preparing (0%), then
video-design (10–90%) read from `videoDesign` every two seconds, and complete (100%) when the design is saved. A failed design ends the stream
with its error. The stream stops following after 270 s and returns the episode as it is; the design continues.

### Background video design

The design agent runs as a Vercel Workflow (`workflows/design-podcast-video.ts`), not inside the request, so it never
hits the function timeout and the user can leave the app. Each agent turn is one workflow step that makes exactly one
tool call: one small `write_file` (at most 16,000 characters), one `edit_file`, one `render_frame` or one
`submit_video`. Extra tool calls in the same turn are not run and return a message asking the model to send them again.
After every turn the step saves the draft (files, conversation, attempt and preview counts, cost) to
`<episode>/video-design/<id>.json`, so a crash or redeploy resumes from the last turn. A turn has a 240 s timeout.
Three failed model calls in a row end the run, as do 5 rejected submissions or 64 turns.

The episode document carries `videoDesign: { id, startedAt, updatedAt, percent, language?, error? }` while a run
works on it. Starting a design while one is running returns the running one; a run that saved nothing for 20 minutes is
stale and can be replaced. A newer run makes the older one stop at its next turn. When the run is accepted, the
composition replaces the previous one, as before: published renders and translation videos are removed. Then
`videoDesign` is cleared, or kept at 92% while a requested translation's labels are translated. A failed run
keeps `videoDesign.error` until the next design starts; the app then shows Retry Video or Generate Video.

Billing: `POST /video` checks the balance with a hold it releases at once. The run's token cost is charged once, when it
ends, with an idempotent hold and settlement (`<key>:video:<id>:charge`). A failed design is free. Designs started from
episode creation are charged separately from the recording.

The podcast sheet follows a running design with a non-blocking status capsule ("Designing video… 42%"). When the
design finishes, the sheet switches to the video and waits for its cloud HD render. If audio is playing, it shows
**Video Ready – Watch** instead, so listening isn't interrupted. More shows a disabled **Designing Video…** item while a
run works.

### Decision-model video progress

Video design consumes the agent's live text/tool-input stream and validation evidence.
The configured `AI_EVALUATION_MODEL` (default `typesafe-ai/jev`; `off` disables it)
judges bounded composition milestones through AI SDK's evaluation API. Calls are
single-flight, at most once per three seconds, with a four-second timeout and no
retries. Only the latest 12,000 characters of generated output are included;
raw output is never sent to the client. A failed evaluation retains the last
estimate. No elapsed-time or step-count increment is used for video design.

The composition estimate is mapped to the existing SSE `video-design` stage
budget (10–82%), evaluated once per background turn from that turn's tool call and outcome. These are work estimates, not time remaining. Saving and completion are
emitted only by the service; local frame rendering continues to use real frame
counts. Evaluation requests use the existing Gateway credentials and incur
provider usage. The existing native overlay consumes the unchanged SSE contract.

### Transcribed caption timing

New podcasts transcribe each generated voice turn through AI Gateway using
`AI_TRANSCRIPTION_MODEL` (default `mistral/voxtral-mini-transcribe-3`) and the existing
Gateway credentials. Segment timestamps are requested explicitly. Edit alignment
maps recognized text back to the original script to correct spelling and omissions;
all displayed caption punctuation is removed, including apostrophes and hyphens.
The original script remains intact for narration and transcript reading.

`segments[].captionCues` contains `{ text, startSeconds, endSeconds }` in episode
seconds, offset by the mixer's voice positions so intro music and interludes do not
shift captions. Playback and MP4 subtitle export use the same cues and leave silence
gaps empty. Voxtral supplies segment timing, not word timing. Long segments advance through pages of at most two short lines without dropping text. Page timing is estimated within each transcribed segment; its outer boundaries and silence gaps stay unchanged. Older episodes without cues retain legacy estimated timing;
regenerate them to obtain transcribed timestamps. Empty, invalid, overlapping or
substantially mismatched transcripts fail new generation rather than publish guessed
caption timing. Calls use the generation deadline, a 45-second per-call timeout and
no automatic transcription retries.

Local verification: `bun run test tests/unit/podcast-captions.test.ts` and the existing
Postman daily-podcast simulation with `PODCAST_SIMULATION_URL` exercise alignment
and the SDK HTTP contract. These fixtures do not establish live Voxtral accuracy.

The Download Podcast sheet also offers **Captions (SRT)** for audio-only and video episodes. This exports UTF-8 subtitles with episode timestamps through the native file picker, using the same punctuation-free cues as MP4 export without fetching audio or rendering video.

## Translations

An episode version can be spoken in more languages. **More → Translate…** opens the Languages sheet. It lists the episode's languages, original first, with a checkmark on the one playing. Tap a language to switch to it. Swipe or open the context menu on a translation to remove it, with native confirmation. **Add Translation** opens its own sheet with a language (only languages the episode doesn't have yet) and Media (Audio + video / Audio only, when the episode has a video). Translation spends points; its progress uses the same overlay as generation, followed by local video rendering. Once an episode has more than one language, **More → Language** switches directly.

Turns are translated one for one, keeping the original's speaker, chip, artwork and order, and are then voiced with the same hosts. Each turn is transcribed for caption timing and mixed with the same theme music (only when the original had music). Switching language therefore resumes playback at the start of the same turn. The app remembers the last language chosen and opens episodes that have it in that language. The video reuses the original composition: the same scenes are driven by the translation's own timings from `data.json`, with translated chip titles, and a model pass translates on-screen labels as exact, unique text edits. Edited files must pass the same validation as a new video. Otherwise the translation keeps the original labels. Captions are never drawn into frames, so the translated subtitle track carries the narration.

Translations belong to an episode version. Regenerating creates a new version with no translations, and removing a version also removes access to its translations. Writing a new original video design removes every translation's video (and its published render). A translation's **Generate Video** then rebuilds it from the current design. If the original has no video yet, it is designed first by the same background run, which then translates the labels.

### API

Every owner read that returns an episode presents one language. The response's `language` is the presented language, `originalLanguage` is the one it was generated in, and `languages` lists every available language, original first. Stored translations are never sent. All episode and media endpoints accept an optional `language` (a query parameter for reads, a body field for writes). When `language` is omitted or equals the original, the request uses the original recording. A missing translation returns 404 `PODCAST_TRANSLATION_MISSING`, except on the daily `GET` and library-chip `GET`, which fall back to the original. A translation keeps the episode's `key`, `day`, `chipIds`, `mood` and `createdAt`. Its own `title`, `speakers`, `segments` (with `captionCues`), `audioPath` (`…/audio?start&end&language=xx`), `durationSeconds`, `music` and `video` replace the original's.

- `POST /api/v1/daily-podcasts/:key/translations` with `{day, language, includeVideo?}` translates the episode and returns `{podcast}` in that language. It supports the SSE progress envelope, with an extra `translating` stage (5%). An existing translation is returned without AI or points. Translating into the original language returns 422 `PODCAST_TRANSLATION_SAME`. Failure returns 502 `PODCAST_TRANSLATION_FAILED` and leaves the episode unchanged. Concurrent requests for the same episode and language share one translation in the server process.
- `DELETE /api/v1/daily-podcasts/:key/translations/:language?start&end` removes the translation's recording, composition and published render, and returns the episode in its original language.
- The video endpoints (`GET`/`POST /video`, `POST /video/upload`, `GET`/`POST`/`DELETE /video/publication`) act on the requested language's composition and render. `POST /video` with a translation `language` translates the current original composition (designing one first when missing).

Storage is under the episode: `translations/<language>/audio.mp3` and `translations/<language>/video.json`. Translations are stored in the episode document (`translations` keyed by language). Writers merge into the latest stored document, so a translation finishing during a video design (or the other way round) is kept. No migration is required.

Web share links stay tied to the episode. `/podcast/:token?language=xx` plays a translation, and the player shows a Language menu when the episode has more than one. `GET /api/public/podcasts/:token?language=xx` returns `language`, `languages` and media paths carrying the same `?language=`. A language the episode doesn't have falls back to the original. Each language's video plays only when that language's render is published.

## Library podcast versions

Regenerating a library podcast no longer creates another podcast chip. The app sends `summaryId` with `library: true`, and the new recording becomes a version of the same chip. The chip's title, summary text and language follow the newest version, and the chip opens that version. `summaryId` must be the caller's own `kind=podcast` chip (404 otherwise; 400 without `library`). **Manage Versions** is available for library podcasts too: `GET /api/v1/daily-podcasts/versions?summaryId=<id>` lists them newest first, and `PATCH`/`DELETE /api/v1/daily-podcasts/:key?start&end` (using that version's own day) chooses the version the chip opens or removes one. A chip's last version can't be removed (422 `PODCAST_LAST_VERSION`): delete the chip instead. Library defaults are kept apart from the day's daily default. Chips created before this change open their newest version.

### Background jobs and completion notifications

Video script design is a durable server workflow. Feed and podcast toolbars open
**Background Jobs**, a full-height sheet with a navigable job detail and activity
log, refreshed every three seconds while active. Closing the app does not stop
script writing or HD rendering. Watch HD Video opens a dedicated full-height sheet;
its progress is an overlay and the finished R2 download is cached locally. 4K export
uses the Download sheet and must remain in the foreground.

Authenticated, owner-only API (no billing, `Cache-Control: no-store`):

- `GET /api/v1/background-jobs?cursor=<job-id>` returns `{items, nextCursor}`,
  newest first, 50 per page. Cursor belongs to the same owner. Deleted episodes
  are excluded. `nextCursor: null` ends pagination.
- `GET /api/v1/background-jobs/:id` returns `{job}` or 404 for a missing/foreign
  job. Each job has `id`, `title`, `episodeKey`, `day: {start,end}`, optional
  `language`, `status: running|ready|failed`, `percent`, ISO timestamps, optional
  `videoId`, and `logs: [{id, at, message}]`. Logs retain up to 200 bounded activity
  entries; they do not include model conversations. Terminal jobs survive app
  restarts. A running job silent for 20 minutes is displayed as needing attention.
- `videoId` identifies the exact script. A superseded job cannot silently render
  the newer composition. Open the latest job instead.

Migration `0040_background_jobs` must run before deployment. Jobs cascade on
account/episode deletion. Ready and failed workflows send the existing APNs
installations a `backgroundJobId` and `userId`; tapping routes to that job only
for the matching signed-in account. The ready alert opens the podcast for playback
or download. Delivery is claimed at most once per job, like paper notifications;
APNs permission/configuration and OS delivery still apply. A lost push does not
lose the durable job. Notification settings are accessible from the jobs sheet.

### Remembered speaker settings

The iOS/macOS generation sheet includes a dedicated Speakers sheet. Automatic lets the model choose hosts; custom mode accepts one to four ordered names (1–40 characters each). Starting generation saves speaker names, language, and audio/video preference in local app storage for the next generation. Source-chip selection remains specific to each episode. Video-only retries do not overwrite these preferences.

`POST /api/v1/daily-podcasts` accepts optional `speakerNames: string[]`. Names are trimmed and validated; omission preserves automatic naming. The script must use the exact requested names and order. Requests exceeding the configured distinct voice count fail before reserving points. The names also participate in in-flight request deduplication.

### Published episode previews and companion articles

Creating a podcast share link prepares and persists a 1200×630 illustrated cover and
an AI-written companion article before returning the URL. The article synthesizes the
recording into prose rather than displaying a transcript. Each section references a
validated segment index; the web player displays its recording timestamp and clicking
it seeks and starts the selected audio or published video. Translated articles use the
selected language's recording and timing. Existing links generate missing assets on
first access. Stored assets are content-addressed sidecars, so no database migration
is needed and concurrent video/translation saves cannot overwrite them.

The page emits episode-specific title, description, Open Graph and Twitter large-card
metadata. `GET /api/public/podcasts/:token` adds `coverPath` and nullable `article`
(`description`, `sections` with `heading`, `paragraphs`, `segmentIndex`, `startSeconds`).
An article-generation failure leaves playback available and retries on a later visit.
`GET /api/public/podcasts/:token/cover?language=xx` returns the PNG. Both endpoints,
including requests by preview crawlers, accept a live token without sign-in, even for
a private library podcast. They recheck link expiry/deletion and source access on every
request and send `private, no-store`; storage keys and bucket URLs are never exposed.
The page stays `noindex` so unlisted links aren't advertised for search indexing.

### Video download resolution

The native Download Podcast sheet defaults video exports to 1080p and offers 720p, 1440p, and 4K (3840 × 2160). HD exports (720p/1080p) use cloud renders stored in R2. 1440p and 4K always render from source on device. The selected resolution applies to both Files and Photos. Higher resolutions render the animation source at the selected pixel density while preserving its layout and timing; selectable subtitles scale with the output. Private cloud HD outputs are independent of web publication; rendering does not create a share link. Each resolution is cached separately. Higher resolutions require more rendering time and storage.

### Source chip navigation

The player toolbar opens a Linked Chips sheet listing each distinct source chip. Opening a chip leaves audio playback with the shared player. A source chip's Watch Podcast toolbar action opens a dedicated list of its saved video episodes, including older versions, and opens the selected episode in the existing video player.

`GET /api/v1/summaries/:id/podcasts` requires bearer authentication and returns `{ items: DailyPodcast[] }`, newest first, with `Cache-Control: private, no-store`. Only the caller's nondeleted episodes with a saved video and this source ID are returned. All source chips and the podcast chip must still be readable. Missing/inaccessible source chips return 404; a readable chip with no matching video returns an empty list. This lookup performs no generation and needs no migration.

### Cloud video rendering and setup

New accepted compositions automatically queue a private 1080p render. This includes
built-in designs, MCP draft submission, and translated compositions. The audio and
source stay usable if renderer setup is missing. Render failures appear in job history
and can be retried explicitly. Forked versions keep source but do not inherit render jobs.

- `POST /api/v1/daily-podcasts/:key/video/render`: `{day, language?, resolution?}`;
  resolution is 720 or 1080, default 1080. Starts or reuses a render of the current
  composition. Other sizes are rejected; export 4K using the native Download sheet.
- `GET` on the same path: `start`, `end`, optional `language` and `resolution` query.
  Read-only; returns `{videoId, render, downloadUrl?}`. `render` is null or has an id,
  status (`running`, `ready`, `failed`), resolution, updatedAt, optional byteSize/error.
  Ready URLs expire in ten minutes. Both endpoints are authenticated, owner-scoped and
  no-store. Source replacement fences stale completion and retires its uploaded output.
- Rendering uses a detached container process. Short durable workflow steps poll it,
  then upload the validated MP4 to R2 and check its content type and exact size.
  Containers have a one-hour deadline and are stopped when the workflow finishes.
  Agent compositions run without account/storage credentials and with network denied;
  upload receives only a scoped, short-lived PUT capability. No per-episode snapshots.
- MP4 validation checks dimensions, duration, audio, subtitles and decoding a video frame.
  Web publication is still an explicit action in its own sheet.

Before deployment, authenticate the Vercel Sandbox SDK with project OIDC (deployments)
or `VERCEL_TOKEN`, `VERCEL_TEAM_ID`, `VERCEL_PROJECT_ID` (local operator setup).
From `server`, run `bun scripts/prepare-podcast-renderer.ts`. It installs pinned
Remotion/Chromium, FFmpeg and fonts in a clean container, warms Chromium and creates
a reusable snapshot. Set the printed `PODCAST_RENDER_SNAPSHOT_ID` in Vercel. An optional
`PODCAST_RENDER_IMAGE` selects a prebuilt Vercel Container Registry image; the Dockerfile
is `server/podcast-renderer/Dockerfile`. Rebuild the snapshot for renderer updates.
R2 uses the existing server configuration. The feature needs no database migration.

Set `PODCAST_RENDER_SNAPSHOT_ID` on the **Production** environment, then redeploy
the production revision to activate it. A value in a local `.env` does not configure
deployed workflows. If a render fails within seconds without a `rendering` job log,
check Vercel workflow launch logs and the snapshot setting first. Keep a tool-capable
fallback in `AI_PODCAST_VIDEO_MODEL` (a comma-separated list) when a configured model
returns text without calling the design tools.

After repairing production configuration, retry the existing composition with
`render_podcast_video`; redesigning the episode is unnecessary. Existing failed job
history is retained.

Local evidence: server lifecycle/authorization tests, a real one-second 1080p
Remotion/FFmpeg render, iOS Simulator compilation, and native-client download tests
against the Postman fixture. This does not establish a live Sandbox render, R2
upload, deployed workflow execution, or physical-device 4K performance.


## Automatic daily recap videos

Settings → Daily Recap opens a dedicated iOS/macOS sheet. Enable the account schedule,
choose a language and hour, and save. The default is 07:00 in the device's IANA time zone,
covering the previous local calendar day. The saved zone remains fixed until changed in
settings. Vercel Cron checks due schedules every five minutes; the selected hour starts
generation, rather than promising the finished video at that instant. The app can stay closed.

Every eligible summary chip is supplied as context. Recaps rank selected stories by significance, impact, usefulness and relevance, then
narrate them in descending importance. Unimportant or repetitive chips can be omitted
even when time remains. Only selected chips appear in the episode’s linked sources and
video headings. Generated podcast chips are excluded from candidates. The target is
about two minutes.
Narration is limited to 250 words / 500 Chinese or Japanese characters before speech.
The mixed recording must be at most 175 seconds, leaving room for video timing; the
trusted cloud runner rejects compositions or measured MP4s longer than 179 seconds.
Over-limit episodes are rejected rather than silently cut mid-sentence. Ordinary manual
podcasts keep their existing full-coverage behavior.

Each successful generation becomes that day's default podcast and queues the existing
video design workflow, then a private 1080p cloud render in R2. Watch it from the selected
day in the Feed. Progress and completion notifications use the existing Background Jobs
and APNs flow once video design starts. Publication to the web remains explicit.

`GET /api/v1/daily-recap` reads the owner's settings, next run and latest outcome.
`PUT` saves `{enabled, timeZone, language, hour}`. The verified billing environment is
saved with the schedule and propagated to background generation; normal podcast points
apply. These endpoints require bearer authentication and return no-store responses.

Migration `0043_daily_recaps` creates schedules and unique owner/local-date run claims.
The secret-authenticated `/api/cron/daily-recaps` dispatches at most 20 due accounts per
invocation, oldest schedule first. Empty days, disabled schedules, and accounts pending
deletion skip generation. Enabling does not backfill history. Failed or ambiguous starts
and billable generation steps are not replayed automatically; the settings sheet reports
an outcome and the owner can generate manually from that day. An interrupted run needs
attention after 15 minutes. The next day proceeds independently. New accounts are off
until they enable their schedule.

Deployment requires the migration, the new cron configuration and `CRON_SECRET`, the
existing AI/points configuration, and the configured cloud renderer snapshot and R2.
Local scheduler/mock-provider tests and app builds do not establish a completed live
scheduled render or activate a user's account schedule.

### Summary backfill

`POST /api/v1/daily-podcasts/:key/summary` accepts `{ day, language? }` and returns `{ podcast }` in the requested playback language. The summary is generated in the original language and validated to fewer than 200 words. Requires owner/source access and billing proof for generation; existing summaries are returned without a model charge. Concurrent requests in the same process share generation. Failures leave the episode unchanged and may be retried explicitly.

### Episode length

The generation form offers a dedicated Length sheet: Long (6:00), Medium (3:00),
Short (1:30), Clips (0:30), or a custom duration from 0:30 to 30:00 in one-second
increments. Presets, limits, and the default come from the generation options
endpoint. The selection is saved on the device when generation starts.

`POST /api/v1/daily-podcasts` accepts optional integer `durationSeconds` (30–1800).
It guides the approximate narration length; the video follows the actual recording.
The finished episode may be shorter or longer. Duration-targeted library
podcasts select highlights when needed to fit the budget. Video-only retries reuse
the recording; changing length requires regenerating the podcast. Automated daily
recaps retain their stricter limit below three minutes.
