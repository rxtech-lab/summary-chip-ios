# Agent Chat live voice

Tap the microphone in Agent Chat's composer to enter a voice session. The composer and transcript switch to the latest spoken response, recent tool activity, a glowing globe, an audio-level waveform, elapsed time and Stop. Stop restores the complete locally persisted transcript, including tool results. Existing chat sheets and panels are reused on iOS and macOS.

## Configuration

`AI_LIVE_CHAT_MODEL=google/gemini-3.8-live` is the default in `server/.env.example` and local `.env`. The optional extended-thinking variant is supported. The existing Gateway credential conventions apply (`AI_GATEWAY_API_KEY`, `AI_GATEWAY_KEY`, or ambient Vercel OIDC); there is no mandatory static key or direct Gemini key.

`POST /api/v1/chat/live` requires app authentication and the existing chat balance eligibility check. It mints a model-bound, single-use credential valid for opening a connection for 60 seconds. The app connects directly to Gateway using its returned WebSocket URL and subprotocols. Server credentials are never returned. Audio does not pass through a serverless HTTP upload.

Voice uses the installed AI Gateway normalized realtime protocol, PCM16 mono at 16 kHz input and 24 kHz output, Google default voice activity detection, and input/output transcription. iOS echo cancellation uses AVAudioEngine voice processing. macOS uses native device formats and capture-time playback suppression, including a 500 ms echo tail; spoken interruption is unavailable on Mac. This avoids VoiceProcessingIO aggregate-device timeouts and DSP faults observed on desktop. Interruptions clear queued output; microphone permission is requested only when starting. Stop, navigation away, connection errors, and app backgrounding release the audio graph and socket. A session ends after ten minutes and can be started again.

Voice sessions now use the same `prepareChat` tool catalog and focused instructions as text chat, plus sanitized recent conversation history. The app sends its current document, trip, graph, clip and local-file context when opening the session. Each direct tool call runs through the authenticated `/api/v1/chat/live/tool` endpoint, which rebuilds the allowed tools and rechecks access. Tool results update the existing native cards. This preserves tool validation, ownership checks and update callbacks. Direct calls no longer run a second chat-model turn; tool services retain their own billing. General spoken conversation is billed to the project's Gateway account; **direct voice usage is not yet debited from the user's Chippy points**. The token eligibility hold is released without a charge; delegated chat turns retain their normal metering. Do not treat the client session duration limit as a server-enforced spending cap.

## Verification

Voice web research uses Gemini's built-in Google Search through a dedicated server-side Gateway request, returning grounded text and sources to the voice model. Gateway rejected native search in realtime setup (1008), so search is executed through the authenticated voice tool endpoint. Text chat retains its existing search provider and Gateway OIDC remains supported.

Run `bun run typecheck`, `bun run test tests/unit/live-chat.test.ts` from `server`, and build the `summary-chip` scheme for iOS Simulator and macOS. `bun --env-file=.env scripts/smoke-live-chat.ts` is an opt-in live provider check: it mints a credential and waits for setup acknowledgement without recording or sending microphone audio. Add `--audio` to request a short spoken greeting and verify nonempty audio frames plus response completion.

Hardware checks still required: allow/deny microphone permission, speaker echo cancellation, Bluetooth route changes, speak over an answer, perform a library search, stop during a tool call, background the app, reopen history, and start another session. Simulator compilation does not establish microphone or provider playback behavior.

Reference: https://github.com/sirily11/pet-companion (Gateway session framing and tool event presentation); https://vercel.com/changelog/gemini-3-8-live-models-now-available-on-ai-gateway.

Verified during implementation: iOS Simulator and macOS Debug builds, TypeScript typecheck, three session tests, ESLint for changed server files, SwiftLint with no errors, and a real Gateway spoken-response smoke check. Live Gateway returned audio, transcript, and response completion events. Native microphone and speaker interaction has not been exercised.

Audio startup fix: macOS logs for error -10875 showed VoiceProcessingIO rejecting mismatched client input/output formats. The main mixer now connects explicitly to the output node using the microphone format, so the 24 kHz model audio is resampled before the voice-processing output. Startup failures tear down the graph and report a readable audio-device error. Configuration notifications queued during successful startup do not end the session.

Gemini Live tool schemas use a shallow `argumentsJson` string envelope; complete argument schemas remain in tool descriptions and the server decodes and validates calls against the original contracts. Sending the original nested graph/UI schemas reproduced an upstream 1011 close; the envelope passed a live graph-catalog audio check (`--audio --graph-tools`). That check does not execute tools or read a user graph.
