import { createHash } from "node:crypto";
import { and, eq, inArray, lt, notInArray } from "drizzle-orm";
import type { AiProvider } from "@/lib/ai/provider";
import type { ReferenceInput, ReferenceLink } from "@/lib/ai/reference-agent";
import type { PaperDocument, PaperReference } from "@/lib/contracts/paper";
import type { Database } from "@/lib/db/client";
import { paperReferenceChecks, papers, summaries, type PaperReferenceCheckRow } from "@/lib/db/schema";
import { renderWithBrowser } from "@/lib/extract/browser";
import { decodeText, fetchPublicDocument, type FetchedDocument } from "@/lib/extract/fetch";
import { scrapeWithFirecrawl } from "@/lib/extract/firecrawl";
import { extractHtml, normalizeWhitespace } from "@/lib/extract/html";
import { extractPdfText } from "@/lib/extract/pdf";
import { assertPublicUrlSyntax } from "@/lib/extract/ssrf";
import { runAfter } from "@/lib/http/after";
import { ApiError } from "@/lib/http/errors";
import { notifyReferenceErrors } from "./notifications";
import { latexToText, stripComments } from "./paper-document";

/* ------------------------------------------------------------------------------------------------
 * Reading the bibliography
 * ---------------------------------------------------------------------------------------------- */

/** One bibliography entry: a `.bib` entry or a `\bibitem` of a `thebibliography`. */
export interface ParsedReference {
  key: string;
  type: string;
  file: string;
  line: number;
  fields: Record<string, string>;
  title: string | null;
  url: string | null;
  /** Identifies the entry's content (its key aside): a check holds until the content changes. */
  hash: string;
  contexts: string[];
}

/** Entries a paper's references are read from, at most; a longer bibliography is checked in part. */
export const MAX_PAPER_REFERENCES = 300;
const MAX_CONTEXTS = 3;
const NON_ENTRIES = new Set(["string", "comment", "preamble"]);

function lineAt(source: string, index: number): number {
  let line = 1;
  for (let at = source.indexOf("\n"); at !== -1 && at < index; at = source.indexOf("\n", at + 1)) line += 1;
  return line;
}

/** The index just past the `}` (or `)`) that closes what opens at `start`, following nested braces. */
function closingIndex(source: string, start: number): number {
  const open = source[start];
  let depth = 0;
  for (let index = start + 1; index < source.length; index += 1) {
    const char = source[index];
    if (char === "{") depth += 1;
    else if (char === "}") {
      if (depth === 0 && open === "{") return index + 1;
      depth -= 1;
    } else if (char === ")" && open === "(" && depth === 0) return index + 1;
  }
  return -1;
}

/** `name = {value} # "more" # macro, …` as a map of lowercase names to raw values; `macros` are the `@string`s. */
function parseFields(body: string, macros: Map<string, string> = new Map()): Record<string, string> {
  const fields: Record<string, string> = {};
  let index = 0;
  while (index < body.length) {
    const match = /\s*,?\s*([A-Za-z][\w:.-]*)\s*=\s*/y;
    match.lastIndex = index;
    const name = match.exec(body);
    if (!name) break;
    index = match.lastIndex;
    const parts: string[] = [];
    for (;;) {
      while (/\s/.test(body[index] ?? "")) index += 1;
      const char = body[index];
      if (char === "{") {
        const end = closingIndex(body, index);
        if (end === -1) return fields;
        parts.push(body.slice(index + 1, end - 1));
        index = end;
      } else if (char === '"') {
        let end = index + 1;
        for (let depth = 0; end < body.length; end += 1) {
          if (body[end] === "{") depth += 1;
          else if (body[end] === "}") depth -= 1;
          else if (body[end] === '"' && depth === 0) break;
        }
        parts.push(body.slice(index + 1, end));
        index = end + 1;
      } else {
        const bare = /[^\s,#}]+/y;
        bare.lastIndex = index;
        const word = bare.exec(body);
        if (!word) break;
        parts.push(macros.get(word[0].toLowerCase()) ?? word[0]);
        index = bare.lastIndex;
      }
      while (/\s/.test(body[index] ?? "")) index += 1;
      if (body[index] !== "#") break;
      index += 1;
    }
    fields[name[1].toLowerCase()] = normalizeWhitespace(parts.join(""));
  }
  return fields;
}

function plain(value: string | undefined, limit = 300): string | null {
  if (!value) return null;
  // Logos are commands latexToText would drop (\TeX, \LaTeX, \BibTeX), and BibTeX's case-protecting
  // braces ({\TeX}book, {Distributed}) join their words rather than split them.
  const unbraced = value.replace(/\\((?:La|Bib)?TeX)\b(?:\{\})?/g, "$1").replace(/(?<!\\[A-Za-z]+\*?)\{([^{}\\]*)\}/g, "$1");
  const text = latexToText(unbraced).slice(0, limit).trim();
  return text || null;
}

function linkOf(fields: Record<string, string>): string | null {
  const url = fields.url?.trim();
  if (url && /^https?:\/\//i.test(url)) return url.replace(/\\([%#&_~])/g, "$1");
  const doi = fields.doi?.trim().replace(/^(?:https?:\/\/(?:dx\.)?doi\.org\/|doi:\s*)/i, "");
  if (doi && /^10\.\d{4,9}\//.test(doi)) return `https://doi.org/${doi}`;
  const eprint = fields.eprint?.trim();
  if (eprint && /arxiv/i.test(fields.archiveprefix ?? fields.eprinttype ?? "")) return `https://arxiv.org/abs/${eprint}`;
  return null;
}

function hashOf(type: string, fields: Record<string, string>): string {
  const sorted = Object.entries(fields).sort(([a], [b]) => a.localeCompare(b));
  return createHash("sha256").update(JSON.stringify([type.toLowerCase(), sorted])).digest("hex").slice(0, 32);
}

function bibEntries(path: string, source: string): ParsedReference[] {
  const entries: ParsedReference[] = [];
  const macros = new Map<string, string>();
  const start = /@\s*([A-Za-z]+)\s*([{(])/g;
  for (let match = start.exec(source); match; match = start.exec(source)) {
    const type = match[1].toLowerCase();
    const open = match.index + match[0].length - 1;
    const end = closingIndex(source, open);
    if (end === -1) break;
    start.lastIndex = end;
    const body = source.slice(open + 1, end - 1);
    if (type === "string") {
      for (const [name, value] of Object.entries(parseFields(body, macros))) macros.set(name, value);
    }
    if (NON_ENTRIES.has(type)) continue;
    const comma = body.indexOf(",");
    const key = (comma === -1 ? body : body.slice(0, comma)).trim();
    if (!key || /\s/.test(key)) continue;
    const fields = parseFields(comma === -1 ? "" : body.slice(comma + 1), macros);
    entries.push({
      key,
      type,
      file: path,
      line: lineAt(source, match.index),
      fields,
      title: plain(fields.title),
      url: linkOf(fields),
      hash: hashOf(type, fields),
      contexts: [],
    });
  }
  return entries;
}

function bibitems(path: string, source: string): ParsedReference[] {
  const entries: ParsedReference[] = [];
  const text = stripComments(source);
  const environment = /\\begin\{thebibliography\}(?:\{[^}]*\})?([\s\S]*?)\\end\{thebibliography\}/g;
  for (let block = environment.exec(text); block; block = environment.exec(text)) {
    const offset = block.index + block[0].indexOf(block[1]);
    const item = /\\bibitem\s*(?:\[[^\]]*\])?\s*\{([^}]+)\}/g;
    const matches = [...block[1].matchAll(item)];
    matches.forEach((match, index) => {
      const from = (match.index ?? 0) + match[0].length;
      const to = matches[index + 1]?.index ?? block[1].length;
      const raw = block[1].slice(from, to).trim();
      const url = /\\(?:url|href)\{([^}]+)\}/.exec(raw)?.[1] ?? null;
      const doi = /\b(10\.\d{4,9}\/[^\s},]+)/.exec(raw)?.[1];
      const fields: Record<string, string> = { text: normalizeWhitespace(raw) };
      entries.push({
        key: match[1].trim(),
        type: "bibitem",
        file: path,
        line: lineAt(source, offset + (match.index ?? 0)),
        fields,
        title: plain(raw),
        url: url && /^https?:\/\//i.test(url) ? url : doi ? `https://doi.org/${doi}` : null,
        hash: hashOf("bibitem", fields),
        contexts: [],
      });
    });
  }
  return entries;
}

const CITE = /\\(?:[A-Za-z]*cite[A-Za-z]*|nocite)\*?(?:\[[^\]]*\]){0,2}\{([^}]*)\}/g;

/** The sentence around each `\cite`, as plain text, by key. */
function citationContexts(document: PaperDocument): Map<string, string[]> {
  const contexts = new Map<string, string[]>();
  for (const file of document.files) {
    if (!file.path.toLowerCase().endsWith(".tex")) continue;
    const source = stripComments(file.content);
    for (const match of source.matchAll(CITE)) {
      const at = match.index ?? 0;
      const before = source.slice(Math.max(0, at - 400), at);
      const after = source.slice(at + match[0].length, at + match[0].length + 200);
      const sentenceStart = Math.max(before.lastIndexOf(". "), before.lastIndexOf("\n\n"));
      const sentenceEnd = after.search(/\.\s|\n\n/);
      const sentence = latexToText(`${before.slice(sentenceStart + 1)} [${match[1]}]${sentenceEnd === -1 ? after : after.slice(0, sentenceEnd + 1)}`).slice(0, 500);
      for (const key of match[1].split(",").map((part) => part.trim()).filter(Boolean)) {
        const list = contexts.get(key) ?? [];
        if (list.length < MAX_CONTEXTS && sentence && !list.includes(sentence)) list.push(sentence);
        contexts.set(key, list);
      }
    }
  }
  return contexts;
}

/**
 * The paper's bibliography: every entry of its `.bib` files and every `\bibitem`, in file order,
 * with the sentences citing each. An entry whose key repeats (a second `.bib` defining it) is
 * listed once, as BibTeX reads it: the first.
 */
export function paperReferences(document: PaperDocument): ParsedReference[] {
  const contexts = citationContexts(document);
  const seen = new Set<string>();
  const entries: ParsedReference[] = [];
  for (const file of [...document.files].sort((a, b) => a.path.localeCompare(b.path))) {
    const lower = file.path.toLowerCase();
    const found = lower.endsWith(".bib") ? bibEntries(file.path, file.content) : lower.endsWith(".tex") ? bibitems(file.path, file.content) : [];
    for (const entry of found) {
      if (seen.has(entry.key) || entries.length >= MAX_PAPER_REFERENCES) continue;
      seen.add(entry.key);
      entries.push({ ...entry, contexts: contexts.get(entry.key) ?? [] });
    }
  }
  return entries;
}

/* ------------------------------------------------------------------------------------------------
 * Opening links
 * ---------------------------------------------------------------------------------------------- */

const LINK_TEXT_CHARS = 20_000;

function httpStatusOf(error: ApiError): number | null {
  const match = /HTTP (\d{3})/.exec(error.message);
  return match ? Number(match[1]) : null;
}

const NOT_PUBLIC: ReferenceLink = { reachable: false, httpStatus: null, note: "The link is not a public web address.", finalUrl: null, title: null, text: "" };

/**
 * Opens a reference's link with Firecrawl when it's configured: it loads the page from Firecrawl's
 * network (in a browser when needed, PDFs included) and reports the page's HTTP status. Without
 * Firecrawl, or when its call fails, the server opens the link itself (`openWithFetch`).
 */
export async function openReferenceLink(url: string): Promise<ReferenceLink> {
  try {
    assertPublicUrlSyntax(url);
  } catch {
    return NOT_PUBLIC;
  }
  const page = await scrapeWithFirecrawl(url);
  if (!page) return openWithFetch(url);
  const status = page.statusCode;
  const gone = status === 404 || status === 410;
  const text = page.markdown.trim();
  const reachable = !gone && (status === null || status < 400 || text.length > 0);
  return {
    reachable,
    httpStatus: status,
    note: gone ? `HTTP ${status}.`
      : !reachable ? `HTTP ${status ?? "error"} and no content.`
      : status !== null && status >= 400 ? `HTTP ${status}; the page may block automated access.`
      : status === null ? "The HTTP status is unknown: check the title and text show the cited work, not an error page."
      : null,
    finalUrl: page.finalUrl ?? url,
    title: page.title,
    text: text.slice(0, LINK_TEXT_CHARS),
  };
}

/**
 * Opens a link from the server: a plain fetch says whether it exists (its HTTP status), and
 * Cloudflare Browser Rendering reads pages that build themselves with JavaScript or turn plain
 * fetches away. When the server's own DNS can't resolve the name or resolves it to a private
 * address (a proxy's fake IPs, split DNS), only the browser opens it: it runs on Cloudflare's
 * network, not ours, so a name that is public by its text alone is safe to hand it.
 */
async function openWithFetch(url: string): Promise<ReferenceLink> {
  let fetched: FetchedDocument | null = null;
  let failure: ApiError | null = null;
  try {
    fetched = await fetchPublicDocument(url, { maxBytes: 8 * 1024 * 1024, timeoutMs: 20_000 });
  } catch (error) {
    if (!(error instanceof ApiError)) throw error;
    // Public by its text (checked by the caller): a private DNS answer only blocks our own fetch.
    if (error.code === "INVALID_URL") return NOT_PUBLIC;
    failure = error;
  }
  const finalUrl = fetched?.url.toString() ?? url;
  if (fetched && (fetched.contentType === "application/pdf" || fetched.contentType === "application/x-pdf")) {
    const pdf = await extractPdfText(fetched.bytes).catch(() => null);
    return { reachable: true, httpStatus: 200, note: "A PDF.", finalUrl, title: pdf?.title ?? null, text: (pdf?.text ?? "").slice(0, LINK_TEXT_CHARS) };
  }
  const status = failure ? httpStatusOf(failure) : 200;
  const gone = status === 404 || status === 410;
  const rendered = gone ? null : await renderWithBrowser(finalUrl);
  const html = rendered ?? (fetched ? decodeText(fetched.bytes, fetched.charset) : null);
  const page = html ? extractHtml(html, finalUrl) : null;
  if (gone || !page) {
    return { reachable: false, httpStatus: status, note: failure?.message ?? "The page had no content.", finalUrl, title: page?.title ?? null, text: page?.text.slice(0, LINK_TEXT_CHARS) ?? "" };
  }
  return {
    reachable: true,
    httpStatus: status,
    note: !failure ? null : status === null
      ? "Only Cloudflare's browser could open it, so the HTTP status is unknown: check the title and text show the cited work, not an error page."
      : `${failure.message} to a plain fetch; it loaded in Cloudflare's browser.`,
    finalUrl,
    title: page.title,
    text: page.text.slice(0, LINK_TEXT_CHARS),
  };
}

/* ------------------------------------------------------------------------------------------------
 * Checks
 * ---------------------------------------------------------------------------------------------- */

/** Entries claimed for checking per save; the rest are claimed by later saves. */
const MAX_CLAIMS_PER_SAVE = 40;
/** Entries checked at once. */
const CHECK_CONCURRENCY = 4;
/** A check that hasn't reported in this long (its function was stopped) is claimed again. */
const STALE_CHECK_MS = 10 * 60 * 1000;
/** After an autosave, how long the bibliography must stay as it is before it's checked (typing). */
const REFERENCE_QUIET_MS = 20_000;
let quietMsOverride: number | undefined;

/** Tests: the autosave's quiet period (0 checks at once); undefined restores the default. */
export function setReferenceQuietMsForTests(value?: number): void {
  quietMsOverride = value;
}

export function referenceQuietMs(): number {
  return quietMsOverride ?? REFERENCE_QUIET_MS;
}
/** How long an MCP edit waits for its checks before answering; the rest finish in the background. */
export const REFERENCE_INLINE_BUDGET_MS = 100_000;

export interface ReferenceCheckDeps {
  ai: AiProvider;
  now: () => Date;
  openLink?: (url: string) => Promise<ReferenceLink>;
}

function toJson(entry: ParsedReference, row: PaperReferenceCheckRow | undefined, now: Date): PaperReference {
  const stale = row?.status === "checking" && now.getTime() - row.startedAt.getTime() > STALE_CHECK_MS;
  return {
    key: entry.key,
    file: entry.file,
    line: entry.line,
    title: entry.title,
    url: entry.url,
    status: !row || stale ? "unchecked" : row.status,
    issue: row?.status === "error" ? row.issue ?? "reference_not_found" : null,
    message: row && row.status !== "checking" ? row.message : null,
    checkedAt: row?.checkedAt?.toISOString() ?? null,
  };
}

/** The working copy's references with their checks. */
export async function referenceStatuses(db: Database, summaryId: string, document: PaperDocument, now = new Date()): Promise<PaperReference[]> {
  const entries = paperReferences(document);
  if (!entries.length) return [];
  const rows = await db.select().from(paperReferenceChecks).where(eq(paperReferenceChecks.summaryId, summaryId));
  const byHash = new Map(rows.map((row) => [row.hash, row]));
  return entries.map((entry) => toJson(entry, byHash.get(entry.hash), now));
}

/**
 * After a save: forgets the checks of entries the paper no longer has and claims the entries not
 * checked yet (new or changed ones, and checks that went stale), returning them.
 */
export async function claimReferences(db: Database, summaryId: string, document: PaperDocument, now: Date): Promise<ParsedReference[]> {
  const entries = paperReferences(document);
  const hashes = [...new Set(entries.map((entry) => entry.hash))];
  await db.delete(paperReferenceChecks).where(hashes.length
    ? and(eq(paperReferenceChecks.summaryId, summaryId), notInArray(paperReferenceChecks.hash, hashes))
    : eq(paperReferenceChecks.summaryId, summaryId));
  if (!hashes.length) return [];
  const rows = await db.select().from(paperReferenceChecks).where(eq(paperReferenceChecks.summaryId, summaryId));
  const byHash = new Map(rows.map((row) => [row.hash, row]));
  const stale = (row: PaperReferenceCheckRow) => row.status === "checking" && now.getTime() - row.startedAt.getTime() > STALE_CHECK_MS;
  const wanted = new Map<string, ParsedReference>();
  for (const entry of entries) {
    const row = byHash.get(entry.hash);
    if ((!row || stale(row)) && !wanted.has(entry.hash) && wanted.size < MAX_CLAIMS_PER_SAVE) wanted.set(entry.hash, entry);
  }
  if (!wanted.size) return [];
  const claimed = [...wanted.values()];
  const staleHashes = claimed.filter((entry) => byHash.has(entry.hash)).map((entry) => entry.hash);
  await db.batch([
    db.insert(paperReferenceChecks)
      .values(claimed.map((entry) => ({ summaryId, hash: entry.hash, status: "checking" as const, startedAt: now })))
      .onConflictDoNothing(),
    ...(staleHashes.length ? [db.update(paperReferenceChecks).set({ startedAt: now })
      .where(and(eq(paperReferenceChecks.summaryId, summaryId), inArray(paperReferenceChecks.hash, staleHashes), lt(paperReferenceChecks.startedAt, new Date(now.getTime() - STALE_CHECK_MS))))] : []),
  ]);
  return claimed;
}

function referenceInput(entry: ParsedReference): ReferenceInput {
  return { key: entry.key, type: entry.type, fields: entry.fields, url: entry.url, contexts: entry.contexts };
}

/** Whether the check found the entry in error (false when it couldn't run or was superseded). */
async function checkOne(db: Database, summaryId: string, entry: ParsedReference, deps: ReferenceCheckDeps): Promise<boolean> {
  const where = and(eq(paperReferenceChecks.summaryId, summaryId), eq(paperReferenceChecks.hash, entry.hash), eq(paperReferenceChecks.status, "checking"));
  const openLink = deps.openLink ?? openReferenceLink;
  const verdict = await deps.ai.checkReference(referenceInput(entry), {
    openLink: (url) => openLink(url).catch((error: unknown) => ({
      reachable: false, httpStatus: null, note: (error as Error).message, finalUrl: null, title: null, text: "",
    })),
  }).catch(() => null);
  if (!verdict) {
    // Unchecked again: the next save that touches the bibliography retries it.
    await db.delete(paperReferenceChecks).where(where);
    return false;
  }
  const result = await db.update(paperReferenceChecks)
    .set({ status: verdict.status, issue: verdict.issue, message: verdict.message.slice(0, 400), checkedAt: deps.now() })
    .where(where);
  return verdict.status === "error" && result.rowsAffected > 0;
}

/** Checks `entries`, a few at a time, then tells the owner about the ones found in error. */
async function checkAll(db: Database, summaryId: string, entries: ParsedReference[], deps: ReferenceCheckDeps): Promise<void> {
  const queue = [...entries];
  const errors: string[] = [];
  const worker = async () => {
    for (let entry = queue.shift(); entry; entry = queue.shift()) {
      if (await checkOne(db, summaryId, entry, deps)) errors.push(entry.key);
    }
  };
  await Promise.all(Array.from({ length: Math.min(CHECK_CONCURRENCY, queue.length) }, worker));
  if (!errors.length) return;
  const order = new Map(entries.map((entry, index) => [entry.key, index]));
  errors.sort((a, b) => order.get(a)! - order.get(b)!);
  try {
    const [paper] = await db.select().from(summaries).where(eq(summaries.id, summaryId));
    if (paper) await notifyReferenceErrors(db, paper, errors);
  } catch {
    console.warn("[paper-references] error notification failed");
  }
}

/** The entries of `claimed` the working copy still has (an autosave since may have changed them). */
async function stillPresent(db: Database, summaryId: string, claimed: ParsedReference[], title: string): Promise<ParsedReference[]> {
  const [row] = await db.select().from(papers).where(eq(papers.summaryId, summaryId)).limit(1);
  if (!row) return [];
  const current = new Set(paperReferences({ title, files: row.files, mainFile: row.mainFile, compiler: row.compiler }).map((entry) => entry.hash));
  return claimed.filter((entry) => current.has(entry.hash));
}

/**
 * The app's autosave: once the bibliography has stayed put for `REFERENCE_QUIET_MS` (the user
 * stopped typing it), checks the claimed entries the paper still has, after the response.
 */
export function checkReferencesLater(db: Database, summaryId: string, title: string, claimed: ParsedReference[], deps: ReferenceCheckDeps, quietMs = referenceQuietMs()): void {
  if (!claimed.length) return;
  runAfter(async () => {
    if (quietMs > 0) await new Promise((resolve) => setTimeout(resolve, quietMs));
    const present = await stillPresent(db, summaryId, claimed, title);
    await checkAll(db, summaryId, present, deps);
  });
}

/**
 * An agent's edit: checks the claimed entries before answering, for up to `budgetMs`; checks
 * still running then finish after the response.
 */
export async function checkReferencesNow(db: Database, summaryId: string, claimed: ParsedReference[], deps: ReferenceCheckDeps, budgetMs = REFERENCE_INLINE_BUDGET_MS): Promise<void> {
  if (!claimed.length) return;
  const job = checkAll(db, summaryId, claimed, deps);
  runAfter(() => job);
  let timer: ReturnType<typeof setTimeout> | undefined;
  await Promise.race([job, new Promise((resolve) => { timer = setTimeout(resolve, budgetMs); })]);
  clearTimeout(timer);
}

/** Why a reference is an error, for an agent. */
export function describeReferenceIssue(reference: PaperReference): string {
  const label = {
    link_not_found: "the link doesn't open",
    reference_not_found: "the work can't be found",
    unreliable_source: "not a reliable source",
    link_mismatch: "the link shows a different work",
    misreference: "misreferenced",
  }[reference.issue ?? "reference_not_found"];
  return `${reference.key} (${reference.file}:${reference.line}): ${label}. ${reference.message ?? ""}`.trim();
}
