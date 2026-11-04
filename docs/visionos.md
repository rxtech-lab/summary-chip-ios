# Vision Pro

Use the `summary-chip-visionOS` scheme for Vision Pro. It builds the shared app without the iOS/macOS test bundles. The `summary-chip` scheme also includes visionOS. Debug uses localhost:3000 and Release uses summary.rxlab.app through the existing configuration files. A physical headset needs a reachable development server address for local development.

The signed-in spatial library supports horizontal or vertical scrolling, chip selection, and dedicated detail sheets. Graphs support drag rotation, pinch zoom, reset, node detail sheets, and document-aware voice conversations. Trips place their map below the upright itinerary; edits retain dedicated sheets. The voice globe starts/stops the existing Gemini live session, displays responses and tool activity above it, stops when dismissed or inactive, and refreshes graph/trip data after agent edits.

## Build

```sh
xcodegen generate
xcodebuild -project summary-chip.xcodeproj -scheme summary-chip-visionOS \
  -destination 'generic/platform=visionOS Simulator' \
  -derivedDataPath /tmp/chippy-vision-build CODE_SIGNING_ALLOWED=NO build
```

Simulator compilation does not verify eye/hand gestures, spatial comfort, microphone routing, authentication callbacks, StoreKit presentation, or live provider connectivity. Validate these on Vision Pro before release.

## Dependency compatibility

RxAgentSDK, RxAuthSwift, and RxSubscriptionIOS use their original GitHub package dependencies, shared with the macOS and iOS app. No copies of these SDKs are maintained in this repository.

RxSubscriptionIOS 1.2.1 includes upstream visionOS support and scene-aware StoreKit purchases (PR #6). Chippy’s custom points top-up view passes its StoreKit purchase environment action. RxAgentSDK 1.2.1 contains the shared chat compatibility fixes (PR #27). RxAuthSwift is temporarily pinned to upstream commit `fad1772fcd4a4e9a252cd21ba180a92c5775d67c` from PR #24: its required GitHub-hosted CI jobs are queued, so the planned 1.3.3 release has not been published. Both fixes passed local SDK iOS/visionOS builds and macOS tests; the complete Chippy visionOS simulator and macOS builds also passed. Replace the authentication revision with the release version after required CI and automatic merge complete.

RxRemotion rejects ProRes encoding on visionOS; H.264 remains available.
