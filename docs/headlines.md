# Editorial headlines

`GET /api/v1/summaries/headlines` uses the existing bearer authentication and returns only the caller's own chips. Responses use `Cache-Control: no-store`.

The latest 50 chips whose kind is `summary` or `podcast` are evaluated together using `AI_EVALUATION_MODEL` (the existing decision model). Each receives an integer score from 0–100. The server sorts by `score × 0.5^(ageHours/24)`, then creation time and ID descending. The first is today's highlight; it changes when the ranking or candidate set changes. All other kinds are excluded. Private chips remain private and can be shown only by the authenticated account's app/widget.

Response: `{ generatedAt: string | null, pending: boolean, items: Headline[], highlighted: Headline | null }`.
A Headline is `{ id: string, title: string, kind: "summary" | "podcast", shareUrl: string, createdAt: string, score: integer }`.
No chips returns `items: []`, `highlighted: null`, `pending: false`. Missing or obsolete ranking returns no items and `pending: true`, and schedules a refresh. Clients poll at bounded intervals. Disabled or failed decision evaluation never fabricates a production score. Existing auth errors apply.

Every summary/podcast insertion, including imports, Siri and daily podcast generation, schedules a fresh ranking after the response. A candidate revision and monotonic write fence prevent older evaluation results replacing newer results. Deletions and edits invalidate the revision; the next read schedules recomputation. Apply migration 0038 before deploying.

The app labels the selected card Editor's Pick. The headline widget fetches the same authenticated result every 15 minutes (subject to WidgetKit scheduling), links to its chip, and hides cached content when the shared session ends. Siri's existing Add Summary shortcut uses the same insertion path.
