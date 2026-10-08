SERVER_DIR := server
## Extra SwiftLint flags, e.g. `--reporter github-actions-logging` in CI.
SWIFTLINT_FLAGS ?=

.PHONY: lint lint-swift lint-server

## Lint the Swift sources and the server.
lint: lint-swift lint-server

## SwiftLint size and complexity rules (.swiftlint.yml). Install with `brew install swiftlint`.
lint-swift:
	swiftlint lint --quiet $(SWIFTLINT_FLAGS)

## ESLint and the TypeScript typecheck for the Next.js server.
lint-server:
	cd $(SERVER_DIR) && bun run lint && bun run typecheck
