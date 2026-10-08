# LaTeX papers

A paper is a library item (`summaries.kind = "paper"`) whose LaTeX source lives in the `papers`
table: a project of text files and S3 image references compiled from one main `.tex` file into one PDF. Users write it
in the app with a live PDF preview; agents write it over MCP. The zod schema in
`server/lib/contracts/paper.ts` is the source of truth; `Packages/SummaryKit/Sources/SummaryKit/Models/Paper.swift`
mirrors it.

## Project

| Field | Type | Notes |
|---|---|---|
| `title` | string ≤ 200 | The library item's title. A new paper without one takes the main file's `\title{…}` |
| `files` | `{ path, content?, asset? }[]`, 1–60 | Text: ≤ 800,000 characters together, each ≤ 400,000. Images: ≤ 10 MiB each, 25 MiB together |
| `mainFile` | path | The `.tex` file compilation starts from; must be one of `files` |
| `compiler` | `pdflatex` (default) \| `xelatex` \| `lualatex` | xelatex/lualatex for system fonts and CJK |

Paths are relative and `/`-separated (`chapters/intro.tex`, at most 5 folders, letters, digits and
`. _ -`, no `..`) and end in a text extension: `tex bib sty cls bst bbx cbx lbx def cfg clo ist tikz
txt csv tsv dat md`, or an image extension: `png jpg jpeg pdf`. The main file pulls the others in
with `\input`/`\include`, `\bibliography`, `\usepackage` and `\includegraphics`, so the whole
project becomes **one PDF**.

## Images and figures

The editor's **More → Add Image** menu entry opens a dedicated figure sheet with a file picker,
preview, caption, and figure path. Dropping an image onto the editor opens the same sheet with
the image preselected; the image section also accepts drops for adding or replacing an image.
Add one image at a time. Images remain local until Save uploads them and includes the figure
in the open TeX file (or the main file). Imports enforce the file and combined image limits,
avoid existing asset paths, and stay disabled for shared papers and version previews.

Image bytes go directly to S3-compatible storage through a presigned PUT. The app uses
`POST /api/v1/uploads`; agents use `create_upload`. Both return a key, upload URL and required
headers. After uploading, add a file with an empty `content` and an asset reference:

```json
{
  "path": "images/result.png",
  "asset": { "key": "uploads/…", "mimeType": "image/png", "byteSize": 12345 }
}
```

The save checks upload ownership, completion, size, MIME type and the image signature. It copies
the bytes to `papers/<id>/assets/<sha256>-<upload-uuid>.<ext>` and returns that immutable key. Working copies and
versions hold only references. Reusing the original upload URL cannot overwrite saved images.
Removed images remain available to earlier versions; deleting the paper deletes all its image
objects. Unattached staging uploads are removed by the existing cleanup cron.

Load `\usepackage{graphicx}` and use `\includegraphics[width=0.8\linewidth]{images/result.png}`.
TikZ and pgfplots run in the same compiler: load `\usepackage{tikz}` or
`\usepackage{pgfplots}` (with `\pgfplotsset{compat=1.18}`), then write a `tikzpicture` or `axis`
environment. Figure files (`.tex`/`.tikz`) and plot data (`.csv`/`.tsv`/`.dat`) are text files.
The compiler reads images from private S3 storage and passes their bytes using the provider's
base64 `file` resource mode; image bytes are never sent in paper-save or MCP JSON.

The summary row is derived from the source on every save: `summary` is the abstract (else the
opening text), `highlights` the first five `\chapter`/`\section` titles, `keywords` the
`\keywords{…}` list, and `content_text` the text without commands (search, embeddings, chat).
Papers are free, private by default, and their link never expires. New papers start from a
template: `article` (default: `main.tex`, `sections/introduction.tex`, `references.bib`), `report`
(chapters) or `blank`.

## Working copy and versions

The `papers` row is the **working copy**: what the editor autosaves to and what agents edit. Its
`revision` counts saves (compare-and-swap: a save made on an older revision is
`409 PAPER_REVISION_CONFLICT` with the current `details.revision`). Versions use the shared history
(`document_versions`, see ARCHITECTURE → Versions) with the paper's `{ title, files, mainFile,
compiler }` as content:

| Change | Working copy | Version |
|---|---|---|
| Creating the paper | revision 0 | version 1 (`owner`, or `agent` over MCP) |
| The app's autosave (`PUT /papers/:id`, ~1 s after typing stops) | revision + 1 | none; `hasUnversionedChanges: true` |
| Leaving the paper in the app (`POST /papers/:id/versions`) | – | one `owner` version for all the edits since the last one; none when the source ended up as it was |
| Every MCP `update_paper` call | revision + 1 | its own `agent` version |
| Restoring a version | revision + 1 | a `restore` version |

`papers.versioned_revision` is the revision the latest version holds. An agent edit or a restore
that lands on top of manual edits not saved as a version yet first saves those as an `owner`
version, so a user's edits and an agent's are never folded into one version.

## Compiling

Compilation runs on [latex-on-http](https://github.com/YtoTech/latex-on-http) (`POST
/builds/sync`, a full TeX Live; BibTeX runs when the project has a bibliography), the hosted
`https://latex.ytotech.com` by default. For production, self-host it (`docker run -p 8080:8080
yoant/latexonhttp`) and set `LATEX_COMPILE_URL`; `LATEX_COMPILER=mock` (and tests) compile every
project into a blank page. The provider sits behind `lib/latex/compiler.ts`.

* **Preview** (`GET /papers/:id/pdf`): TeX recovers from errors the way an editor's preview does and
  still returns a PDF when it can. Only a compile that produces no PDF is `422 LATEX_COMPILE_FAILED`,
  with `details.errors` (`[{ file, line, message }]`, `file` a project path or null) and
  `details.log` (the log's last 6,000 characters). The working copy's last PDF is kept in R2
  (`papers/<id>/<hash>.pdf`, keyed by the source's hash), so an unchanged paper downloads at once.
  `X-Paper-Revision` says which revision it is. `?version=` compiles a saved version (owner only;
  not kept).
* **Check** (`POST /papers/:id/check`, MCP `compile_paper`): stops at the first error and reports it:
  `{ ok: true, revision, byteSize }` or `{ ok: false, revision, errors, log }`.
* The service being down is `503 LATEX_UNAVAILABLE`.

## Export, languages and rendering

The toolbar's **More → Export** entry opens a sheet with PDF / Word (`.docx`) and language dropdowns.
Word uses Pandoc in an isolated WASM worker and produces editable paragraphs, headings, tables,
and supported equations. It uses the paper's private assets and included files. TikZ and pgfplots
must be replaced with images for Word; unresolved content fails export instead of being silently
discarded. PDF retains native LaTeX diagrams. Word and PDF can paginate differently.

**More → Language** manages saved translations in English, Simplified/Traditional Chinese,
Japanese, Korean, Spanish, French, and German, matching trip languages. Translating uses points;
reading or exporting never starts a paid translation. Only human prose is translated; LaTeX
commands, equations, citation keys, file paths, assets and bibliography records stay intact.
The original source is editable; translated readings are read-only. Source edits mark translations
outdated; updating reuses unchanged prose. An outdated/missing export language returns
`409 PAPER_TRANSLATION_OUTDATED`. `lang=original` always chooses the source language; omitted
`lang` follows the owner's selected reading (other viewers receive the original by default).

**More → Rendering Options** and the export sheet's **Rendering Options** entry open the same
dedicated settings sheet. Options cover one/two columns, column gap, A4/Letter/Legal/A5 paper,
orientation, four margins, original/serif/sans/monospace fonts, body/heading sizes, heading color,
line/paragraph spacing, first-line indent, alignment, hyphenation, section numbering, contents
and depth, title page, page-number placement, header and footer text. Presets include Standard,
Two-column Paper and Comfortable Reading. Custom rendering is opt-in; disabling it restores
the source's native layout. Settings affect the live preview and both exports, including saved
versions. They are stored separately from source history, do not advance its revision and do
not invalidate translations. PDF cache keys include rendered layout.

Custom rendering and translated PDFs use XeLaTeX. The compiler needs `geometry`, `fontspec`,
`setspace`, `ragged2e`, `xcolor`, `titlesec`, `fancyhdr`, TeX Gyre OTF fonts and CJK fonts for those
languages (`xeCJK`; Noto Serif CJK or Fandol/HaranoAji/UnBatang fallbacks). Custom document classes
may conflict with these packages; turning off custom rendering preserves their own layout.
Apply migrations `0028_paper_translations` and `0029_paper_rendering` before deploying this API.
The export route traces the Pandoc worker and WASM files into the deployment; no host Pandoc
installation is required.

## References

Every bibliography entry (each entry of the `.bib` files, and each `\bibitem` of a
`thebibliography`) is fact-checked by an agent (`lib/ai/reference-agent.ts`) that opens the entry's
`url`, DOI (as `https://doi.org/…`) or arXiv id in Cloudflare Browser Rendering (a plain fetch first
gives the HTTP status; `lib/services/paper-references.ts` → `openReferenceLink`), searches the web
for the title and authors, and reads the sentences that `\cite` it. A reference that doesn't hold up
gets `status: "error"` with one `issue`:

| `issue` | Meaning |
|---|---|
| `link_not_found` | The URL or DOI doesn't open (404/410, unknown host). |
| `reference_not_found` | No work with this title and these authors exists. |
| `unreliable_source` | The work exists but isn't a reliable reference. |
| `link_mismatch` | The link opens on a different work. |
| `misreference` | The entry gets the work wrong (authors, year, venue), or the citing sentences claim what it isn't about. |

Checks are kept in `paper_reference_checks`, keyed by a hash of the entry's content (type and
fields, not its key or layout). A save checks only the entries with no check yet (new or changed
ones), at most 40 per save, four at a time, and forgets the checks of entries it removed. Editing
the text around a citation isn't a reference change. A check that fails to finish leaves the entry
`unchecked` (retried by the next save); one stuck `checking` for 10 minutes is claimed again.

| Save | When the check runs |
|---|---|
| The app's autosave, a restore, creating a paper in the app | After the response. An autosave waits until the bibliography has stayed the same for 20 s (typing), then checks the entries still there. |
| MCP `create_paper`, `update_paper` | Before answering, for up to 100 s (the rest finish after the response). The save always goes through; the answer has a `warning` listing each reference error and asking the agent to rewrite it. |

`Paper.references` (owner only; `[]` for others) lists every entry in file order:
`{ key, file, line, title, url, status: unchecked | checking | verified | error, issue, message, checkedAt }`.
The editor refreshes it while checks run.

## API

| Method & path | Body | Response |
|---|---|---|
| `GET /api/v1/papers` | – | `{ papers: [{ id, slug, title, mainFile, fileCount, revision, updatedAt }] }`, most recently edited first |
| `POST /api/v1/papers` | `{ title?, files?, mainFile?, compiler?, template?, visibility? }` | `201 { paper: Paper }` |
| `GET /api/v1/papers/:id` | – | `{ paper: Paper }` (owner, or read-only for anyone who may open it) |
| `PUT /api/v1/papers/:id` | `{ title, files, mainFile, compiler, revision }` | `{ paper: Paper }` (autosave; no version) |
| `DELETE /api/v1/papers/:id` | – | `204` (versions and PDF go with it) |
| `POST /api/v1/papers/:id/versions` | – | `{ paper: Paper, version: number \| null }` |
| `GET /api/v1/papers/:id/pdf?version=` | – | `application/pdf`, or `422 LATEX_COMPILE_FAILED` |
| `GET /api/v1/papers/:id/export?format=pdf\|docx&lang=original\|…&version=` | – | PDF/Word attachment, `Content-Language`, `X-Paper-Revision` for current source |
| `POST /api/v1/papers/:id/export` | `{ format?, lang?, version?, rendering? }` | Same attachment; optional per-export rendering override does not change saved settings |
| `PUT /api/v1/papers/:id/rendering` | Rendering options (`server/lib/contracts/paper-rendering.ts`) | `{ paper: Paper }`; owner only, source revision unchanged |
| `GET /api/v1/papers/:id/translations` | – | `{ originalLanguage, items: [{ language, upToDate, translating }] }` |
| `POST /api/v1/papers/:id/translations` | `{ language: en\|zh-Hans\|zh-Hant\|ja\|ko\|es\|fr\|de\|null }` | `{ paper: Paper }`; owner only, `null` selects original |
| `GET /api/v1/papers/:id/assets?path=images/result.png&version=` | – | Image bytes for an authorized viewer; saved versions are owner-only |
| `POST /api/v1/papers/:id/check` | – | `{ ok, revision, errors?, log?, byteSize? }` |
| `GET /s/:key/paper.pdf` | – | The PDF for whoever the share link lets in |

Versions are listed, read and restored under `/api/v1/summaries/:id/versions` (restore answers
`{ version, summary, trip, paper }`).

```jsonc
// Paper
{
  "id": "uuid", "slug": "a1B2c3D4e5", "shareUrl": "https://summary.rxlab.app/s/a1B2c3D4e5",
  "revision": 12, "version": 4, "hasUnversionedChanges": true,
  "visibility": "private", "isOwner": true,
  "title": "Quantum Gears", "mainFile": "main.tex", "compiler": "pdflatex",
  "files": [{ "path": "main.tex", "content": "\\documentclass{article}…" }],
  "createdAt": "…", "updatedAt": "…", "likedAt": null
}
```

## MCP

| Tool | What it does |
|---|---|
| `list_papers` | The user's papers. |
| `get_paper` | The working copy (`paths` limits which files' content comes back). |
| `create_paper` | A new paper from files, or a template. |
| `update_paper` | Operations in order, as one version: `write_file`, `edit_file` (exact find-and-replace; `find` must occur once unless `all`), `delete_file`, `rename_file`, `set_main_file`, `set_compiler`, `set_title`. An operation that can't apply is `PAPER_EDIT_FAILED` naming it; nothing is saved. New or changed references are checked before it answers; reference errors come back as a `warning` (the edit is saved). |
| `compile_paper` | The strict check, so the agent can fix errors by file and line. |

## Apps

The paper opens from the library (`kind == .paper`) in `PaperDetailView`:

* **iPad (regular width) and Mac**: the editor and the PDF preview side by side. Drag the divider
  to resize either area; the app remembers the split and keeps both panes visible in narrow
  windows. The divider also supports accessibility adjustments. The preview recompiles after
  each autosave and continues fitting its pane unless the reader has zoomed manually.
* **iPhone**: the editor fills the screen; the toolbar's **PDF** button shows the preview in a sheet.
* Files are picked from a menu, added and renamed in sheets; **More** also has **Check LaTeX**
  (lists errors by file and line), **Versions** (the shared history sheet: view and restore), and
  **Export** (PDF/Word and language options).
* **More** contains **Add Image**, **Share**, **Language** and **Rendering Options**. Export
  also links to rendering settings and translation management.
* **Add Image** opens a dedicated sheet with a native file picker and preview. **Add Figure**
  opens a TikZ or pgfplots sheet with editable starter code. Saving loads the required package,
  creates a figure `.tex` file and includes it in the open TeX file (or the main file). Imported
  assets show an image/PDF preview instead of a text editor. Upload/save status appears as an
  overlay, with mobile selection, success and error haptics.
* **Replace Image** opens its own sheet and updates the existing asset path. Its figure reference
  keeps working, while previous versions retain the original image.
* **The editor** (`PaperSourceEditor`, TextKit 1 on both platforms; grammar, completion, hover
  text and bracket matching in SummaryKit's `LaTeX/`):
  * **Highlighting**: `.tex`/`.sty`/`.cls` files colour commands, environments, keys, headings,
    math and comments; `.bib` files colour entry types, keys and fields.
  * **Brackets**: the bracket at the caret and its partner are marked yellow (red when it has
    none); `\{`, `\}` and brackets in comments don't count. Typing `{` adds its `}`, typing `}`
    steps over it, and deleting a `{` before its `}` deletes both.
  * **Line numbers** in a gutter (an `NSRulerView` on Mac).
  * **Errors**: the latest compile's errors for the open file tint their lines, number them in red
    and show the message in a pill at the line's end.
  * **Completion with descriptions**: typing a command (`\sec`) or inside `\begin{`, `\end{`
    (innermost open environment first), `\cite{`, `\ref{`, `\input{`, `\includegraphics{`,
    `\bibliography{` or `\usepackage{` offers built-in commands plus the paper's own
    `\newcommand`s, labels, `.bib` keys (author, year, title) and files, each described. Picking
    one adds its braces, and a new environment gets its `\end{…}`. On iPhone and iPad they sit in
    a bar over the keyboard (which otherwise describes the word or error at the caret, then shows
    `\ { } $ [ ] _ ^ & % ~`); on Mac a list opens under the caret with the selected description
    below (arrows move, Return/Tab/click pick, Esc closes or opens it).
  * **Hover** (Mac, iPad pointer): a card describes the word under the pointer (a command's
    signature and purpose or where the paper defines it, an environment, a package, a citation's
    entry, where a label is), flags citations and references the paper lacks, and lists the
    errors on that line.
  * `--preview-paper-editor` (Debug) opens the editor on a sample paper without a session;
    `PaperEditorUITests` (iOS and Mac) drive it.
* Edits autosave about a second after typing stops. Leaving the paper saves them as one version.
  While it is open, the editor checks for agent edits every few seconds and on returning to the
  app, and reloads them when nothing is waiting to be saved.
* **References**: the preview highlights each reference with an error in the PDF's bibliography
  (found by its title's opening words); hovering one on Mac or with an iPad pointer, or tapping it,
  shows a popover with the issue and what to fix. A capsule under the preview counts the errors
  (or says references are being checked) and opens the **References** sheet (also in the More
  menu), which lists every entry with its check; choosing one opens its entry in the editor.
  **Export** asks for confirmation while references have errors.
