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

CI runs the iOS (iPhone) and Mac UI test suites on every push (`.github/workflows/ui-tests.yaml`), and on every pull request captures the library, chat with a rendered view, a trip (trains, a tracked flight, days and a json-render view), Likes, the MCP server and deep links on iPhone, iPad and macOS (`.github/workflows/screenshots.yaml`). `ScreenshotTests` in both UI test targets run against the `--preview-likes` fixture, and the workflow uploads the images as run artifacts (kept for 7 days) and posts one PR comment linking to them. Both workflows use the `[self-hosted, macOS, ARM64, ui-tests]` runner. For the Mac jobs, run `sudo automationmodetool enable-automationmode-without-authentication` once on that runner; otherwise UI tests wait for someone to authenticate and time out. CI has no Apple ID, so `scripts/ci/ui-test.sh` builds the simulator app unsigned and signs the Mac app ad hoc, without the app group, keychain group and associated domain entitlements.

The published RxAgentSDK 1.0.8 lacks the `userMessagePinning` parameter used by the current iOS chat implementation. Mac chat uses its published API. The iOS implementation is preserved and currently requires the existing local SDK edits until that API is released.
