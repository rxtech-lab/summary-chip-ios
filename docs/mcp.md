# MCP server

The Chippy server hosts a [Model Context Protocol](https://modelcontextprotocol.io) server at
`https://summary.rxlab.app/api/mcp`. With it, AI agents (Claude Code, Claude Desktop, Cursor and others)
can add summaries to your library, search it in natural language and list it by filter, and read, create
and edit trip diaries, from any machine.
Agents sign in with a personal **API key** and act as the account that owns it. The app doesn't need to
be open.

## API keys

**Settings → MCP Server** on iOS (under *Integrations*) and macOS (under *General*) opens a sheet that:

- shows the endpoint URL, with a copy button;
- lists the account's keys, newest first. Each row shows the key's name, its hint
  (`chippy_Ab3x…9fQz`), how many tool calls it made, how many summaries it added, and when it was
  created and last used;
- **New API Key** (the `+` button) opens a sheet to name a key. After it's created, the same sheet shows
  the key **once**, with a copy button and ready-made configuration for Claude Code, Claude Desktop or any
  agent that reads JSON MCP configuration;
- **Rename…** opens its own sheet. **Revoke…** asks for confirmation, then deletes the key. Agents using it
  get `401` from their next request on. On iOS these are swipe actions; on both platforms they are in the
  row's context menu, and on macOS also in its `…` menu.

A key is `chippy_` followed by 32 random bytes in base64url. The server stores only its SHA-256
(`api_keys.key_hash`). The full key is in the `POST` response and nowhere else, so a lost key can't be
recovered: revoke it and create another. An account can have at most 25 keys. Keys go when the account is
deleted, through the `owner_id` foreign key's cascade.

| Method & path | Body | Response |
|---|---|---|
| `GET /api/v1/api-keys` | – | `{items:[ApiKey]}` |
| `POST /api/v1/api-keys` | `{name}` (1–60 chars) | `201 {key, apiKey: ApiKey}`, or `409 API_KEY_LIMIT_REACHED` |
| `PATCH /api/v1/api-keys/:id` | `{name}` | `ApiKey` |
| `DELETE /api/v1/api-keys/:id` | – | `204` (revoked) |

`ApiKey` is `{id, name, hint, toolCallCount, summariesAddedCount, lastUsedAt, createdAt}`. These routes
take the app's OAuth token, like the rest of `/api/v1`. An API key can't manage keys.

`lastUsedAt` is set on every `tools/call`, and on other authenticated MCP requests (`initialize`,
`tools/list`) at most once a minute per key. `toolCallCount` counts every `tools/call`, including failed ones. `summariesAddedCount` counts chips that
`add_summary` saved.

## Connecting an agent

### Claude Code

```sh
claude mcp add --transport http chippy https://summary.rxlab.app/api/mcp \
  --header "Authorization: Bearer <api key>"
# add --scope user to use it in every project
```

### Cursor, VS Code, `.mcp.json`

```json
{
  "mcpServers": {
    "chippy": {
      "type": "http",
      "url": "https://summary.rxlab.app/api/mcp",
      "headers": { "Authorization": "Bearer <api key>" }
    }
  }
}
```

### Claude Desktop

Claude Desktop's config file only starts stdio servers, so it reaches the HTTP endpoint through
[`mcp-remote`](https://www.npmjs.com/package/mcp-remote), which needs Node.js:

```json
{
  "mcpServers": {
    "chippy": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "https://summary.rxlab.app/api/mcp", "--header", "Authorization: Bearer <api key>"]
    }
  }
}
```

## Tools

| Tool | What it does | Service |
|---|---|---|
| `add_summary` | Saves a summary the agent wrote, with key points, tags and the raw source text. Nothing is re-summarised. | `importSummary` (as `POST /api/v1/summaries/import`) |
| `search_summaries` | Natural-language search (meaning + keywords), most relevant first. Up to 50 per page. | `listSummaries` with `q` |
| `list_summaries` | The library newest first, filtered. Up to 200 per call. | `listSummaries` |
| `list_trips` | The user's trips, ongoing and upcoming first, then past ones. | `listTrips` (as `GET /api/v1/trips`) |
| `get_trip` | A trip's full TripDocument and its revision. | `getTrip` |
| `create_trip` | Saves a new trip from a complete TripDocument. Free (no summary allowance). | `createTrip` (as `POST /api/v1/trips`) |
| `update_trip` | Applies operations (upsert/delete records by id, `set_meta`, `add_source`) in order, as one change. Free. | `applyTripOperations` (as `POST /api/v1/trips/:id/operations`) |
| `update_place` | Changes some of a place's details (description, photos, hours, prices, website, phone…) and appends photos, without resending the place. Free. | `applyTripOperations` with an `update_place` operation |
| `upload_trip_image` | Stores a photo (copied from a URL, or base64) for a trip and returns its lasting https URL. Free. | `uploadTripImage` |
| `add_to_trip_from_source` | Chippy's trip agent reads a URL or text and adds what it contributes to a trip. Costs points. | `addToTripFromSource` |

`search_summaries` and `list_summaries` accept the same filters: `source` (`web`, `x`, `facebook`,
`youtube`, `github`, `pdf`, `text`), `category`, `tag`, `visibility` (`public` / `private`), `kind`
(`summary` or `trip`) and `scope` (`all`, `mine`, `viewed` or `liked`). Both return `{count, items, nextCursor}`. Pass `nextCursor` back as `cursor`
to get the next page. Each item has `id`, `title`, `summary`, `keyPoints`, `category`, `tags`, `source`,
`sourceUrl`, `sourceTitle`, `siteName`, `shareUrl`, `visibility`, `language`, `isOwner`, `hasSourceText`,
`createdAt` and `viewedAt`.

`add_summary` takes `title`, `summary` and `text` (all required), plus optional `keyPoints` (≤ 5), `tags`
(≤ 12), `keywords` (≤ 10), `category`, `language`, `sourceUrl`, `sourceTitle`, `siteName`, `visibility`,
`ttlDays` (`1`, `3`, `7`, `30`, `90`, `365` or `"never"`) and `allowDuplicate`. The arguments are checked
with the import API's own schema, so the limits under [Import body](ARCHITECTURE.md#import-body) apply.
Added chips always get an illustrated cover. Each one counts against the summary allowance. The account's
devices with notifications on are alerted, the same as for the import API.

A chip that is already in the library (`409 DUPLICATE_SUMMARY`) comes back as a tool error. The message
names the existing chip and its link, and suggests `allowDuplicate: true`. Other API errors, such as an
allowance that is used up, come back as tool errors carrying the server's message and code.

### Trip tools

The trip format and its operations are specified in [trips.md](trips.md).

- `list_trips` takes no arguments and returns `{count, trips: [{id, slug, title, subtitle, startDate, endDate, revision, updatedAt, dayCount, placeCount}]}`.
- `get_trip` takes `tripId` and returns `{trip: {id, revision, visibility, shareUrl, updatedAt, document}}`. Anyone may read
  a public trip; only the owner's key may change it.
- `create_trip` takes `document` (a TripDocument, validated including referential integrity) and optional `visibility`
  (default `private`) and returns the same `{trip}`.
- `update_trip` takes `tripId`, `operations` (1–200) and an optional `revision`. With `revision`, a trip that changed since
  is refused (`TRIP_REVISION_CONFLICT`: call `get_trip` and retry); without it the operations apply to the latest document.
  A result that would be invalid (`TRIP_INVALID`, e.g. a `stayId` naming no hotel) changes nothing.
- `update_place` takes `tripId`, `placeId`, `changes` (any place fields except `id`; `null` clears an optional one,
  `photos` and `pricing` replace their lists), `addPhotos` (appended after the existing photos, skipping URLs already
  there, at most 12 in all) and an optional `revision`. It returns `{place, revision}`; an unknown `placeId` is a tool
  error listing the trip's place ids.
- `upload_trip_image` takes `tripId` and exactly one of `url` (a public image, fetched with the same SSRF checks as
  link summaries) or `data` (base64 or a `data:` URL). JPEG, PNG, WebP, GIF, AVIF or HEIC up to 15 MB is re-encoded as a
  JPEG of at most 2048 px with EXIF (GPS, camera) stripped, stored in R2 under `trip-images/<tripId>-<time>-<random>.jpg`,
  and returned as `{image: {url, width, height, byteSize}}`. The URL is on `R2_PUBLIC_BASE_URL` when set, else
  `/api/public/trip-images/:file` (the unguessable file name is the capability, like OG image keys). Put it in a place's
  `photos` or an `Image` / `Gallery` view. Only the trip's owner may upload.
- `add_to_trip_from_source` takes `tripId`, exactly one of `url` or `text`, and optional `instructions`. It holds points
  first (`TRIP_POINTS_EXHAUSTED` when the balance is empty), runs the trip agent synchronously (within the route's 300 s),
  and returns `{changeSummary, operationsApplied, trip}`. Invalid operations the agent proposes are dropped.

## Implementation

| File | Role |
|---|---|
| `server/app/api/mcp/route.ts` | `POST` handler: API key auth, then a fresh `McpServer` + `WebStandardStreamableHTTPServerTransport` per request (stateless, JSON responses). `GET`/`DELETE` answer `405` |
| `server/lib/mcp/server.ts` | Tool catalog (zod input schemas), mapping to the summary and trip services, results and usage counting |
| `server/lib/services/trips.ts` | Trip create/read/list/edit and the trip agent run behind the trip tools |
| `server/lib/services/api-keys.ts` | Key generation, hashing, list/create/rename/revoke, authentication and usage counters |
| `server/lib/http/handler.ts` | `withApiKeyAuth`: `401 MISSING_API_KEY` / `INVALID_API_KEY` with `WWW-Authenticate: Bearer` |
| `server/app/api/v1/api-keys/**` | Key management routes (OAuth) |
| `server/tests/integration/mcp.test.ts` | Key routes and MCP tool calls end to end |
| `summary-chip/MCP/MCPSettingsSheet.swift` | The settings sheet: endpoint, key list with usage, revoke |
| `summary-chip/MCP/APIKeySheets.swift` | Create (shows the key once, with agent configuration) and rename sheets |

The server is stateless: there are no `MCP-Session-Id`s, so any serverless instance can answer any
request, and `add_summary` runs within the route's `maxDuration` (300 s).

Check the endpoint by hand. Expect `401` without the key, then a JSON-RPC result with the server's
capabilities:

```sh
curl -i https://summary.rxlab.app/api/mcp \
  -H "Authorization: Bearer <api key>" -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"curl","version":"1"}}}'
```
