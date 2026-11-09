# Rich documents

A rich document is a library item (`kind = "rich_document"`) made of blocks rendered top to bottom. Its document
lives in the `rich_documents` table (1:1 with `summaries`); the summary row holds the card's text, the cover and
sharing. Contract: `server/lib/contracts/rich-document.ts`; Swift mirror: `Packages/SummaryKit/Sources/SummaryKit/Models/RichDocument.swift`; Markdown conversion: `server/lib/rich-document/markdown.ts`.

## Document

```jsonc
{
  "version": 1,
  "title": "Field notes",                       // ≤ 200
  "description": null,                          // optional, ≤ 1200; else the card uses the opening text
  "blocks": [{
    "id": "b1",                                 // letters, digits, _ . : -; ≤ 120
    "type": "text",                             // text | image | video | audio
    "align": "leading",                         // leading | center | trailing (default leading)
    "columns": [                                // 1 or 2, side by side (stacked on narrow screens)
      { "markdown": "## Intro\n\nHello **world**." }
    ],
    "children": [{ "type": "link", "title": "Source", "url": "https://example.com" }]  // ≤ 20, shown under the block
  }, {
    "id": "b2", "type": "video", "align": "center",
    "columns": [{ "url": "https://…/clip.mp4", "posterUrl": "https://…/still.jpg", "caption": "Dawn" }],
    "children": []
  }]
}
```

- A **text** column needs `markdown` (CommonMark plus GitHub tables, task lists and strikethrough) and no `url`.
- An **image / video / audio** column needs an https `url` and no `markdown`; `caption` is optional, `alt` is for images,
  `posterUrl` for videos only.
- Link children are `http(s)` or `mailto` URLs. Child types are a discriminated union so more can be added later.
- Limits: 500 blocks, 50 000 characters of Markdown per column, 2 000 000 characters of JSON in all (a save fits a
  Vercel Function's 4.5 MB body). Images go through presigned uploads: `POST /api/v1/uploads`, `PUT` the bytes, then
  `POST /api/v1/rich-documents/:id/images {uploadKey}` for a lasting URL. Video and audio are linked by https URL.
- The web renders Markdown without raw HTML, so a document can't inject markup.

## Markdown

Markdown is the primary way in and out: a document can be created from it, blocks inserted from it, and
`get_rich_document` / `GET …?format=markdown` return it. Conversion rules:

| Markdown | Becomes |
|---|---|
| Text, until the next media line, container or `#` / `##` heading | A text block (headings start a new block, so sections are addressable) |
| A line with only `![alt](https://… "caption")` | A media block: `video` for `.mp4 .m4v .mov .webm .m3u8`, `audio` for `.mp3 .m4a .aac .wav .ogg .oga .flac .opus`, else `image` |
| Two such lines in a row, same type | One two-column media block |
| Lines with only `[title](url)` right after a media block | That block's link children |
| `::: columns` / `::: center` / `::: trailing` (combinable) … `+++` … `:::` | One block; `+++` starts the second column. Media when every column is one media line, text otherwise |
| Fenced code | Always text |
| The first line's `# heading` on create | The title, when no `title` is given |

Exporting writes each block so it reads back as the same block (ids aside). Link children of a text block export as
link lines and read back as text.

## API

| Route | Does |
|---|---|
| `GET /api/v1/rich-documents` | The caller's documents, most recently changed first |
| `POST /api/v1/rich-documents` | `{document}` or `{markdown, title?, description?}`, plus `visibility`; designs a cover. Free |
| `GET /api/v1/rich-documents/:id` | The document, for anyone who can read its summary. `?format=markdown` returns Markdown |
| `DELETE /api/v1/rich-documents/:id` | Deletes the document and its summary |
| `POST /api/v1/rich-documents/:id/operations` | `{operations, revision?}`; owner only. One change, one version |
| `POST /api/v1/rich-documents/:id/images` | `{uploadKey}`; owner only. `{image: {url, width, height, byteSize}}` |

Operations: `set_meta`, `upsert_block` (same id replaces in place, or moves with `after`; new id inserts),
`update_block {id, changes}` (replaces `type`, `align`, `columns` or `children`), `move_block {id, after}`,
`delete_block {id}`, `insert_markdown {markdown, after}` and `replace_markdown {markdown}`. `after` is a block id,
`null` for first, omitted for last. With `revision`, a stale edit is `409 RICH_DOCUMENT_REVISION_CONFLICT`; an edit that
breaks the document is `422 RICH_DOCUMENT_INVALID` with `details.issues`.

Versions and restore go through the shared `/api/v1/summaries/:id/versions` routes.

## MCP

`list_rich_documents`, `get_rich_document`, `create_rich_document`, `update_rich_document`, `delete_rich_document` and
`upload_rich_document_image` (`server/lib/rich-document/mcp.ts`).

## Web

The share page (`/s/:slug`) renders the blocks in full (`server/app/s/[slug]/rich-document.tsx`).

## App

`kind = "rich_document"` is its own document type in the apps: `SummaryKind.richDocument`, the library's
**Documents** filter and a *Document* badge. Swift mirror: `Packages/SummaryKit/Sources/SummaryKit/Models/RichDocument.swift`.
`summary-chip/RichDocument/RichDocumentDetailView.swift` renders the blocks natively (Markdown text, images, video
that loads on play, an audio row, link buttons). Two columns sit side by side, and they stack on compact width.
Its menu has Refresh, Share…, Export Markdown…, Delete Document and version history. Block types from a newer server
are skipped. The library's **New** menu has *Document* (`summary-chip/RichDocument/NewRichDocumentSheet.swift`), which creates
one from a title and Markdown. The app has no block editor; agents edit over MCP, and the screen refreshes when it returns to the foreground.
