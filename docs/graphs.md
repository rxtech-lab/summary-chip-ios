# Graphs

A graph is a library item (`kind = "graph"`) of nodes joined by edges. Its document lives in the `graphs` table
(1:1 with `summaries`). The summary row holds the card's text, the cover and sharing. Contract:
`server/lib/contracts/graph.ts`; Swift mirror: `Packages/SummaryKit/Sources/SummaryKit/Models/Graph.swift`.

## Document

```jsonc
{
  "version": 1,
  "title": "Computing pioneers",                 // ≤ 200
  "description": "Who built what",               // optional, ≤ 1200; else the card describes the graph's size
  "nodes": [{
    "id": "ada",                                 // letters, digits, _ . : -; ≤ 120
    "label": "Ada Lovelace",                     // what the graph shows
    "types": ["Person"],                         // what (n:Person) matches
    "color": "#AA3388",                          // optional; else a colour per first type
    "properties": { "born": 1815, "address": { "city": "London" } },  // any JSON, ≤ 20 000 characters
    "images": [{ "url": "https://…", "caption": "…", "credit": "…" }], // ≤ 12, https only
    "view": { "root": "r", "elements": { "r": { "type": "Callout", "props": { "title": "…", "text": "…" } } } }
  }],
  "edges": [{
    "id": "e1", "source": "ada", "target": "babbage",
    "label": "WORKED_WITH",                      // what [r:WORKED_WITH] matches
    "directed": false,                           // default true; undirected edges are walked both ways
    "color": null, "properties": {}, "images": [], "view": null
  }],
  "queries": [{ "id": "people", "name": "People", "description": null, "query": "MATCH (n:Person) RETURN n" }]
}
```

Limits: 2000 nodes, 6000 edges, 100 saved queries and 3 000 000 characters of JSON, so a save fits a Vercel
Function's 4.5 MB request body. `view` uses the JSON catalog of a trip's custom views (`lib/contracts/trip-view.ts`)
and is drawn by `NativeJSONViewRenderer`. Without a `view`, the app still renders `properties` natively as rows.

Images go through presigned uploads: `POST /api/v1/uploads`, `PUT` the bytes to the returned URL, then
`POST /api/v1/graphs/:id/images {uploadKey}` for a lasting URL. They never pass through a function's request body.

## API

| Route | Does |
|---|---|
| `GET /api/v1/graphs` | The caller's graphs, most recently changed first |
| `POST /api/v1/graphs` | `{document, visibility}`; designs a cover. Free |
| `GET /api/v1/graphs/:id` | The graph, for anyone who can read its summary. `selection` is sent to the owner only |
| `DELETE /api/v1/graphs/:id` | Deletes the graph and its summary |
| `POST /api/v1/graphs/:id/operations` | `{operations, revision?}`; owner only. One change, one version |
| `POST /api/v1/graphs/:id/query` | `{query}`; anyone who can read the graph. `{result: {nodeIds, edgeIds, rowCount, rows, truncated}}` |
| `PUT /api/v1/graphs/:id/selection` | `{selection \| null}`; owner only. Adds no version |
| `POST /api/v1/graphs/:id/images` | `{uploadKey}`; owner only. `{image: {url, width, height, byteSize}}` |

Operations: `set_meta`, `upsert_node`, `update_node`, `upsert_edge`, `update_edge`, `upsert_query`, and
`delete {collection: nodes|edges|queries, id}`. `update_*` takes `{id, changes}`: properties merge and a null removes
one. Deleting a node removes its edges. With `revision`, a stale edit is `409 GRAPH_REVISION_CONFLICT`; without it, the
edit applies to the latest document. An edit that breaks the graph is `422 GRAPH_INVALID` with `details.issues`.

Versions and restore go through the shared `/api/v1/summaries/:id/versions` routes.

## Queries

A read-only subset of Cypher, run in memory on the server (`lib/graph/query.ts`).

```
MATCH (a:Person {city: "Paris"})-[r:KNOWS*1..2]->(b), (b)-->(c)
WHERE a.age >= 30 AND NOT b.name CONTAINS "x"
RETURN a, r, b.name AS name
LIMIT 20
```

- Relationships: `-[r:A|B]->`, `<-[r]-`, `-[r]-`, `-->`, `<--`, `--`, and `*`, `*2`, `*1..3`, `*..3` (at most 8 hops; 5 when open). A path doesn't walk the same edge twice.
- `WHERE`: `= <> != < <= > >=`, `CONTAINS`, `STARTS WITH`, `ENDS WITH`, `IN`, `IS [NOT] NULL`, `AND`, `OR`, `NOT`.
- `n.a.b` reads properties. `id`, `label`, `types`, `source` and `target` read the element's own fields when no property has that name.
- Functions: `id`, `label`, `type`, `types`, `labels`, `degree`, `size`, `toLower`, `toUpper`.
- Types and relationship labels match case-insensitively; property values don't.
- The result lights up what `RETURN` names. Without `RETURN`, or with `RETURN *`, it's everything matched, anonymous elements included.
- Anything that writes (`SET`, `DELETE`, `CREATE`…) is a syntax error. Bad syntax is `422 GRAPH_QUERY_INVALID`.
- Work is capped at 500 000 steps and 5000 matches: past that the search stops and returns `truncated: true`. The response carries at most 50 rows.

## Selection

`graphs.selection` is what the view picks out: `{mode: highlight|isolate, nodeIds, edgeIds, query}`. `highlight` dims the
rest and `isolate` hides it, keeping the ends of a picked edge. It is view state, so it adds no version and only the
owner sees it. Ids of elements deleted later are dropped when it's read.

## Agents

- **In-app chat** (`graphId` on `POST /api/v1/chat`, `lib/ai/graph-agent.ts`): `updateGraph`, `queryGraph`, `selectGraphElements`, `readGraphElements`. A selection reaches the screen as soon as the tool returns. Above 30 000 characters the agent gets an outline instead of the whole document.
- **Node reports** (`writeReport`, `lib/ai/report-writer.ts`): the writer loads the requested node, every edge touching it, and the full data of its directly connected nodes from the owned graph, regardless of map selection. Reports describe these relationships and consider them in the analysis and risks, preserving edge direction and distinguishing supplied graph claims from independently verified facts. Custom UI definitions and unrelated nodes are excluded.
- **MCP** (`lib/graph/mcp.ts`): `list_graphs`, `get_graph`, `create_graph`, `update_graph`, `query_graph`, `select_graph_elements`, `upload_graph_image`. The app has no push channel for these, so a change appears when the screen next loads, returns to the foreground or is refreshed.

## App

`summary-chip/Graph/`. The graph is drawn in a SwiftUI `Canvas` with its own projection (`GraphScene.swift` in SummaryKit), which is what lets a popover point at an element:

- **3D:** nodes arranged around a sphere, connected ones pulled together. The sphere itself is never drawn: the graph floats in empty space with straight edges, and whatever is behind dims for depth. A drag spins it, a pinch or the buttons zoom.
- **2D:** a force-directed plane. A drag pans, a pinch or the buttons zoom.
- **Tap a node or edge:** the camera zooms to it and its info opens: a half sheet on compact width (iPhone), a popover otherwise (macOS, iPad, a wide iPhone or foldable).
- **Large graphs:** above 800 edges they're drawn without arrowheads, above 200 nodes without thumbnails, and above 100 nodes the canvas exposes no per-node accessibility elements. The Elements sheet lists everything.

`--preview-graph` opens the real screen against an in-memory API (`GraphPreviewHost.swift`). The UI tests run against it.
