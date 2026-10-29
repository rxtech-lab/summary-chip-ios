# Daily podcast simulation

Updated 2026-10-25. The committed gateway fixture derives from the installed
`@ai-sdk/gateway` adapters; it is a local contract stand-in, not a captured provider.

## Purpose

Exercise the real gateway HTTP client during durable video design. See
`tests/integration/podcast-video.test.ts` and `mocks/podcast-gateway/default.js`.

## Execution

From `server`, start `postman simulation run postman/simulations/daily-podcast.sim.yaml --port 4938 --output ndjson`.
After its `listening` event, run
`PODCAST_SIMULATION_URL=http://127.0.0.1:4938/gateway bun run test -- tests/integration/podcast-video.test.ts tests/integration/background-jobs.test.ts`.
Stop that simulation process after testing.

## Assumptions

- APNs, real model quality, deployment and device rendering are outside this
  simulation (observed 2026-10-25). Database/storage test fixtures remain local.

## Observations

<!-- begin:observations -->
2026-10-25: Success and hanging-response runs reached the gateway member;
the real SDK's 300 ms deadline produced a job timeout error at 10%, then a
successful turn cleared it. The member served all modeled traffic; none was silent.
2026-10-25: The gateway member served a successful `/language-model` request;
all 11 video integration tests passed with the HTTP case enabled. No member was
silent. The HTTP test now drives the real single-turn agent used by workflow steps.
<!-- end:observations -->

## What didn't work

- 2026-10-25: The stale handler answered 500 on `/language-model`: it expected
  `episode.segments` and streamed responses. The current prompt uses `turns`,
  requires phrase actions, and uses JSON generation responses. The fixture now
  matches those contracts; the rerun passed.

2026-10-25: The fixture also accepts companion-article prompts with indexed segments.
The article HTTP test exercises structured output through the real Gateway SDK.
Speech fixture MP3s now preserve spoken text in an ID3 title, matching the local
transcription fixture used by the existing streamed-generation integration test.

2026-10-27: Summary backfill uses the real gateway HTTP adapter against the transcript fixture. All 34 focused podcast tests passed with the simulation enabled, including persisted summaries, reuse, access denial, invalid output, and provider failure. Updated the script fixture with required summary and recap ranking fields. This does not verify live model quality.

2026-10-28: Plan preparation uses the real gateway HTTP adapter with per-turn camera directions. The plan and HTTP integration suites verify persisted storyboard output before media generation; the broader five-file run passed 101 tests. The gateway member served language, speech, transcription, and video calls; no member was silent. This proves the local contract and review gate, not live model quality or device interaction.
