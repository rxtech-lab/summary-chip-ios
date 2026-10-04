# Chippy — Architecture & API Contract

This document is the single source of truth shared by the Next.js server (`server/`) and
the iOS targets (app, share extension, iMessage extension, App Clip). Both sides must
implement exactly this contract.

## Repository layout

```
server/                     Next.js 16 (App Router) + Vercel AI SDK v7, bun
  app/s/[slug]/             Public preview website (the link that gets shared)
  app/api/v1/...            Bearer-authenticated JSON API for iOS
  app/api/public/...        Unauthenticated API (App Clip)
  app/api/cron/cleanup      Vercel cron: retire OG images of expired links, orphan uploads
  app/api/cron/account-deletion  Vercel cron (hourly): purge accounts past their deletion date
  lib/db                    drizzle-orm + Turso (libsql) + FTS5
  lib/storage               Cloudflare R2 via @aws-sdk/client-s3
  lib/ai                    Summarisation, OG image design, chat agent
project.yml                 XcodeGen spec (generates summary-chip.xcodeproj)
Packages/SummaryKit         Swift package shared by every iOS target
summary-chip/               Main iOS app
SmartShare/                 Share extension (web pages, URLs, PDFs, text)
SummaryMessages/            iMessage app extension
SummaryClip/                App Clip for the preview website
Configuration/              xcconfig files (API base URL, RxAuth client, …)
```

## Identifiers

| Thing | Value |
|---|---|
| Team | `P9KK452K8P` |
| App bundle id | `com.rxlab.summary-chip` |
| Share extension | `com.rxlab.summary-chip.SmartShare` |
| iMessage extension | `com.rxlab.summary-chip.Messages` |
| App Clip | `com.rxlab.summary-chip.Clip` |
| Keychain access group | `$(AppIdentifierPrefix)com.rxlab.summary-chip.shared` |
| App group | `group.com.rxlab.summary-chip` |
| OAuth redirect | `summarychip://oauth/callback` |
| RxAuth issuer | `https://auth.rxlab.app` |
| Public site (default) | `https://summary.rxlab.app` (env `NEXT_PUBLIC_SITE_URL`) |

## Authentication

* iOS signs in with **RxAuthSwift** (`OAuthManager` + `RxSignInView`), public client id
  from xcconfig `SUMMARY_CHIP_IOS_CLIENT_ID`.
* Tokens live in one JSON keychain item shared through the keychain access group so the
  share extension and iMessage extension reuse the session. Refresh happens in
  `SharedTokenBroker` (actor) guarded by a cross-process `flock` in the app group
  container (pattern copied from sticker-gen).
* Server verifies `Authorization: Bearer <jwt>` against
  `${AUTH_ISSUER}/.well-known/jwks.json` (RS256, `client_id` must be in the allow list:
  `IOS_OAUTH_CLIENT_ID`, `RXLAB_ALLOWED_CLIENT_IDS`). `sub` is the user id.
* The App Clip is anonymous; it only uses `/api/public/*`.

## Data model (Turso / SQLite)

```
users(id PK = RxAuth sub, email, name, created_at)
summaries(
  id PK (uuid), slug UNIQUE (10 char, url-safe), owner_id FK users,
  source_type  'url' | 'webpage' | 'pdf' | 'text',
  source_url, source_title, site_name, source_file_key (R2, pdf only),
  content_excerpt (≤ 8k chars of extracted text, for the chat's getSummary tool),
  content_text (the full extracted original text, ≤ 500k chars; grounds the per-summary chat),
  content_markdown (the source as a formatted Markdown document, NULL when not kept: always kept for
                    url/webpage/text and pdfs with a sourceUrl; local files only with keepSourceText.
                    Written by the document agent (lib/ai/document-agent.ts) from the page's simplified
                    HTML — links, images, headings, tables — or the plain text; saved after the response),
  title, summary, highlights JSON[], category, tags JSON[], keywords JSON[], language,
  theme JSON {colors[], mode, emoji, accent},
  image_style 'graphic' | 'illustration', og_image_key (R2),
  visibility 'public' | 'private', ttl_days (NULL = never), expires_at (NULL = never),
  view_count, created_at, updated_at)
summary_tags(summary_id, tag)                    -- tag filter index
summary_views(user_id, summary_id, viewed_at)   -- "past viewed content" history
summaries_fts  FTS5(title, summary, highlights, tags, keywords, category, site_name)
```

Default TTL = `DEFAULT_TTL_DAYS` env (7). Allowed `ttlDays`: 1, 3, 7, 30, 90, 365, or
`null` (never). Changing TTL recomputes `expiresAt = now + ttlDays`; switching private → public
without a TTL restarts the clock the same way.

The TTL only limits the **public link**. Summaries are kept until the owner deletes them: after
`expiresAt` the owner still sees and can edit the summary, while everyone else (web page, OG image,
public API, other users' libraries/chat) gets 404 until the owner extends the TTL or re-shares it.

"Delete" in the app is available, but the primary way to stop sharing is making the
summary **private**: the `/s/[slug]` page, OG image and public API then return 404,
while the owner still sees it in the app and can flip it back to public.

## JSON shapes (camelCase, ISO-8601 dates)

```jsonc
// Summary
{
  "id": "uuid", "slug": "a1B2c3D4e5",
  "shareUrl": "https://summary.rxlab.app/s/a1B2c3D4e5",
  // public + R2_PUBLIC_BASE_URL set: direct CDN URL ${R2_PUBLIC_BASE_URL}/og/<id>-<ts>-<random>.png;
  // otherwise the gated route (owner bearer token for private summaries):
  "ogImageUrl": "https://summary.rxlab.app/s/a1B2c3D4e5/og.png?v=<updatedAt ms>",
  // the same artwork with no text (library tiles draw their own title); same URL rules, null when absent:
  "artImageUrl": "https://summary.rxlab.app/s/a1B2c3D4e5/art.png?v=<updatedAt ms>" | null,
  "sourceType": "url" | "webpage" | "pdf" | "text",   // how it was submitted
  "source": "web" | "pdf" | "text",   // what the content is (a `url` serving a PDF → "pdf"); open set, clients must tolerate new values
  "sourceUrl": "https://…" | null,
  "sourceTitle": "string" | null, "siteName": "string" | null,
  "sourceFileUrl": "https://summary.rxlab.app/s/<slug>/source" | null,   // pdf only
  "hasSourceMarkdown": true,   // the source was kept as Markdown (GET /api/v1/summaries/:id/markdown); a local file's only for its owner
  "title": "string", "summary": "string", "highlights": ["string"],
  "category": "Technology", "tags": ["ai", "apple"], "keywords": ["..."],
  "language": "en",
  "theme": { "colors": ["#104b8f", "..."], "mode": "light" | "dark", "emoji": "📰", "accent": "#hex" },
  "imageStyle": "graphic" | "illustration",
  "visibility": "public" | "private",
  "ttlDays": 7 | null, "expiresAt": "iso" | null,
  "viewCount": 0, "isOwner": true,
  "viewedAt": "iso" | null,   // when the caller last opened someone else's summary; null for own
  "createdAt": "iso", "updatedAt": "iso"
}

// Error (any non-2xx)
{ "error": { "code": "STRING_CODE", "message": "human readable", "requestId": "…" } }
```

Categories (closed set the LLM must pick from): `Technology, Science, Business, Finance,
Politics, World, Health, Sports, Entertainment, Culture, Education, Lifestyle, Travel,
Food, Opinion, Research, Other`.

## API (all `/api/v1/*` require Bearer auth)

| Method & path | Body / query | Response |
|---|---|---|
| `POST /api/v1/uploads` | `{filename, mimeType:"application/pdf", byteSize}` (≤ 25 MB) | `201 {key, uploadUrl, method:"PUT", headers:{…}, expiresAt}` |
| `POST /api/v1/summaries` | see *Create* | `201 Summary` (synchronous, may take up to ~90 s) |
| `POST /api/v1/summaries/import` | see *Import* | `201 Summary` — saves a summary written elsewhere as given (no summarising) |
| `GET /api/v1/summaries` | `?scope=all|mine|viewed&q=&category=&tag=&visibility=&cursor=&limit=` | `{items:[Summary], nextCursor:string|null}` — the **library**: own summaries + others' public summaries the caller opened (`scope`, default `all`), ordered by activity (created for own, last viewed for others) |
| `GET /api/v1/summaries/:id` | – | `Summary` (owner, or public for anyone signed in) |
| `PATCH /api/v1/summaries/:id` | `{visibility?, ttlDays? (number|null), title?, tags?}` | `Summary` |
| `DELETE /api/v1/summaries/:id` | – | `204` |
| `GET /api/v1/summaries/:id/markdown` | – | `{markdown}` — the source as Markdown; `404 SOURCE_NOT_KEPT` when not kept (or a local file's, for anyone but the owner) |
| `POST /api/v1/summaries/:id/image` | `{imageStyle}` | `Summary` (regenerated OG image) |
| `GET /api/v1/facets` | – | `{categories:[{name,count}], tags:[{name,count}]}` |
| `GET /api/v1/facets?kind=category\|tag&q=&cursor=&limit=` | – | `{items:[{name,count}], nextCursor}` (one facet list, searched + paged) |
| `POST /api/v1/views` | `{slug}` | `Summary` — records that the signed-in user viewed a public summary |
| `POST /api/v1/chat` | `{messages: UIMessage[], summaryId?}` (AI SDK UI message format; `summaryId` focuses the chat on one summary the caller can open, grounded in its original text — 404 otherwise) | AI SDK UI message stream (SSE) |
| `GET /api/v1/account/deletion` | – | `{pendingDeletion, deletionScheduledAt, deletionRequestedAt}` (ISO dates or null) |
| `POST /api/v1/account/deletion` | – | same shape — schedules deletion 7 days out at rxlab-auth and locally (idempotent; needs the `write:profile` scope, else `403 ACCOUNT_DELETION_SCOPE_REQUIRED`) |
| `DELETE /api/v1/account/deletion` | – | same shape — cancels a pending deletion |
| `GET /api/v1/legal/{privacy,terms}` | – (no auth) | `text/markdown` legal document |
| `GET /api/public/summaries/:slug` | – | `Summary` without owner-only fields (`isOwner:false`); 404 if private/expired |

### Create body

```jsonc
{
  "source":
      { "type": "url", "url": "https://…" }                          // server fetches + extracts (Readability)
    | { "type": "webpage", "url": "https://…", "title": "…", "content": "main text", "html": "<main content markup>" /* optional, ≤ 400k */, "siteName": "…", "lang": "en" }
    | { "type": "pdf", "uploadKey": "uploads/…", "filename": "x.pdf", "sourceUrl": "https://…" | null }
    | { "type": "text", "text": "…", "title": "…" },
  "language": "auto" | "en" | "zh-Hans" | "zh-Hant" | "ja" | "ko" | "es" | "fr" | "de",   // output language
  "imageStyle": "graphic" | "illustration",   // default "graphic"
  "ttlDays": 7 | null,                          // default DEFAULT_TTL_DAYS
  "visibility": "public" | "private",           // default "public"
  "deviceReader": true,                         // optional: the client can read pages in an on-device web view
  "followLinks": false,                         // optional: summarise `text` as-is, never read a link inside it
  "keepSourceText": true                        // optional: also keep a local file's text (as Markdown); links and text are always kept
}
```

`webpage.content` is truncated client-side to 60 000 characters.

**Reading links.** A `url` source is read on the server: platform extractor, plain fetch, then
Cloudflare Browser Rendering. A `text` source that contains a URL is first judged by the evaluation
model (`AI_EVALUATION_MODEL`); a share snippet is read the same way as a `url`, anything else is
summarised as text. When the server cannot read the page (`SOURCE_HTTP_ERROR`, `SOURCE_UNREACHABLE`,
`SOURCE_TIMEOUT`, `URL_UNREACHABLE`, `URL_NOT_ALLOWED`, `NO_CONTENT`) and the request has `deviceReader: true`, it answers
`422 SOURCE_NEEDS_DEVICE` with `details: { url, cause }`. The app then loads that URL in an
off-screen `WKWebView` (`WebPageReader`) and resubmits it as a `webpage` source. If the device
can't read it either, the client throws `UnreadablePageError` and the creation flow shows
`OpenInSafariSheet`: a diagram of Safari → Share → Chippy, an **Open in Safari** button, Cancel and,
for pasted text, **Summarise the text instead** (resubmits with `followLinks: false`).
Without `deviceReader`, a `url` source returns the original error and a `text` source falls back to the text.

### Import body

Adds a summary, its tags and the raw source text in one call, for scripts, other apps and agents.
Auth is the same OAuth bearer token as the rest of `/api/v1` (an RxLab access token whose
`client_id` is in `IOS_OAUTH_CLIENT_ID` / `RXLAB_ALLOWED_CLIENT_IDS`; `sub` becomes the owner).
Nothing is summarised: the server only designs the cover image and embeds it for search, and the raw
text is kept as the source document (`GET /api/v1/summaries/:id/markdown`). Counts as one summary
against the allowance (`402 SUMMARY_ALLOWANCE_EXHAUSTED` when used up). Unknown fields are rejected.

```jsonc
{
  "title": "…",                                 // required, ≤ 200
  "summary": "…",                               // required, ≤ 1200
  "text": "raw source text",                    // required, ≤ 200 000
  "tags": ["…"],                                // ≤ 12, lowercased + de-duplicated
  "highlights": ["…"],                          // optional, ≤ 5
  "category": "Technology",                     // optional, one of the categories; default "Other"
  "keywords": ["…"],                            // optional, ≤ 10
  "language": "en",                             // optional BCP-47; default "en"
  "sourceUrl": "https://…" | null,              // optional; sets sourceType "url" and the platform label
  "sourceTitle": "…", "siteName": "…",          // optional
  "imageStyle": "graphic" | "illustration",     // default "graphic"
  "ttlDays": 7 | null,                          // default DEFAULT_TTL_DAYS
  "visibility": "public" | "private"            // default "public"
}
```

```sh
curl -X POST https://<host>/api/v1/summaries/import \
  -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" \
  -d '{"title":"Monarch migration","summary":"Monarchs fly south each autumn.","tags":["butterflies"],"text":"Raw notes…"}'
```

### Chat stream (what iOS must parse)

Standard AI SDK v7 UI message stream, `Content-Type: text/event-stream`, lines of
`data: <json>\n\n`, terminated by `data: [DONE]`. iOS handles these chunk `type`s and
ignores the rest:

* `text-start {id}`, `text-delta {id, delta}`, `text-end {id}`
* `tool-input-available {toolCallId, toolName, input}`
* `tool-output-available {toolCallId, output}`
* `error {errorText}`, `finish`

Request `messages` use the UI message shape:
`{ "id": "…", "role": "user" | "assistant", "parts": [ { "type": "text", "text": "…" } ] }`
(iOS only sends text parts; prior tool results are summarised in text by the client).

Tools the agent exposes (outputs are shown as cards on iOS):

* `searchSummaries({query, category?, tag?, scope: "all"|"mine"|"viewed", limit?})` →
  `{ results: [ {id, slug, title, summary, category, tags, siteName, sourceUrl, shareUrl, ogImageUrl, createdAt, viewedAt?} ] }`
* `getSummary({id})` → `{ summary: Summary-like object incl. contentExcerpt }`

When the owner chats about a local-file summary, the app reads the linked file on device and sends
its text as `localContent` (never stored). Files up to 20,000 characters are inlined in full,
longer ones as an opening preview, and the agent also gets:

* `grepLocalFile({pattern, regex?, caseSensitive?, contextLines?, maxMatches?})` →
  `{ totalLines, matches: [ {line, text, before?, after?} ], totalMatches, truncated }` (or `{error}`)
* `readLocalFile({startLine, endLine?})` → `{ startLine, endLine, totalLines, text: "N: …" lines, truncated }` (or `{error}`)

## Public website

* `GET /s/[slug]` — summary page: OG image hero, title, summary, highlights, tags,
  category, "Read the original" link (source URL, or `/s/[slug]/source` for PDFs),
  expiry note. Includes `og:*`/`twitter:*` meta, `apple-itunes-app` meta with
  `app-clip-bundle-id=com.rxlab.summary-chip.Clip`, and `app-clip-display=card`.
* `GET /s/[slug]/og.png` — 1200×630 PNG (404 when private/expired). When `R2_PUBLIC_BASE_URL`
  (the bucket's custom domain) is set, public summaries get a `302` to
  `${R2_PUBLIC_BASE_URL}/og/<id>-<ts>-<random>.png` and the page's `og:image` and the API's `ogImageUrl` point there
  directly (served by Cloudflare's CDN). Making a summary private copies the image to a new
  random key and deletes the old one, so the old CDN URL dies (the cleanup cron does the same for
  links that expired in the last 7 days; objects carry
  `Cache-Control: public, max-age=300`). Without the env var the route streams from R2.
* `GET /s/[slug]/art.png` — the text-free artwork (`art/<id>-<ts>-<random>.png`), with the same
  access, CDN redirect and key-rotation rules as `og.png`. Artwork never contains text: "graphic"
  is the gradient + SVG background, "illustration" is the image model's drawing (prompted for no
  text at all); the card template lays the headline over either one to make `og.png`.
* `GET /s/[slug]/source` — 302 to a short-lived signed R2 URL of the uploaded PDF.
* Both routes above also accept an optional `Authorization: Bearer` token: when the
  caller is the owner they succeed even if the summary is private (the app needs the
  image for its own private summaries). Private responses use `Cache-Control: private, no-store`.
  iOS must send the bearer header when loading these for owned summaries.
* `GET /.well-known/apple-app-site-association` — `applinks` (`/s/*`) for the app,
  `appclips` for the clip, `webcredentials`.

## OG image generation

1. The summarisation LLM call (structured output) also returns a design:
   palette (4–6 hex colors), light/dark mode, emoji, and a short `headline` (≤ 70 chars).
2. `imageStyle = "graphic"`: a second LLM call writes a small decorative SVG
   (abstract shapes matching the topic, sanitised: no scripts/external refs/foreignObject).
   `imageStyle = "illustration"`: `AI_IMAGE_MODEL` (default setup: `google/gemini-3.1-flash-lite-image`,
   called via `generateText` since Gemini is a language model on the Gateway) draws text-free
   artwork, cover-cropped with `sharp` to 1200×630 (falls back to graphic if unset or it fails).
3. `next/og` `ImageResponse` composes the background (gradient + geometric SVG, or the
   illustration) + accent-bar category label + headline + hairline footer (brand mark, site name)
   → PNG (no emoji), uploaded to R2 at `og/<summaryId>-<ts>-<random>.png`; the bare background is
   uploaded as `art/<summaryId>-<ts>-<random>.png`.

## Sharing on iOS

After generation the user picks:

* **Share as link** — shares only the `shareUrl`; Messages/Slack/etc. render the OG preview.
* **Share as image** — shares the rendered OG PNG plus a caption with the title and `shareUrl`.
* **Copy link**.

## Environment variables (server)

```
AI_MODEL=openai/gpt-5-mini            # default text model (AI Gateway id)
AI_IMAGE_MODEL=google/gemini-3.1-flash-lite-image  # optional, enables "illustration" style
AI_GATEWAY_API_KEY=                   # optional on Vercel (OIDC)
TURSO_DATABASE_URL=libsql://… | file:local.db
TURSO_AUTH_TOKEN=
R2_ACCOUNT_ID= R2_ACCESS_KEY_ID= R2_SECRET_ACCESS_KEY= R2_BUCKET=
R2_PUBLIC_BASE_URL=                   # optional custom domain of the bucket (CDN for public OG images)
AUTH_ISSUER=https://auth.rxlab.app
IOS_OAUTH_CLIENT_ID=
RXLAB_ALLOWED_CLIENT_IDS=
NEXT_PUBLIC_SITE_URL=https://summary.rxlab.app
DEFAULT_TTL_DAYS=7
CRON_SECRET=
APPLE_TEAM_ID=P9KK452K8P
APP_STORE_ID=                         # optional, for the smart banner
```
