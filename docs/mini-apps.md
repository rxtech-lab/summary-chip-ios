# Mini Apps

Mini Apps are versioned interactive Chippy documents rendered with native SwiftUI controls on iOS and macOS. Describe an app in Chat, open the isolated preview, refine it, then choose **Save App**. The library also offers **New Mini App**. Owners can edit with AI, edit the definition directly, inspect version history, and restore a definition. **Manage** opens separate Data and Connections screens; **Sharing** manages invitations and table permissions.

The implementation follows the component/action/state separation in [ChatKit](https://developers.openai.com/api/docs/guides/custom-chatkit) and [ChatGPT app UI](https://developers.openai.com/plugins/build/chatgpt-ui). Chippy renders its own native catalog; it does not embed a ChatGPT web widget or depend on undocumented ChatGPT internals.

## Enablement and deployment

1. Apply the additive `server/drizzle/0032_mini_apps.sql` migration using the normal migration runner. Do this before deploying code which reads the new membership tables. The migration creates only Mini App tables and indexes.
2. Configure the encryption keyring on the server. Generate 32 random bytes per key and encode as base64. Set `MINI_APP_SECRET_KEYS` to a JSON object mapping version names to these keys, and `MINI_APP_ACTIVE_SECRET_KEY` to the current version name. Keep the keyring in deployment secrets, never in source control. Retain old keys until all associated credentials have been rotated or reconnected.
3. Set `NEXT_PUBLIC_SITE_URL` to the deployment's HTTPS origin. Register each displayed OAuth callback URL with the provider. The callback is `/api/v1/mini-apps/{appId}/connections/{connectorId}/callback`.
4. Build with Node worker support. `next.config.ts` traces the standalone QuickJS worker and its WASM packages into Mini App, chat and MCP server functions. The functions require Node, not an Edge runtime. Use `bunx next build` for a build-only check; the repository's `bun run build` also runs migrations against the configured database.
5. In a deployment preview, run a pure script, an infinite script, and an allocation-heavy script through validation/action execution. Check termination and inspect the deployed worker/WASM files before enabling `MINI_APPS_ENABLED=true`.
6. Ship the matching native renderer. The catalog advertises schema version 1, component names, expressions, action schemas, limits and examples. Server validation rejects unsupported versions; the client displays an update message for unknown document versions.

No production migration, secret provisioning, provider registration, or deployment is performed merely by building the repository. No background schedules or incoming webhooks are implemented.

## Definition and rendering

The contract lives in `server/lib/contracts/mini-app.ts`; native models live in SummaryKit. A definition contains `schemaVersion`, title/description, an element graph, initial state, logical table schemas, named queries, actions, JavaScript function bodies, connector specifications, and preview fixtures. It never contains live records or connection secrets.

UI elements use `type`, `props`, child IDs, optional `visible` expressions and `repeat.items`, plus named event handlers. Existing trip and chat visualizations retain their component format through the shared native visual renderer. Native interactive elements include Navigation, Tabs/Tab, Toolbar, Menu, Form/Section, Button, text fields/editors, toggles, pickers, dates, device location, maps, progress/empty states, Sheet, Dialog, Alert, and Confirmation. Icons use SF Symbols. Buttons support disabled expressions and a destructive role. Navigation and sheets use a form directly when their sole content is a Form. `Location` is a button that asks for when-in-use access and writes `{latitude, longitude, accuracy}` to its `binding`, then fires `change`; with `auto` it fills in on load only when access was already granted, so it never prompts unprompted. Coordinates stay on the device unless an action sends them to the server as state or to an API as request input. `Map` shows a MapKit map centered on `latitude`/`longitude` with a `span` in meters (or fitted to its `markers`); selecting a marker writes its `id` to `binding` and fires `change`. A Sheet with `height: "half"` opens at half height and can be dragged to full height (iOS); on macOS it opens as a shorter sheet. `Tabs` renders a native tab bar of `Tab` children (title, SF Symbol icon, optional badge; on macOS the tabs sit in the navigation bar as a segmented control); use it as the root, or as a Navigation's sole content, to split an app into screens. Its `binding` keeps the selected tab id in state. `Toolbar` children become native toolbar items with a `placement` of `primary` (default), `secondary`, `leading` or `bottom`; a Toolbar on Tabs shows on every tab, and one inside a Tab shows while that tab is selected. `searchable` on a Navigation or Tabs adds the native search field: typing writes `state.search` and fires `search`, and Return fires `submit`. The app's own Edit, Versions, Sharing and Manage commands sit in a single More menu, which leaves the toolbar to the Mini App.

Use `{"get":"state.path"}`, `{"get":"item.data.field"}`, or `{"op":"add","args":[1,2]}` for computed values. Form `binding` values are literal state paths. Repeated query rows contain `id`, `revision`, and `data`. `props.input` supplies evaluated event inputs. Search writes `state.search`; load/search/refresh/change events must reference a `read` action. `press` and `submit` may invoke `interaction` actions. `present` opens a Navigation destination, native sheet, alert or confirmation based on its target's component type. `dismiss` closes the active presentation. State survives query refreshes; state changed while a request is in flight is preserved when results arrive.

Pure presentation actions (including conditions) execute locally. In a saved app, an action whose steps are only presentation steps, keyless (`auth: none`) requests and scripts also runs on the device: keyless requests go directly from the device to the API with the same origin, input, 1 MiB and 10-second limits, and each script step runs in the server sandbox through `POST /api/v1/mini-apps/{id}/scripts` (`{revision, script, input}` → `{value}`). Actions with queries, database mutations or credentialed connectors execute entirely on the server against a saved app revision and declared action ID. Preview always runs on the server with fixtures. The server validates fields and current permissions; JSON never supplies authenticated identity or an ownership override. Form validation catches required values before a user action. Mutations are not triggered by opening, searching or refreshing.

Limits: 1 MiB definition/state/request/response, 100 KB per record, 300 declared elements, depth 24, 5,000 expanded elements, 100 repeated rows, 50 steps per action, and a 30-second action budget checked between steps. An in-flight bounded API request or worker may finish after that deadline; another step will not start. Runtime actions are capped at 120 per user per minute. JSON expressions and state paths cannot traverse prototype keys.

## Data and history

`mini_apps` stores the validated schema and current revision. Logical collection definitions are stored atomically inside that document. `mini_app_records` stores JSON records partitioned by app ID, collection ID and user ID for personal data, or the shared partition. There are no dynamically created per-user SQL tables. `mini_app_members` stores email invitations and explicit shared-table read/write permissions. Personal tables remain private to the acting user, including from the app's creator. Membership does not confer permission to change the app definition.

Fields are typed string, number, boolean, date or JSON, with optional required validation. Queries provide filters, sorting and page cursors, with at most 100 rows per page. A query action step can supply a `cursor` expression from the previous result's `nextCursor`. Record changes require the record revision; definition edits require the app revision. New apps are private. Definition history records owner/chat/agent authorship, and restoration creates another version without changing records or credentials. Removing or changing a populated table's scope/types/required fields is refused. V1 does not offer an automatic data transformation engine: preserve the old collection, add a compatible collection, and carry out an explicit, reviewed migration separately.

Action and direct record-write requests require a UUID idempotency key. A duplicate completed request returns the same result if its permissions are still valid. A changed request or revoked permissions are refused. Failed, running, or uncertain requests with the same key never run again. Multi-step actions are not transactions spanning external services: earlier successful database changes can remain after a later failure. Refresh the app before initiating a new attempt. External writes with lost/failed responses return an uncertain outcome and are never retried automatically.

App deletion cascades definitions, records, members, connections, grants, pending OAuth flows, and execution records through the existing summary deletion path. Deleting a user cascades their personal records and connections. Execution records can contain user data in saved state and must be treated as private application data. Retain idempotency keys if implementing a future execution-result retention policy; deleting a key reopens the possibility of a duplicate write.

## Connections

The server broker supports JSON HTTPS APIs that are public (`auth: {"type":"none"}`, no connection or credential), or use API-key headers or OAuth 2.0 authorization-code authentication. Public connectors are called from the device when the action runs there; when the server runs them (actions mixing queries or mutations, MCP), they go through the same HTTPS, SSRF, size and time limits. Each connector fixes one API origin and named operations with method, path and typed inputs. GET inputs become query parameters; other methods send JSON. This version does not support multipart uploads, streaming, arbitrary client headers, or provider-specific token authentication methods beyond public clients and `client_secret_post`.

Users enter keys/client secrets only in the native Connections screen. OAuth uses the system authentication session, PKCE S256, random expiring single-use state bound to the initiating Chippy user/app/connector/callback, and a server-side token exchange. Cancellation consumes state. Token refresh uses a database lease and revision checks so two requests cannot rotate the same token concurrently; failed refreshes require reconnection. Disconnect removes local access immediately and attempts provider revocation when configured.

API keys, client secrets, access/refresh tokens and pending OAuth verifiers are AES-256-GCM encrypted with random nonces, versioned server keys and authenticated app/user/connector/connection ownership metadata. Reads can decrypt older key versions; successful use reseals under the active key. Secrets are excluded from the renderer, scripts, authoring tools and version history. Provider responses are redacted for known credential values. Do not add request-body/header logging around these routes.

Connections are personal by default. Only the app owner may create an app-owned shared connection and explicitly grant named operations to invited members. Membership and grants are rechecked immediately before dispatch. A changed connector fingerprint, including origin, operation, OAuth endpoints or scopes, requires reconnection; reconnecting clears shared grants. Grant revocation does not distribute or expose credentials.

The broker requires HTTPS/public addresses, validates every DNS result, pins the connection to one validated address, rejects credential-bearing redirects, restricts credential header names, bounds DNS and request time, and limits response size. JavaScript cannot call the broker directly. Security guidance: [OAuth 2.0 Security BCP](https://www.rfc-editor.org/rfc/rfc9700.html).

## JavaScript and preview

Scripts are JSON-in/JSON-out function bodies receiving `input`. Each invocation gets a fresh [QuickJS WASM](https://github.com/justjake/quickjs-emscripten) runtime in a terminable Node worker: 32 MiB script memory, 256 KiB script stack, one-second interrupt budget, five-second worker deadline, and bounded JSON input/output. No process, environment, filesystem, host imports, credentials or direct networking are exposed. Effects belong in explicit subsequent declarative steps. Ordinary runtime actions and definition saves never call a model.

Preview uses only `fixtures.records` and `fixtures.responses` plus an isolated preview record copy. Response keys are `connector_operation`. `fixtures.tests` declares up to ten `{action,input,state,expectState}` cases; validation runs them in isolation, compares the named state values and reports actionable diagnostics, with a ten-second fixture validation budget. Syntax checks and fixture execution never use real user records or connections.

Acceptance examples:

- [Personal tracker](mini-app-examples/personal-tracker.json): private records, native add sheet, required input, search and refresh.
- [Shared checklist](mini-app-examples/shared-checklist.json): invite a reader and a writer in Sharing; only the writer can mark shared rows complete.
- [Weather](mini-app-examples/weather.json): a Now / Map tab bar, a toolbar location button, city search in the native search field, a map whose marker opens a half-height details sheet, two keyless Open-Meteo connectors, a script formatting conditions, and `if` branches for no match.
- [API dashboard](mini-app-examples/api-dashboard.json): mocked HTTPS response, a pure JavaScript aggregation, and an explicit read action. Replace the example origin with your actual API and connect it in Chippy.

## HTTP and MCP

All application/data/connection endpoints require bearer authentication. OAuth callback state identifies the initiating account; it is not a general application access token.

| Endpoint | Operations |
| --- | --- |
| `/api/v1/mini-apps` | GET owned apps (ten/page); POST validated definition |
| `/api/v1/mini-apps/catalog` | GET schema and renderer capabilities |
| `/api/v1/mini-apps/validate` | POST definition validation and fixture checks |
| `/api/v1/mini-apps/preview` | POST isolated preview action |
| `/api/v1/mini-apps/:id` | GET definition; PUT `{document,revision}`; DELETE owned app |
| `/api/v1/mini-apps/:id/actions` | POST `{revision,action,key,input,state,item?}` |
| `/api/v1/mini-apps/:id/records` | GET table/query/cursor; POST `{key,table,operation,id?,revision?,data?}` |
| `/api/v1/mini-apps/:id/members` | GET members; PUT email, table permissions or removal |
| `/api/v1/mini-apps/:id/connections` | GET statuses; POST native API-key/OAuth setup |
| `/api/v1/mini-apps/:id/connections/:connectionId` | DELETE owned connection; PUT shared operation grants |

The existing document-version endpoints/tools accept `mini_app`. Focused Chat accepts `miniAppId` and uses existing chat billing for AI authoring/refinement. MCP tools use the same validation/service layer: `get_mini_app_catalog`, `validate_mini_app`, `create_mini_app`, `get_mini_app`, `list_mini_apps`, and `update_mini_app`. Read tools use `chippy:read`; create/update use `chippy:write`. Listings are paginated with a hard ten-item maximum. Updates require an expected revision and create an agent-authored version. Agents declare integrations; connection setup belongs in Chippy.

Sharing creates a separate revocable metadata-preview link. Its web page contains app metadata and **Open in Chippy**. A preview link, including one marked “anyone,” never grants runtime access: the Mini App service still requires the owner or a current invitation. The original private document link remains private.

## Verification

Integration coverage includes app/user isolation, shared roles and revocation, connection grants, stale revisions, duplicate writes, incompatible schemas, version restoration, deletion cascades, OAuth cancellation/replay/expiry/refresh races, credential encryption and rotation, SSRF literals, redaction, pure scripts, infinite loops and memory exhaustion, fixtures, MCP scopes and listing bounds. Existing trip/chat rendering, MCP and document-version tests remain in the regression suite.

`MiniAppUITests` exercises the real native sheet/form/confirmation renderer with an offline fixture (`--preview-mini-app`). SummaryKit tests cover definition decoding and safe expression/state bindings. Before release, also verify VoiceOver, macOS keyboard navigation, all controls, real provider OAuth cancellation/rotation and connection recovery on physical devices. A local build or simulator run does not replace provider or deployed worker checks.

### Local verification record

The implementation was verified with the full server suite (565 tests), SummaryKit regressions (182 tests), an iOS simulator form/sheet/confirmation test, native iOS/macOS builds, and a production webpack build. The QuickJS worker plus dependencies copied solely from the production trace returned a pure result, interrupted an infinite loop, and rejected memory exhaustion. The default Turbopack build stalled in this local environment; the supported `next build --webpack` completed. The macOS UI test could not begin because the desktop was locked; its build passed. No remote deployment preview or live-provider OAuth flow was run; those remain release checks.
