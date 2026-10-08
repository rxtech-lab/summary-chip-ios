# MCP server

The Chippy server hosts a [Model Context Protocol](https://modelcontextprotocol.io) server at
`https://summary.rxlab.app/api/mcp`. With it, AI agents (Claude Code, Claude Desktop, Cursor and others)
can add summaries to your library, search it in natural language and list it by filter, and read, create
and edit trip diaries, from any machine.
Agents sign in with **OAuth** or a personal **API key**, acting as the connected account. The app
doesn't need to be open.

## OAuth sign-in

An OAuth-capable agent needs only the Streamable HTTP endpoint URL. An installed plugin can bundle
that connection in `mcp.json`; the agent discovers Chippy's authorization server, registers a public
OAuth client, opens RxLab sign-in, and asks the user to approve Chippy access. Installing the plugin
does not bypass the user's sign-in or consent.

Chippy acts as both the MCP resource server and a small OAuth authorization server. RxAuth proves
the user's identity through a **dedicated confidential client** and its existing authorization-code
+ S256 PKCE flow. Chippy then issues its own opaque MCP credentials, bound to the MCP resource,
client and consented scopes. RxAuth app access tokens are never forwarded to MCP agents and remain
invalid at `/api/mcp`.

### Deployment

1. Register a confidential OAuth client in RxAuth named **Chippy MCP**. Enable the authorization-code
   flow, S256 PKCE, and the `openid profile email` scopes. Register the exact callback URL
   `https://summary.rxlab.app/api/mcp/oauth/callback` (use your MCP origin for another deployment).
2. Set server-only `MCP_RXAUTH_CLIENT_ID` and `MCP_RXAUTH_CLIENT_SECRET` to that client's credentials.
   Do not add this client to the ordinary `/api/v1` client allowlist. It is used only to prove MCP login.
3. Set `MCP_RESOURCE_URL=https://summary.rxlab.app/api/mcp`. This canonical audience is never taken
   from incoming Host headers. Only HTTPS is supported, except HTTP on loopback for local development.
4. Apply `server/drizzle/0016_mcp_oauth.sql` through the normal migration command before deploying.
5. Install/enable the Chippy plugin or add its URL in an OAuth-capable MCP agent, then connect and
   approve access. OpenAI hosts can use **dynamic client registration (DCR)**; choose DCR when
   configuring a custom MCP connection. Chippy advertises public-client token authentication (`none`)
   and `S256`, and returns `iss` in authorization responses. CIMD is not advertised.

Local development uses, for example, `MCP_RESOURCE_URL=http://127.0.0.1:3000/api/mcp`; register that
origin's `/api/mcp/oauth/callback` in the development RxAuth client. Upstream discovery is not proxied
or rewritten: the broker uses RxAuth's existing `/api/oauth/authorize`, `/api/oauth/token` and
`/.well-known/jwks.json` endpoints under `AUTH_ISSUER`.

### Endpoints and permissions

| Endpoint | Purpose |
|---|---|
| `GET /.well-known/oauth-protected-resource` | MCP audience, authorization server and supported scopes |
| `GET /.well-known/oauth-protected-resource/api/mcp` | Path-specific resource metadata alias |
| `GET /.well-known/oauth-authorization-server` | Chippy authorization server discovery |
| `POST /api/mcp/oauth/register` | Public-client registration; JSON metadata, HTTPS or loopback callbacks |
| `GET /api/mcp/oauth/authorize` | Validate client, callback, scope, resource and S256 challenge; begin RxAuth login |
| `GET /api/mcp/oauth/callback` | Verify upstream state, browser cookie and signed RxAuth identity |
| `GET/POST /api/mcp/oauth/consent` | Show permissions and approve or deny this agent's access |
| `POST /api/mcp/oauth/token` | Exchange a code or rotate a refresh token; URL-encoded form |
| `POST /api/mcp/oauth/revoke` | Revoke the grant associated with an access or refresh token |

Authorization and token requests must include `resource` equal to `MCP_RESOURCE_URL`. Codes are
bound to the registered client, exact callback and S256 verifier, expire after one minute, and can
be used once. Login/consent requests expire after ten minutes and are bound to an HttpOnly,
SameSite browser cookie. The consent page shows the agent's name, callback origin and requested
permissions; it never silently grants access based on a previous RxAuth consent.

| Scope | Tools |
|---|---|
| `chippy:read` | `search_summaries`, `list_summaries`, `list_trips`, `get_trip`, `get_upload` |
| `chippy:write` | `add_summary`, `update_summary`, `create_trip`, `update_trip`, `update_place`, `choose_plan_option`, `create_upload`, `upload_trip_image`, `add_to_trip_from_source` |
| Valid connection, no additional scope | `get_profile` — stable connected account ID with available name/email |

An omitted scope defaults to `chippy:read`. Tool declarations expose their OAuth scopes. A tool
called with insufficient permission returns an OAuth challenge in `_meta["mcp/www_authenticate"]`
so the host can request approval for the needed scope before retrying. Invalid or expired transport
credentials get `401` with a `WWW-Authenticate` challenge pointing to resource metadata.

Access tokens expire after one hour. Refresh tokens rotate on every use, with a thirty-day maximum
grant lifetime from consent. Refresh can retain or explicitly narrow the grant's scopes; it cannot
expand them. Narrowing also removes those permissions from earlier access tokens in that grant.
Replaying a consumed code or refresh token revokes the whole grant. Revocation likewise invalidates
all its credentials, and finalized account deletion cascades to grants, codes and tokens. Only
credential hashes are persisted; upstream access/refresh tokens are discarded after login.

The cleanup cron retires expired login state, codes and credentials. Registered client IDs remain
stable across reconnects. Anonymous registration is limited to sixty clients per minute across
instances; deployment-level request limits can further protect this public endpoint.

### Verification

`server/tests/integration/mcp-oauth.test.ts` covers discovery, registration, login and consent,
PKCE/client/callback/resource binding, scope enforcement, refresh rotation and replay, revocation,
expiry, private-library isolation and account-deletion cascade. It uses a temporary SQLite file so
interactive transactions use the same shared database across connections.

`server/tests/e2e/mcp-oauth-browser.spec.ts` drives Chromium through the actual Allow/Cancel form
and a real loopback agent callback, including code exchange and an authenticated profile call.
It checks the browser-generated Origin header, callback navigation, and mobile/dark layout.
The consent page uses `Referrer-Policy: same-origin` so native form POSTs retain their origin,
and its CSP allows the registered agent callback origin for the post-consent redirect. Origin,
browser-cookie and CSRF checks remain enforced.

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
| `add_summary` | Saves a summary the agent wrote, with key points, tags and the raw source text. Nothing is re-summarised. Free. | `importSummary` (as `POST /api/v1/summaries/import`) |
| `update_summary` | Changes some fields of one of the user's own chips (title, summary, key points, tags, keywords, category, visibility, link lifetime). Free. | `patchSummary` (as `PATCH /api/v1/summaries/:id`) |
| `search_summaries` | Natural-language search (meaning + keywords), most relevant first. Up to 50 per page. | `listSummaries` with `q` |
| `list_summaries` | The library newest first, filtered. Up to 200 per call. | `listSummaries` |
| `list_trips` | The user's trips, ongoing and upcoming first, then past ones. | `listTrips` (as `GET /api/v1/trips`) |
| `get_trip` | A trip's full TripDocument and its revision. | `getTrip` |
| `create_trip` | Saves a new trip from a complete TripDocument. Free (no summary allowance or points). | `createTrip` (as `POST /api/v1/trips`) |
| `update_trip` | Applies operations (upsert/delete records by id, `set_meta`, `add_source`) in order, as one change. Free. | `applyTripOperations` (as `POST /api/v1/trips/:id/operations`) |
| `choose_plan_option` | Records which option of a plan (route 1 / route 2…) the user follows; saved per user, the document doesn't change. Free. | `selectPlanOption` (as `PUT /api/v1/trips/:id/plan-selections`) |
| `update_place` | Changes some of a place's details (description, photos, hours, prices, website, phone…) and appends photos, without resending the place. Free. | `applyTripOperations` with an `update_place` operation |
| `create_upload` | Prepares a presigned S3-compatible PUT URL for an image or file (up to 25 MB). Free. | `createUpload` |
| `get_upload` | Checks a completed upload belongs to the caller and returns a temporary download URL. Free. | `getUpload` |
| `upload_trip_image` | Stores a photo (copied from a URL, base64, or an owned upload) for a trip and returns its lasting https URL. Free. | `uploadTripImage` |
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
Added chips always get an illustrated cover. They are free: unlike the import API, they don't use the summary
allowance or points. The account's devices with notifications on are alerted, the same as for the import API.

A chip that is already in the library (`409 DUPLICATE_SUMMARY`) comes back as a tool error. The message
names the existing chip and its link, and suggests `allowDuplicate: true`. Other API errors come back as
tool errors carrying the server's message and code.

`update_summary` takes `summaryId` plus any of `title`, `summary`, `keyPoints`, `tags`, `keywords`,
`category`, `visibility` and `ttlDays`; fields left out stay as they are, and lists replace the old ones.
The arguments are checked with the `PATCH /api/v1/summaries/:id` schema. Edits go to the chip as written,
never to the translation the owner reads; changing the title, summary or key points drops the chip's
translations (and their covers), which are re-made on the next read. The cover itself isn't redesigned.
Only the owner can update a chip, and trips are refused (use `update_trip`).

### Image and file uploads

The MCP transport carries upload metadata, not file bytes. Storage uses the existing Cloudflare R2
S3-compatible signer. No new storage credentials or bucket are required.

1. Call `create_upload` with `filename` (1–300 characters), `mimeType` (a MIME type without parameters,
   such as `image/png`, `application/pdf`, `text/plain` or `application/octet-stream`) and `byteSize`
   (the exact file size, 1–26,214,400 bytes). It returns
   `{key, uploadUrl, method:"PUT", headers:{"content-type":…}, expiresAt}`. The URL expires in ten minutes.
2. PUT the raw bytes directly to `uploadUrl` with the returned headers. Use the URL exactly as returned;
   the signature binds the MIME type and content length. Do not send a multipart form, base64, or the
   Chippy Authorization header to storage. For example, after preparing an `image/png` upload:

   ```sh
   curl --fail-with-body --request PUT --upload-file /path/to/photo.png \
     --header 'Content-Type: image/png' "$UPLOAD_URL"
   ```

3. Call `get_upload` with `{key}` to check completion and obtain
   `{key, filename, mimeType, byteSize, downloadUrl, expiresAt}`. This download URL expires in five minutes
   and uses an attachment disposition. A missing object returns `UPLOAD_INCOMPLETE`; a size different
   from `byteSize` returns `UPLOAD_SIZE_MISMATCH`. Other accounts and keys outside the upload namespace
   are refused before storage access.
4. For a lasting trip photo, call `upload_trip_image` with `{tripId, uploadKey:key}` after PUT succeeds,
   then pass its `image.url` to `update_place` or a trip view. It verifies both upload and trip ownership
   and applies the same 15 MB image limit, resizing and metadata removal as URL/base64 uploads.

`create_upload` requires `chippy:write`; `get_upload` requires `chippy:read`. Raw uploads get an
owner-scoped random key under `uploads/` and are accessed through signed URLs, with no public URL
returned by these tools. Upload rows and objects not attached to a summary are removed by the existing
cleanup cron once older than 24 hours. `get_upload` does not extend their lifetime. The processed trip
photo is stored separately and survives cleanup of the raw upload. The app's `POST /api/v1/uploads`
continues to accept PDFs only.

See [R2 presigned URL documentation](https://developers.cloudflare.com/r2/api/s3/presigned-urls/)
for the storage protocol and browser CORS requirements.

### Trip tools

The trip format and its operations are specified in [trips.md](trips.md).

A trip's cover is designed once, by `create_trip`. Edits (`update_trip`, `update_place`,
`add_to_trip_from_source`, `choose_plan_option`) update its title and text but never redesign the cover.

- `list_trips` takes no arguments and returns `{count, trips: [{id, slug, title, subtitle, startDate, endDate, revision, updatedAt, dayCount, placeCount}]}`.
- `get_trip` takes `tripId` and returns `{trip: {id, revision, visibility, shareUrl, updatedAt, document, planSelections}}` (`planSelections`: plan id → the option the user picked). Anyone may read
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
  link summaries), `data` (base64 or a `data:` URL) or `uploadKey` (from `create_upload`, after PUT completes).
  JPEG, PNG, WebP, GIF, AVIF or HEIC up to 15 MB is re-encoded as a
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
| `server/lib/services/uploads.ts` | Presigned upload creation, ownership/completion checks and temporary download URLs |
| `server/lib/services/trip-images.ts` | URL/base64/presigned-upload image processing and lasting trip photo URLs |
| `server/lib/services/api-keys.ts` | Key generation, hashing, list/create/rename/revoke, authentication and usage counters |
| `server/lib/http/handler.ts` | `withMcpAuth`: personal keys or resource-bound OAuth tokens; OAuth discovery challenges on `401` |
| `server/lib/mcp/oauth*.ts`, `server/app/api/mcp/oauth/**` | OAuth discovery, registration, RxAuth login, consent and credential lifecycle |
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
