# Chippy

Chippy turns articles, videos, documents, and other sources into shareable summary cards. This repository contains the Apple apps, extensions, and the server that powers summaries and sharing.

## Repository

- `summary-chip/` and `summary-chip-macOS/` — iOS and macOS apps.
- `Packages/SummaryKit/` — shared Swift code.
- `SmartShare/`, `SummaryMessages/`, and `SummaryClip/` — sharing extensions and App Clip.
- `server/` — Next.js API, website, and hosted MCP server.

Open `summary-chip.xcodeproj` in Xcode to explore the Apple app. For server setup, configuration, and commands, see the [server README](server/README.md). The [architecture guide](docs/ARCHITECTURE.md) describes the app and API.

## License

Chippy is source-available under the [Chippy Source-Available License](LICENSE). Noncommercial use is permitted subject to its terms; commercial use and competing hosted services require separate written permission. Third-party materials may have their own licenses.
