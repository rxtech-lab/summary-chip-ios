# macOS support

Chippy runs natively on macOS 26 and later. Open `summary-chip.xcodeproj`, select the **summary-chip** scheme, and run on **My Mac**. The same app target and scheme support iOS devices and simulators. The **summary-chip-macOS** scheme builds this shared target and selects the Mac test suites.

The Mac app uses a sidebar for Library, Chat, and Settings. Toolbar Search (also available with Command-K) opens a focused overlay over the current screen; close it with Escape, the close button, or a click on the backdrop. New Summary (also available with Command-N), filters, sharing, image regeneration, account deletion, and summary deletion have dedicated sheets. Creation options use a separate navigation destination. The feed adjusts its column count as the window changes size.

The app includes native clipboard copying, the macOS system sharing picker, security-scoped PDF import, drag-and-drop summary creation (drop a PDF, text or Markdown file or a web link on the window, or a file on the Dock icon or via Finder’s Open With, to open New Summary with it), welcome onboarding, and Siri/Shortcuts actions. Long-running intents use the macOS 27 API when available and the existing generation path on macOS 26.

**Settings → General → MCP Server** manages the API keys AI agents use with the hosted MCP server (`/api/mcp`) to add, search and list summaries; see [MCP server](mcp.md). The same sheet is under Settings → Integrations on iOS. The app itself runs no server.

`MacSmartShare` is the bundled macOS share extension. It accepts web links, PDFs, and text, and uses the same generation flow as the main app. Sign in to the containing app first, then choose Chippy in Safari’s Share menu. macOS may require enabling the extension in System Settings before it appears.

## Configuration and signing

The app and Mac share extension reuse `Configuration/Debug.xcconfig` (localhost API) and `Configuration/Release.xcconfig` (production API), including the existing public OAuth client and `summarychip://oauth/callback`. They use the same app bundle identifier, app group, and keychain access group as iOS. The app, extensions, and tests use Rxlab LIMITED’s team (`T7GYB573Y6`) with automatic signing and the Apple Development identity. Provisioning must include the shared groups and associated domains. The app enables sandboxing, outgoing network connections, and read-only access to user-selected files.

The `summary-chip` target supports iOS and native macOS. Dependencies use `destinationFilters`: `MacSmartShare` is built and embedded only for macOS; `SmartShare`, `SummaryMessages`, and `SummaryClip` only for iOS. SDK-conditioned build settings select the Mac app icon, sandbox entitlements, Info.plist, signing identity, and framework search path. Mac app configuration files are maintained in `summary-chip-macOS/`; targets, schemes, and other generated plists and entitlements are defined in `project.yml`. Regenerate with `xcodegen generate` after changing the spec. Existing local Xcode signing overrides may need to be reapplied after regeneration.

## Validation

For Developer ID distribution, Sparkle updates, release credentials, and GitHub Pages/Cloudflare setup, see [macOS signing and updates](macos-updates.md).

Build the Mac app and extension without distribution signing:

```sh
xcodebuild -project summary-chip.xcodeproj -scheme summary-chip \
  -configuration Debug -destination 'platform=macOS' \
  build CODE_SIGNING_ALLOWED=NO
```

Run the shared package tests with `swift test` in `Packages/SummaryKit`. The Mac scheme also includes the app unit tests and `summary-chip-macOSUITests`, which check sidebar navigation, creation sheets, and welcome page progression. UI tests require macOS to allow Xcode UI automation. Debug launch arguments `--preview-mac` and `--preview-education` allow UI review without a live account; they do not perform sign-in or change production onboarding read state.

CI runs the iOS (iPhone) and Mac UI test suites on every push (`.github/workflows/ui-tests.yaml`), and on every pull request captures the library, chat with a rendered view, a trip (trains, a tracked flight, days and a json-render view), Likes, a LaTeX paper (editor, reader and reviews), the MCP server and deep links on iPhone, iPad (in landscape) and macOS (`.github/workflows/screenshots.yaml`). `ScreenshotTests` in both UI test targets reach every screen in the app itself, running against the `--preview-likes` fixture, and the workflow records each iOS device's screen while the tests run, uploads the images and recordings as run artifacts (kept for 7 days), posts one PR comment linking to the images, and sends both to Telegram when the `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` secrets are set. Both workflows use the `[self-hosted, macOS, ARM64, ui-tests]` runner. For the Mac jobs, run `sudo automationmodetool enable-automationmode-without-authentication` once on that runner; otherwise UI tests wait for someone to authenticate and time out. CI has no Apple ID, so `scripts/ci/ui-test.sh` builds the simulator app unsigned and signs the Mac app ad hoc, without the app group, keychain group and associated domain entitlements.

The published RxAgentSDK 1.0.8 lacks the `userMessagePinning` parameter used by the current iOS chat implementation. Mac chat uses its published API. The iOS implementation is preserved and currently requires the existing local SDK edits until that API is released.

## Local agents in live voice

On the Mac, live voice can be answered by the user's own Claude Code or Codex instead of the cloud voice model. The composer's small button next to the microphone opens the picker, and the last pick is remembered (`LiveVoiceSettings`). The same sheet picks each agent's model, per agent, from the list the installed CLI reports through RxAgentSDK's `availableModels()`, called in the runner because a sandboxed app can't launch the CLI; leaving it on Agent Default uses the model from the agent's own settings. Models with no preset voices get a Voice Seed in Settings → Voice Models → Details, with a Play Sample button: the worker clones a clip it generates from that seed, so each seed is a different voice that stays the same for a whole conversation. iOS and visionOS always use the cloud voice.

- **Audio:** Apple's `SpeechAnalyzer` transcribes on device. Replies are read by the user-selected Hugging Face MLX speech model. Downloads pin the chosen revision and verify file hashes. `LocalVoiceManifest` pins the shared Python runtime, not a default model.
- **Model management:** Settings → Storage → Voice Models uses RxCode's sidebar/detail layout. Browse Hugging Face MLX text-to-speech models or select downloaded models on the left; the right shows metadata, README, and Downloads with the total model size. There is no bundled catalogue or architecture allowlist. Public MLX speech repositories can be downloaded and selected; actual inference support is determined by MLX Audio. Models needing reference audio or voice instructions still require those inputs and may fail to start in live chat. Search supports pagination. Downloads pin a revision, verify file hashes, and resume partial files. Models and the persisted catalogue stay in Application Support, never in the app bundle. Changing/deleting models requires ending voice chat. The first download also installs a shared runtime; its size is separate from the model size shown.
- **Runtime:** `kokoro_worker.py` runs in a `uv`-managed environment under `~/Library/Application Support/Chippy/LocalVoice`, separate from the app. The Swift Kokoro packages checked bring in GPL-3.0 code (FluidAudio's eSpeak-NG phonemizer, and mlx-swift-audio itself), which doesn't suit Chippy's license, so none is linked into the app. The runtime still downloads `espeakng-loader` as a separate component on the user's Mac. It needs Apple silicon and `uv`.
- **`ChippyLocalAgentRunner`:** an XPC service embedded in the app. The app stays sandboxed, but whatever a sandboxed app launches inherits its sandbox, and agents can't work under that. launchd starts XPC services separately, so the runner isn't sandboxed. This works for a Developer ID app but wouldn't pass Mac App Store review. It exposes named operations only, never arbitrary commands, and ends its processes when the app goes away. `scripts/ci/sign-sparkle.sh` signs it and asserts it has the hardened runtime and no sandbox.
- **Permissions:** nobody can approve prompts during a voice session. Claude Code runs in its default mode with only Chippy's tools and read-only tools allowed, so anything else is denied unless the user's own settings allow it. Codex runs with approvals off in a read-only sandbox, with only the Chippy server's tools auto-approved.
- **Library access:** the first session creates a normal API key named "Live Voice on <device>", kept in the keychain and revocable in Settings → MCP Server. Agents get it through an environment variable, so it never appears in process arguments.

Run `swift test` in `Packages/LocalAgentKit` for the parsers, command building and turn detection.
