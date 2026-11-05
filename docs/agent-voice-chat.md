# Agent Chat live voice

Tap the microphone in Agent Chat's composer to enter a voice session. The composer and transcript switch to the latest spoken response, recent tool activity, a glowing globe, an audio-level waveform, elapsed time and Stop. Stop restores the complete locally persisted transcript, including tool results. Existing chat sheets and panels are reused on iOS and macOS.

## Configuration

`AI_LIVE_CHAT_MODEL=google/gemini-3.8-live` is the default in `server/.env.example` and local `.env`. The optional extended-thinking variant is supported. The existing Gateway credential conventions apply (`AI_GATEWAY_API_KEY`, `AI_GATEWAY_KEY`, or ambient Vercel OIDC); there is no mandatory static key or direct Gemini key.

`POST /api/v1/chat/live` requires app authentication and the existing chat balance eligibility check. It mints a model-bound, single-use credential valid for opening a connection for 60 seconds. The app connects directly to Gateway using its returned WebSocket URL and subprotocols. Server credentials are never returned. Audio does not pass through a serverless HTTP upload.

Voice uses the installed AI Gateway normalized realtime protocol, PCM16 mono at 16 kHz input and 24 kHz output, Google default voice activity detection, and input/output transcription. iOS echo cancellation uses AVAudioEngine voice processing. macOS uses native device formats and capture-time playback suppression, including a 500 ms echo tail; spoken interruption is unavailable on Mac. This avoids VoiceProcessingIO aggregate-device timeouts and DSP faults observed on desktop. Interruptions clear queued output; microphone permission is requested only when starting. Stop, navigation away, connection errors, and app backgrounding release the audio graph and socket. A session ends after ten minutes and can be started again.

Voice sessions now use the same `prepareChat` tool catalog and focused instructions as text chat, plus sanitized recent conversation history. The app sends its current document, trip, graph, clip and local-file context when opening the session. Each direct tool call runs through the authenticated `/api/v1/chat/live/tool` endpoint, which rebuilds the allowed tools and rechecks access. Tool results update the existing native cards. This preserves tool validation, ownership checks and update callbacks. Direct calls no longer run a second chat-model turn; tool services retain their own billing. General spoken conversation is billed to the project's Gateway account; **direct voice usage is not yet debited from the user's Chippy points**. The token eligibility hold is released without a charge; delegated chat turns retain their normal metering. Do not treat the client session duration limit as a server-enforced spending cap.

Before calling tools, the voice model is instructed to announce the intended action aloud in the user's language. The app waits for already queued speech to finish before executing the tool. A quiet two-note cue repeats while tools are pending, pauses for assistant speech, and stops when all calls finish, fail, or are cancelled. Interruption and session teardown also silence the cue. It uses a separate local audio player, leaving the speech waveform unchanged; macOS capture suppression prevents the cue from being sent back as microphone input. Existing tool cards and mobile completion haptics remain in place. Narration is model-directed; the client does not synthesize a fallback announcement if the provider omits speech.

## Verification

Voice web research uses Gemini's built-in Google Search through a dedicated server-side Gateway request, returning grounded text and sources to the voice model. Gateway rejected native search in realtime setup (1008), so search is executed through the authenticated voice tool endpoint. Text chat retains its existing search provider and Gateway OIDC remains supported.

Run `bun run typecheck`, `bun run test tests/unit/live-chat.test.ts` from `server`, and build the `summary-chip` scheme for iOS Simulator and macOS. `bun --env-file=.env scripts/smoke-live-chat.ts` is an opt-in live provider check: it mints a credential and waits for setup acknowledgement without recording or sending microphone audio. Add `--audio` to request a short spoken greeting and verify nonempty audio frames plus response completion.

Use `--tool-narration` to check that spoken audio arrives before a tool call. This returns a synthetic empty-library result over the socket and never executes a real user tool. It checks provider event ordering, not the semantic quality of the announcement or native speaker playback. On hardware, also check the cue during slow and parallel calls, that speech remains clear, and that Stop/cancellation immediately silences feedback.

Tool-feedback validation: eight focused session/tool/route tests, TypeScript typecheck, ESLint, and the live `--tool-narration` check passed. SwiftLint reported no errors (the existing audio startup function exceeds the warning length). The modified voice code compiled for macOS and iOS Simulator; full builds failed embedded-content validation because the current project includes extensions for the opposite platform. Native cue audibility and microphone interaction still require hardware verification.

Hardware checks still required: allow/deny microphone permission, speaker echo cancellation, Bluetooth route changes, speak over an answer, perform a library search, stop during a tool call, background the app, reopen history, and start another session. Simulator compilation does not establish microphone or provider playback behavior.

Reference: https://github.com/sirily11/pet-companion (Gateway session framing and tool event presentation); https://vercel.com/changelog/gemini-3-8-live-models-now-available-on-ai-gateway.

Verified during implementation: iOS Simulator and macOS Debug builds, TypeScript typecheck, three session tests, ESLint for changed server files, SwiftLint with no errors, and a real Gateway spoken-response smoke check. Live Gateway returned audio, transcript, and response completion events. Native microphone and speaker interaction has not been exercised.

Audio startup fix: macOS logs for error -10875 showed VoiceProcessingIO rejecting mismatched client input/output formats. The main mixer now connects explicitly to the output node using the microphone format, so the 24 kHz model audio is resampled before the voice-processing output. Startup failures tear down the graph and report a readable audio-device error. Configuration notifications queued during successful startup do not end the session.

Gemini Live tool schemas use a shallow `argumentsJson` string envelope; complete argument schemas remain in tool descriptions and the server decodes and validates calls against the original contracts. Sending the original nested graph/UI schemas reproduced an upstream 1011 close; the envelope passed a live graph-catalog audio check (`--audio --graph-tools`). That check does not execute tools or read a user graph.

## RxAgentSDK integration

The Xcode project uses the published RxAgentSDK package, version 1.4.0 or later.

- Gemini uses the SDK's `GeminiVoiceEngine` and `VoiceConnection` for its gateway
  transport. Chippy retains microphone/playback, transcript rendering, tool
  execution through its authenticated API, and document refresh callbacks.
- Claude Code and Codex with local speech use `PipelineVoiceEngine`. Chippy adapts
  its Apple recognizer, utterance detector, and downloaded TTS worker to the SDK
  speech protocols. The SDK pipeline only synthesizes a completed response, so
  `LocalLiveVoiceSession` speaks each sentence as it arrives and uses the pipeline's
  call to read what's left.
- Agent text turns use SDK `ClaudeCodeClient` / `CodexClient` in the XPC runner.
  Normalized events cross XPC; the application no longer parses CLI wire events.
- Codex Realtime is a separate Mac picker option. It uses WebRTC because Codex
  only accepts a ChatGPT sign-in on that transport (WebSocket needs API key auth).
  The XPC runner runs `codex app-server` and relays the SDP answer and transcripts.
  The app owns the peer connection (`CodexRealtimePeer`), so microphone, speaker and
  echo cancellation are WebRTC's, not `LiveVoiceAudio`. It uses the installed Codex
  account and does not need a local TTS model. The API is experimental and account
  access can change, so failures point to Codex · Local Speech as the alternative.
  The realtime model delegates work to the Codex thread, which runs the MCP tools. The
  runner forwards that thread's `mcpToolCall` items, so tool cards and graph updates
  work as in the other local modes. Since `LiveVoiceAudio` isn't running here, the tool
  sound has its own output-only player (`RealtimeToolCue`). It starts with the first
  tool and stops when the thread's turn ends, and waits while the model is speaking.
  WebRTC needs `com.apple.security.network.server`; without it the sandbox makes ICE
  fail, which appears as a connection timeout.

### Test on device before release

Open Agent Chat → voice agent selection. Test Gemini, Claude Code, Codex · Local
Speech, and Codex Realtime. Check microphone permission, transcript ordering,
Chippy library tools, audio playback, interruption, stop during startup, restart,
and changing engines after stopping. Check a non-English local speech language
and a long response. Codex realtime availability depends on the installed CLI and
account. Builds and protocol tests do not establish live provider or audio-device
behavior. Local recognition/TTS and Codex modes are Mac-only; iOS and visionOS
continue to use Gemini.

The staged SDK also contains integration fixes for Gemini batched events,
function-result names and interrupted playback, plus forwarding Codex realtime
instructions. Both repositories must be included in the eventual release review.
