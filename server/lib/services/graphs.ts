import { and, eq, sql } from "drizzle-orm";
import type { z } from "zod";
import type { ApiPrincipal } from "@/lib/auth/bearer";
import { normalizeDraft, type SummaryDraft } from "@/lib/ai/summary-schema";
import {
  graphDocumentSchema,
  graphOperationSchema,
  MAX_GRAPH_OPERATIONS,
  type createGraphSchema,
  type GraphDocument,
  type GraphEdge,
  type GraphNode,
  type GraphOperation,
  type graphOperationsRequestSchema,
  type GraphSelection,
} from "@/lib/contracts/graph";
import type { Database } from "@/lib/db/client";
import { graphs, summaries, type GraphRow, type SummaryRow, type Visibility } from "@/lib/db/schema";
import { EXCERPT_LIMIT, SOURCE_TEXT_LIMIT } from "@/lib/extract";
import { GraphQuerySyntaxError, runGraphQuery, type GraphQueryResult } from "@/lib/graph/query";
import { runAfter } from "@/lib/http/after";
import { ApiError } from "@/lib/http/errors";
import { selectCoverTheme } from "./cover-colors";
import { versionStatements, type VersionOptions } from "./document-versions";
import { embedSummary, indexSummary } from "./embeddings";
import { shareUrlFor } from "./serialize";
import { canViewerRead } from "./share-access";
import { coverImages, findSummaryById, getOwnedSummary, insertSummary, resolveDeps, type ServiceDeps } from "./summaries";

export type CreateGraphInput = z.infer<typeof createGraphSchema>;
export type GraphOperationsInput = z.infer<typeof graphOperationsRequestSchema>;
type SaveDeps = Pick<ServiceDeps, "ai" | "now" | "store"> & VersionOptions;

/** `GET /api/v1/graphs/:id`. `selection` is the owner's; others see the graph without it. */
export interface GraphJson {
  id: string;
  slug: string;
  revision: number;
  visibility: Visibility;
  isOwner: boolean;
  createdAt: string;
  updatedAt: string;
  shareUrl: string;
  document: GraphDocument;
  selection: GraphSelection | null;
}

/** One row of `GET /api/v1/graphs`. */
export interface GraphListItem {
  id: string;
  slug: string;
  title: string;
  revision: number;
  updatedAt: string;
  nodeCount: number;
  edgeCount: number;
  queryCount: number;
}

const GRAPH_TAGS = ["graph"];

function graphNotFound(): ApiError {
  return new ApiError(404, "NOT_FOUND", "The graph does not exist");
}

function revisionConflict(current: number): ApiError {
  return new ApiError(409, "GRAPH_REVISION_CONFLICT", `The graph changed since you loaded it (now revision ${current}). Reload it and apply your edit again.`, { revision: current });
}

function issueList(error: z.ZodError) {
  return error.issues.map((issue) => ({ path: issue.path.map(String), message: issue.message }));
}

/** Parses a document after edits; a broken one is `422 GRAPH_INVALID` with the issues in `details`. */
export function validGraphDocument(document: unknown, what = "The edit"): GraphDocument {
  const parsed = graphDocumentSchema.safeParse(document);
  if (parsed.success) return parsed.data;
  const issues = issueList(parsed.error);
  const listed = issues.slice(0, 3).map((issue) => `${issue.path.join(".") || "document"}: ${issue.message}`).join("; ");
  throw new ApiError(422, "GRAPH_INVALID", `${what} leaves the graph invalid: ${listed}`, { issues });
}

/* ------------------------------------------------------------------------------------------------
 * Derived text
 * ---------------------------------------------------------------------------------------------- */

function clip(text: string, limit: number): string {
  return text.length <= limit ? text : `${text.slice(0, limit - 1)}…`;
}

function counted(count: number, one: string, many: string): string {
  return `${count} ${count === 1 ? one : many}`;
}

/** The library card's text: the description, or what the graph holds and its best-connected nodes. */
export function graphDigest(document: GraphDocument): { title: string; summary: string; highlights: string[]; keywords: string[] } {
  const degree = new Map<string, number>();
  for (const edge of document.edges) {
    degree.set(edge.source, (degree.get(edge.source) ?? 0) + 1);
    degree.set(edge.target, (degree.get(edge.target) ?? 0) + 1);
  }
  const hubs = [...document.nodes].sort((a, b) => (degree.get(b.id) ?? 0) - (degree.get(a.id) ?? 0) || a.label.localeCompare(b.label)).slice(0, 5);
  const types = [...new Set(document.nodes.flatMap((node) => node.types))];
  const labels = [...new Set(document.edges.map((edge) => edge.label))];
  const generated = `A graph of ${counted(document.nodes.length, "node", "nodes")} and ${counted(document.edges.length, "edge", "edges")}.`;
  return {
    title: clip(document.title, 200),
    summary: clip(document.description || generated, 1200),
    highlights: hubs.map((node) => clip(`${node.label}: ${counted(degree.get(node.id) ?? 0, "connection", "connections")}`, 300)),
    keywords: [...new Set([...types, ...labels, ...hubs.map((node) => node.label)])].slice(0, 10).map((keyword) => keyword.slice(0, 60)),
  };
}

/** The graph as plain text: what search and embeddings read. */
export function graphText(document: GraphDocument): string {
  const lines = [document.title, document.description ?? ""];
  const labels = new Map(document.nodes.map((node) => [node.id, node.label]));
  for (const node of document.nodes) {
    lines.push(`${node.label}${node.types.length ? ` (${node.types.join(", ")})` : ""}: ${JSON.stringify(node.properties)}`);
  }
  for (const edge of document.edges) {
    lines.push(`${labels.get(edge.source) ?? edge.source} ${edge.label} ${labels.get(edge.target) ?? edge.target}: ${JSON.stringify(edge.properties)}`);
  }
  return lines.filter(Boolean).join("\n");
}

/* ------------------------------------------------------------------------------------------------
 * Read
 * ---------------------------------------------------------------------------------------------- */

/** A selection never names elements deleted after it was made. */
function liveSelection(selection: GraphSelection | null, document: GraphDocument): GraphSelection | null {
  if (!selection) return null;
  const nodes = new Set(document.nodes.map((node) => node.id));
  const edges = new Set(document.edges.map((edge) => edge.id));
  return { ...selection, nodeIds: selection.nodeIds.filter((id) => nodes.has(id)), edgeIds: selection.edgeIds.filter((id) => edges.has(id)) };
}

export function toGraphJson(row: SummaryRow, graph: GraphRow, viewerId: string | null): GraphJson {
  const isOwner = viewerId !== null && viewerId === row.ownerId;
  return {
    id: row.id,
    slug: row.slug,
    revision: graph.revision,
    visibility: row.visibility,
    isOwner,
    createdAt: row.createdAt.toISOString(),
    updatedAt: graph.updatedAt.toISOString(),
    shareUrl: shareUrlFor(row.slug),
    document: graph.document,
    selection: isOwner ? liveSelection(graph.selection, graph.document) : null,
  };
}

async function findGraphRow(db: Database, id: string): Promise<GraphRow | null> {
  const [row] = await db.select().from(graphs).where(eq(graphs.summaryId, id)).limit(1);
  return row ?? null;
}

async function findGraphForViewer(db: Database, id: string, viewerId: string): Promise<{ summary: SummaryRow; graph: GraphRow } | null> {
  const summary = await findSummaryById(db, id);
  if (!summary || summary.kind !== "graph" || !await canViewerRead(db, summary, viewerId)) return null;
  const graph = await findGraphRow(db, id);
  return graph ? { summary, graph } : null;
}

export async function getGraph(db: Database, id: string, viewerId: string): Promise<GraphJson> {
  const found = await findGraphForViewer(db, id, viewerId);
  if (!found) throw graphNotFound();
  return toGraphJson(found.summary, found.graph, viewerId);
}

/** Only the owner edits. */
export async function getOwnedGraph(db: Database, id: string, ownerId: string): Promise<{ summary: SummaryRow; graph: GraphRow }> {
  const summary = await getOwnedSummary(db, id, ownerId).catch((error) => {
    throw error instanceof ApiError && error.code === "NOT_FOUND" ? graphNotFound() : error;
  });
  if (summary.kind !== "graph") throw graphNotFound();
  const graph = await findGraphRow(db, id);
  if (!graph) throw graphNotFound();
  return { summary, graph };
}

/** The owner's graphs, most recently changed first. */
export async function listGraphs(db: Database, ownerId: string): Promise<{ graphs: GraphListItem[] }> {
  const rows = await db.select({ summary: summaries, graph: graphs })
    .from(summaries)
    .innerJoin(graphs, eq(graphs.summaryId, summaries.id))
    .where(and(eq(summaries.ownerId, ownerId), eq(summaries.kind, "graph")));
  const items = rows.map(({ summary, graph }): GraphListItem => ({
    id: summary.id,
    slug: summary.slug,
    title: graph.document.title,
    revision: graph.revision,
    updatedAt: graph.updatedAt.toISOString(),
    nodeCount: graph.document.nodes.length,
    edgeCount: graph.document.edges.length,
    queryCount: graph.document.queries.length,
  }));
  return { graphs: items.sort((a, b) => b.updatedAt.localeCompare(a.updatedAt)) };
}

/* ------------------------------------------------------------------------------------------------
 * Create
 * ---------------------------------------------------------------------------------------------- */

/**
 * Saves a new graph: a `kind = "graph"` summary row (card text derived from the document, a designed
 * cover, the graph as plain text for search) plus its `graphs` row at revision 0. Like trips, graphs
 * don't count against the summary allowance and their link never expires.
 */
export async function createGraph(db: Database, principal: ApiPrincipal, input: CreateGraphInput, deps?: ServiceDeps & VersionOptions): Promise<GraphJson> {
  const { ai, store, now } = await resolveDeps(deps);
  const document = input.document;
  const id = crypto.randomUUID();
  const digest = graphDigest(document);
  const text = graphText(document).slice(0, SOURCE_TEXT_LIMIT);

  const language = await ai.detectLanguage(digest) ?? "en";
  const design = await ai.designCover({ title: digest.title, summary: digest.summary, category: "Research", keywords: digest.keywords, text, language });
  const normalized = normalizeDraft({
    ...digest,
    category: "Research",
    tags: [],
    language,
    design: design ?? { colors: [], mode: undefined as unknown as "light", emoji: "", accent: "", headline: "" },
  }, { requestedLanguage: "auto", seed: id });
  const draft: SummaryDraft = {
    ...normalized,
    title: digest.title,
    tags: GRAPH_TAGS,
    theme: await selectCoverTheme(db, principal.sub, normalized.theme),
  };
  const embedding = embedSummary(ai, { ...draft, siteName: null, sourceTitle: null, contentText: text });

  const createdAt = now();
  const imageKeys = await coverImages(store, ai, id, draft, null, "illustration", createdAt, "graph");
  const graphRow: GraphRow = { summaryId: id, document, revision: 0, selection: null, updatedAt: createdAt };
  const row = await insertSummary(db, store, {
    id,
    ownerId: principal.sub,
    kind: "graph",
    sourceType: "text",
    source: "text",
    sourceUrl: null,
    sourceTitle: null,
    siteName: null,
    sourceFileKey: null,
    contentExcerpt: text.slice(0, EXCERPT_LIMIT),
    contentText: text,
    contentMarkdown: null,
    title: draft.title,
    summary: draft.summary,
    highlights: draft.highlights,
    category: draft.category,
    tags: draft.tags,
    keywords: draft.keywords,
    language: draft.language,
    sourceLanguage: null,
    displayLanguage: null,
    theme: draft.theme,
    ogHeadline: draft.headline,
    imageStyle: "illustration",
    ...imageKeys,
    visibility: input.visibility,
    ttlDays: null,
    expiresAt: null,
    viewCount: 0,
    createdAt,
    updatedAt: createdAt,
  }, embedding, () => [db.insert(graphs).values(graphRow)], document, { actor: deps?.actor });
  return toGraphJson(row, graphRow, principal.sub);
}

/* ------------------------------------------------------------------------------------------------
 * Edit
 * ---------------------------------------------------------------------------------------------- */

function missing(collection: string, id: string): ApiError {
  return new ApiError(422, "GRAPH_INVALID", `There is no ${collection} "${id}" in the graph`, { issues: [{ path: [collection, id], message: "not found" }] });
}

/** Merges property changes: a null removes the property. */
function mergeProperties(current: Record<string, unknown>, changes: Record<string, unknown> | undefined) {
  if (!changes) return current;
  const merged = { ...current };
  for (const [key, value] of Object.entries(changes)) {
    if (value === null) delete merged[key];
    else merged[key] = value;
  }
  return merged;
}

function replaced<T extends { id: string }>(items: T[], item: T): T[] {
  const index = items.findIndex((candidate) => candidate.id === item.id);
  if (index < 0) return [...items, item];
  return items.map((candidate, at) => (at === index ? item : candidate));
}

/** Applies one operation; the whole document is validated once the batch is applied. */
export function applyGraphOperation(document: GraphDocument, operation: GraphOperation): GraphDocument {
  switch (operation.op) {
    case "set_meta":
      return {
        ...document,
        ...(operation.title !== undefined ? { title: operation.title } : {}),
        ...(operation.description !== undefined ? { description: operation.description } : {}),
      };
    case "upsert_node":
      return { ...document, nodes: replaced(document.nodes, operation.node) };
    case "update_node": {
      const node = document.nodes.find((candidate) => candidate.id === operation.id);
      if (!node) throw missing("node", operation.id);
      const { properties, ...changes } = operation.changes;
      const updated = { ...node, ...changes, properties: mergeProperties(node.properties, properties) } as GraphNode;
      return { ...document, nodes: replaced(document.nodes, updated) };
    }
    case "upsert_edge":
      return { ...document, edges: replaced(document.edges, operation.edge) };
    case "update_edge": {
      const edge = document.edges.find((candidate) => candidate.id === operation.id);
      if (!edge) throw missing("edge", operation.id);
      const { properties, ...changes } = operation.changes;
      const updated = { ...edge, ...changes, properties: mergeProperties(edge.properties, properties) } as GraphEdge;
      return { ...document, edges: replaced(document.edges, updated) };
    }
    case "upsert_query":
      return { ...document, queries: replaced(document.queries, operation.query) };
    case "delete":
      if (operation.collection === "nodes") {
        if (!document.nodes.some((node) => node.id === operation.id)) throw missing("node", operation.id);
        return {
          ...document,
          nodes: document.nodes.filter((node) => node.id !== operation.id),
          edges: document.edges.filter((edge) => edge.source !== operation.id && edge.target !== operation.id),
        };
      }
      if (operation.collection === "edges") {
        if (!document.edges.some((edge) => edge.id === operation.id)) throw missing("edge", operation.id);
        return { ...document, edges: document.edges.filter((edge) => edge.id !== operation.id) };
      }
      if (!document.queries.some((query) => query.id === operation.id)) throw missing("query", operation.id);
      return { ...document, queries: document.queries.filter((query) => query.id !== operation.id) };
  }
}

export function applyGraphOperations(document: GraphDocument, operations: GraphOperation[]): GraphDocument {
  return validGraphDocument(operations.reduce(applyGraphOperation, document));
}

/**
 * Saves a document over `graph.revision` (compare-and-swap: a concurrent save makes this one
 * `409 GRAPH_REVISION_CONFLICT`), refreshes the card's derived text and adds a version.
 */
async function saveGraph(db: Database, deps: SaveDeps, summary: SummaryRow, graph: GraphRow, document: GraphDocument): Promise<GraphJson> {
  const { ai, now } = await resolveDeps(deps);
  if (JSON.stringify(graph.document) === JSON.stringify(document)) return toGraphJson(summary, graph, summary.ownerId);
  const updatedAt = now();
  const revision = graph.revision + 1;
  const digest = graphDigest(document);
  const text = graphText(document).slice(0, SOURCE_TEXT_LIMIT);
  const changes = {
    title: digest.title,
    summary: digest.summary,
    highlights: digest.highlights,
    keywords: digest.keywords,
    contentText: text,
    contentExcerpt: text.slice(0, EXCERPT_LIMIT),
    updatedAt,
  } satisfies Partial<SummaryRow>;
  // `changes()` fences the writes to the compare-and-swap: a refused save touches nothing else.
  const [result] = await db.batch([
    db.update(graphs).set({ document, revision, updatedAt }).where(and(eq(graphs.summaryId, graph.summaryId), eq(graphs.revision, graph.revision))),
    db.update(summaries).set(changes).where(and(eq(summaries.id, summary.id), sql`changes() > 0`)),
    ...versionStatements(db, summary, document, { at: updatedAt, actor: deps.actor, restoredFrom: deps.restoredFrom, fenced: true }),
  ]);
  if (result.rowsAffected === 0) {
    const current = await findGraphRow(db, graph.summaryId);
    if (!current) throw graphNotFound();
    throw revisionConflict(current.revision);
  }
  const updated = { ...summary, ...changes };
  runAfter(() => indexSummary(db, ai, updated));
  return toGraphJson(updated, { ...graph, document, revision, updatedAt }, summary.ownerId);
}

/**
 * Applies operations as one change. With `revision` a stale edit is refused; without it, the edit
 * goes on the latest document and retries when another save lands in between.
 */
export async function editGraph(db: Database, ownerId: string, id: string, input: GraphOperationsInput, deps: SaveDeps = {}): Promise<GraphJson> {
  for (let attempt = 0; ; attempt += 1) {
    const { summary, graph } = await getOwnedGraph(db, id, ownerId);
    if (input.revision !== undefined && input.revision !== graph.revision) throw revisionConflict(graph.revision);
    const document = applyGraphOperations(graph.document, input.operations);
    try {
      return await saveGraph(db, deps, summary, graph, document);
    } catch (error) {
      if (input.revision === undefined && attempt < 2 && error instanceof ApiError && error.code === "GRAPH_REVISION_CONFLICT") continue;
      throw error;
    }
  }
}

/** The chat's edit: refused operations come back as issues for the agent to fix, not as a stream error. */
export async function applyChatGraphOperations(db: Database, ownerId: string, id: string, raw: unknown, deps: SaveDeps = {}): Promise<
  | { applied: number; revision: number; nodeCount: number; edgeCount: number }
  | { error: string; issues: { path: string; message: string }[] }
> {
  const list = Array.isArray(raw) ? raw : [];
  if (list.length === 0 || list.length > MAX_GRAPH_OPERATIONS) return { error: `Send between 1 and ${MAX_GRAPH_OPERATIONS} operations.`, issues: [] };
  const operations: GraphOperation[] = [];
  for (const [index, item] of list.entries()) {
    const parsed = graphOperationSchema.safeParse(item);
    if (!parsed.success) {
      return {
        error: "An operation is malformed. Fix it and call updateGraph again with the full list.",
        issues: parsed.error.issues.slice(0, 8).map((issue) => ({ path: `operations.${index}.${issue.path.join(".")}`, message: issue.message })),
      };
    }
    operations.push(parsed.data);
  }
  try {
    const saved = await editGraph(db, ownerId, id, { operations }, { actor: "chat", ...deps });
    return { applied: operations.length, revision: saved.revision, nodeCount: saved.document.nodes.length, edgeCount: saved.document.edges.length };
  } catch (error) {
    if (error instanceof ApiError && error.code === "GRAPH_INVALID") {
      const issues = (error.details as { issues?: { path: string[]; message: string }[] } | undefined)?.issues ?? [];
      return { error: `${error.message} Fix it and call updateGraph again with the full list.`, issues: issues.slice(0, 12).map((issue) => ({ path: issue.path.join("."), message: issue.message })) };
    }
    throw error;
  }
}

/** Brings a version back as a new one, over the latest revision. */
export async function restoreGraph(db: Database, ownerId: string, id: string, content: unknown, deps: SaveDeps): Promise<GraphJson> {
  const document = validGraphDocument(content, "Restoring this version");
  for (let attempt = 0; ; attempt += 1) {
    const { summary, graph } = await getOwnedGraph(db, id, ownerId);
    try {
      return await saveGraph(db, deps, summary, graph, document);
    } catch (error) {
      if (attempt < 2 && error instanceof ApiError && error.code === "GRAPH_REVISION_CONFLICT") continue;
      throw error;
    }
  }
}

/* ------------------------------------------------------------------------------------------------
 * Query and selection
 * ---------------------------------------------------------------------------------------------- */

/** Runs a query against a stored document; bad syntax is `422 GRAPH_QUERY_INVALID`. */
export function queryGraphDocument(document: GraphDocument, query: string): GraphQueryResult {
  try {
    return runGraphQuery(document, query);
  } catch (error) {
    if (error instanceof GraphQuerySyntaxError) throw new ApiError(422, "GRAPH_QUERY_INVALID", error.message);
    throw error;
  }
}

/** `POST /api/v1/graphs/:id/query`: anyone who can read the graph can query it. */
export async function queryGraph(db: Database, id: string, viewerId: string, query: string): Promise<GraphQueryResult> {
  const found = await findGraphForViewer(db, id, viewerId);
  if (!found) throw graphNotFound();
  return queryGraphDocument(found.graph.document, query);
}

/**
 * Saves what the view picks out (null clears it) without adding a version, so an agent can light up
 * elements for the owner. Ids that aren't in the graph are dropped.
 */
export async function setGraphSelection(db: Database, ownerId: string, id: string, selection: GraphSelection | null): Promise<GraphSelection | null> {
  const { graph } = await getOwnedGraph(db, id, ownerId);
  const live = liveSelection(selection, graph.document);
  await db.update(graphs).set({ selection: live }).where(eq(graphs.summaryId, id));
  return live;
}
