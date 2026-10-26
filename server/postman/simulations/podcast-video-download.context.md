# Published podcast download simulation

Updated 2026-10-26. Local fixtures model the owner download-ticket contract in
`docs/daily-podcasts.md` and signed storage GETs; they do not contain a playable MP4.
The native `SummaryAPIClient` runs for real. Server authorization is checked separately
by `podcast-video.test.ts` and `podcast-translation.test.ts`.

From `server`, start:
`postman simulation run postman/simulations/podcast-video-download.sim.yaml --port 4942 --no-history --output ndjson`.
After the listening event, from `Packages/SummaryKit`, run:
`PODCAST_DOWNLOAD_SIMULATION_URL=http://127.0.0.1:4942/media swift test --filter PublishedPodcastVideoTests`.
Stop the simulation after testing. The test is skipped without that environment variable.

2026-10-26: The native test passed. The media member served three authenticated ticket
requests and two storage downloads. The successful four-byte download completed byte
progress; a replaced video ID was rejected before a storage request; a two-byte file
was rejected against the four-byte publication size. Storage rejects account bearer
tokens, and the success path passed. No member was silent.

The initial fixture used `listen(0)`, which left the simulation forwarding to an unused
port (502). It must listen on `process.env.PORT`, as Postman assigns the member port.
Live R2, playback of an actual MP4, deployment and physical-device behavior are unverified.
