import { z } from "zod";
import { GraphQuerySyntaxError, MAX_QUERY_LENGTH, parseGraphQuery } from "@/lib/graph/query";
import { jsonValue, type Json } from "./mini-app";
import { viewSpecIssues, viewSpecSchema, type ViewSpec } from "./trip-view";
import { VISIBILITIES } from "@/lib/db/schema";

/**
 * A graph document: nodes joined by edges, both with schemaless JSON properties, images and an
 * optional JSON-rendered view, plus saved queries. Spec: `docs/graphs.md`.
 * `Packages/SummaryKit/Sources/SummaryKit/Models/Graph.swift` mirrors it.
 */

export const MAX_GRAPH_NODES = 2000;
export const MAX_GRAPH_EDGES = 6000;
export const MAX_GRAPH_QUERIES = 100;
export const MAX_ELEMENT_IMAGES = 12;
export const MAX_ELEMENT_TYPES = 10;
/** One element's properties, serialised. */
export const MAX_PROPERTIES_CHARS = 20_000;
/** The whole document, serialised: a save has to fit a Vercel Function's 4.5 MB request body. */
export const MAX_GRAPH_DOCUMENT_CHARS = 3_000_000;
export const MAX_GRAPH_OPERATIONS = 500;
export const MAX_SELECTION_IDS = MAX_GRAPH_NODES + MAX_GRAPH_EDGES;

const FORBIDDEN_KEYS = new Set(["__proto__", "prototype", "constructor"]);

export const graphElementId = z.string().trim().regex(/^[A-Za-z0-9][A-Za-z0-9_.:-]{0,119}$/, "use 1-120 letters, digits, _ . : or -");
const label = z.string().trim().min(1).max(200);
const color = z.string().trim().regex(/^#[0-9A-Fa-f]{6}$/, "must be a #RRGGBB color").nullish();
const httpsImage = z.string().trim().max(4096).url().refine((value) => value.startsWith("https://"), "must be an https URL");

const properties = z.record(z.string().min(1).max(200), jsonValue).superRefine((value, context) => {
  const forbidden = Object.keys(value).find((key) => FORBIDDEN_KEYS.has(key));
  if (forbidden) context.addIssue({ code: "custom", message: `"${forbidden}" can't be a property name` });
  if (JSON.stringify(value).length > MAX_PROPERTIES_CHARS) context.addIssue({ code: "custom", message: `properties can be at most ${MAX_PROPERTIES_CHARS} characters of JSON` });
});

export const graphImageSchema = z.object({
  url: httpsImage,
  caption: z.string().trim().max(300).nullish(),
  credit: z.string().trim().max(300).nullish(),
});

const elementFields = {
  id: graphElementId,
  label,
  color,
  /** Schemaless data, like a NoSQL document. */
  properties: properties.default({}),
  images: z.array(graphImageSchema).max(MAX_ELEMENT_IMAGES).default([]),
  /** A custom native view of the element, drawn with the catalog in `trip-view.ts`. */
  view: viewSpecSchema.nullish(),
};

export const graphNodeSchema = z.object({
  ...elementFields,
  /** What `(n:Type)` matches, like a labelled property graph's labels. */
  types: z.array(z.string().trim().min(1).max(80)).max(MAX_ELEMENT_TYPES).default([]),
});
export type GraphNode = z.infer<typeof graphNodeSchema>;

export const graphEdgeSchema = z.object({
  ...elementFields,
  source: graphElementId,
  target: graphElementId,
  /** An undirected edge is walked both ways by `->` and `<-`. */
  directed: z.boolean().default(true),
});
export type GraphEdge = z.infer<typeof graphEdgeSchema>;

const queryText = z.string().trim().min(1).max(MAX_QUERY_LENGTH).superRefine((value, context) => {
  try {
    parseGraphQuery(value);
  } catch (error) {
    if (!(error instanceof GraphQuerySyntaxError)) throw error;
    context.addIssue({ code: "custom", message: error.message });
  }
});

export const graphSavedQuerySchema = z.object({
  id: graphElementId,
  name: z.string().trim().min(1).max(120),
  description: z.string().trim().max(500).nullish(),
  query: queryText,
});
export type GraphSavedQuery = z.infer<typeof graphSavedQuerySchema>;

function requireUnique(items: { id: string }[], collection: string, context: z.RefinementCtx) {
  const seen = new Set<string>();
  items.forEach((item, index) => {
    if (seen.has(item.id)) context.addIssue({ code: "custom", path: [collection, index, "id"], message: `"${item.id}" is used more than once` });
    seen.add(item.id);
  });
}

function requireValidView(view: ViewSpec | null | undefined, path: (string | number)[], context: z.RefinementCtx) {
  if (!view) return;
  for (const issue of viewSpecIssues(view)) context.addIssue({ code: "custom", path: [...path, "view", ...issue.path], message: issue.message });
}

export const graphDocumentSchema = z.object({
  version: z.literal(1).default(1),
  title: z.string().trim().min(1).max(200),
  description: z.string().trim().max(1200).nullish(),
  nodes: z.array(graphNodeSchema).max(MAX_GRAPH_NODES).default([]),
  edges: z.array(graphEdgeSchema).max(MAX_GRAPH_EDGES).default([]),
  queries: z.array(graphSavedQuerySchema).max(MAX_GRAPH_QUERIES).default([]),
}).superRefine((document, context) => {
  requireUnique(document.nodes, "nodes", context);
  requireUnique(document.edges, "edges", context);
  requireUnique(document.queries, "queries", context);
  const nodes = new Set(document.nodes.map((node) => node.id));
  document.edges.forEach((edge, index) => {
    if (!nodes.has(edge.source)) context.addIssue({ code: "custom", path: ["edges", index, "source"], message: `no node "${edge.source}"` });
    if (!nodes.has(edge.target)) context.addIssue({ code: "custom", path: ["edges", index, "target"], message: `no node "${edge.target}"` });
    requireValidView(edge.view, ["edges", index], context);
  });
  document.nodes.forEach((node, index) => requireValidView(node.view, ["nodes", index], context));
  if (JSON.stringify(document).length > MAX_GRAPH_DOCUMENT_CHARS) {
    context.addIssue({ code: "custom", message: `a graph can be at most ${MAX_GRAPH_DOCUMENT_CHARS} characters of JSON` });
  }
});
export type GraphDocument = z.infer<typeof graphDocumentSchema>;

export const createGraphSchema = z.object({
  document: graphDocumentSchema,
  visibility: z.enum(VISIBILITIES).default("private"),
}).strict();

/** Changes to named fields of an element; `properties` merge, and a null property removes it. */
const elementPatch = {
  label: label.optional(),
  color,
  properties: z.record(z.string().min(1).max(200), jsonValue).optional(),
  images: z.array(graphImageSchema).max(MAX_ELEMENT_IMAGES).optional(),
  view: viewSpecSchema.nullish(),
};

export const graphOperationSchema = z.discriminatedUnion("op", [
  z.object({ op: z.literal("set_meta"), title: z.string().trim().min(1).max(200).optional(), description: z.string().trim().max(1200).nullish() }),
  z.object({ op: z.literal("upsert_node"), node: graphNodeSchema }),
  z.object({ op: z.literal("update_node"), id: graphElementId, changes: z.object({ ...elementPatch, types: z.array(z.string().trim().min(1).max(80)).max(MAX_ELEMENT_TYPES).optional() }) }),
  z.object({ op: z.literal("upsert_edge"), edge: graphEdgeSchema }),
  z.object({ op: z.literal("update_edge"), id: graphElementId, changes: z.object({ ...elementPatch, source: graphElementId.optional(), target: graphElementId.optional(), directed: z.boolean().optional() }) }),
  z.object({ op: z.literal("upsert_query"), query: graphSavedQuerySchema }),
  /** Deleting a node also removes the edges touching it. */
  z.object({ op: z.literal("delete"), collection: z.enum(["nodes", "edges", "queries"]), id: graphElementId }),
]);
export type GraphOperation = z.infer<typeof graphOperationSchema>;

export const graphOperationsRequestSchema = z.object({
  operations: z.array(graphOperationSchema).min(1).max(MAX_GRAPH_OPERATIONS),
  revision: z.number().int().min(0).optional(),
}).strict();

export const runGraphQuerySchema = z.object({ query: z.string().trim().min(1).max(MAX_QUERY_LENGTH) }).strict();

export const GRAPH_SELECTION_MODES = ["highlight", "isolate"] as const;

/** Which elements the view picks out. `isolate` hides everything else. */
export const graphSelectionSchema = z.object({
  mode: z.enum(GRAPH_SELECTION_MODES).default("highlight"),
  nodeIds: z.array(graphElementId).max(MAX_SELECTION_IDS).default([]),
  edgeIds: z.array(graphElementId).max(MAX_SELECTION_IDS).default([]),
  /** The query the selection came from; null for a hand-picked one. */
  query: z.string().trim().max(MAX_QUERY_LENGTH).nullish(),
});
export type GraphSelection = z.infer<typeof graphSelectionSchema>;

export const putGraphSelectionSchema = z.object({ selection: graphSelectionSchema.nullable() }).strict();

export type { Json };
