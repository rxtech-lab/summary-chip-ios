import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";
import type { BillingEnvironment } from "@/lib/subscription/config";
import { createGraphSchema, GRAPH_SELECTION_MODES, graphDocumentSchema, graphElementId, graphOperationSchema, graphOperationsRequestSchema, MAX_GRAPH_OPERATIONS, MAX_SELECTION_IDS } from "@/lib/contracts/graph";
import type { Database } from "@/lib/db/client";
import { ApiError } from "@/lib/http/errors";
import { securitySchemes } from "@/lib/mcp/oauth-config";
import type { McpPrincipal } from "@/lib/mcp/oauth-tokens";
import { createGraph, editGraph, getGraph, getOwnedGraph, listGraphs, queryGraphDocument, setGraphSelection, type GraphJson } from "@/lib/services/graphs";
import { storeDocumentImage } from "@/lib/services/trip-images";
import { GRAPH_QUERY_GUIDE, MAX_QUERY_LENGTH } from "./query";

const summary = (graph: GraphJson) => ({
  id: graph.id,
  revision: graph.revision,
  visibility: graph.visibility,
  shareUrl: graph.shareUrl,
  updatedAt: graph.updatedAt,
  document: graph.document,
  selection: graph.selection,
});

type Run = (name: string, action: () => Promise<{ result: CallToolResult }>) => Promise<CallToolResult>;

/** Graphs over MCP: an agent reads and edits the document, runs queries and lights elements up in the app. */
export function registerGraphTools(server: McpServer, context: { db: Database; principal: McpPrincipal; billingEnvironment?: BillingEnvironment }, run: Run) {
  const { db, principal } = context;
  const result = (payload: Record<string, unknown>, text?: string): { result: CallToolResult } => ({
    result: { content: [...(text ? [{ type: "text" as const, text }] : []), { type: "text", text: JSON.stringify(payload) }], structuredContent: payload },
  });
  const meta = (name: string, title: string, read: boolean, destructive = false) => ({
    title,
    _meta: { securitySchemes: securitySchemes(name) },
    annotations: { title, readOnlyHint: read, destructiveHint: destructive, idempotentHint: false, openWorldHint: false },
  });
  const graphId = z.string().trim().min(1).max(100).describe("The graph's id, from list_graphs.");

  server.registerTool("list_graphs", {
    ...meta("list_graphs", "List Graphs", true),
    description: "List the user's graphs, most recently changed first, with their id, title, revision and how many nodes, edges and saved queries each has. Open one with get_graph.",
    inputSchema: {},
  }, () => run("list_graphs", async () => {
    const { graphs } = await listGraphs(db, principal.sub);
    return result({ count: graphs.length, graphs });
  }));

  server.registerTool("get_graph", {
    ...meta("get_graph", "Get Graph", true),
    description: "Read a graph's full document: nodes and edges with their JSON properties, images and custom views, and its saved queries. Pass the revision to update_graph to make sure nobody changed it in between.",
    inputSchema: { graphId },
  }, (args) => run("get_graph", async () => result({ graph: summary(await getGraph(db, args.graphId, principal.sub)) })));

  server.registerTool("create_graph", {
    ...meta("create_graph", "Create Graph", false),
    description: "Create a graph from a document: { title, description?, nodes: [{ id, label, types?, color?, properties?, images?, view? }], edges: [{ id, source, target, label, directed?, color?, properties?, images?, view? }], queries?: [{ id, name, description?, query }] }. "
      + "properties hold any JSON, like a NoSQL document. images are [{ url, caption?, credit? }] with https URLs. view is a JSON-rendered native view { root, elements } (the same catalog as a trip's custom views). "
      + `${GRAPH_QUERY_GUIDE} Designs a cover (this can take a minute). Free.`,
    inputSchema: {
      document: graphDocumentSchema.describe("The graph document."),
      visibility: z.enum(["public", "private"]).optional().describe("Who can open its link; private unless the user asks to share it."),
    },
  }, (args) => run("create_graph", async () => {
    const input = createGraphSchema.parse({ document: args.document, visibility: args.visibility });
    const graph = await createGraph(db, principal, input, { billingEnvironment: context.billingEnvironment, actor: "agent" });
    return result({ graph: summary(graph) }, `Created graph "${graph.document.title}" (${graph.visibility}).\n${graph.shareUrl}`);
  }));

  server.registerTool("update_graph", {
    ...meta("update_graph", "Update Graph", false, true),
    description: "Edit a graph with operations applied in order, as one change: set_meta, upsert_node / upsert_edge / upsert_query (a full record; the same id replaces it, a new id adds it), "
      + "update_node / update_edge (id, changes: only the fields to change; properties merge and a null property is removed), and delete (collection: nodes|edges|queries, id). Deleting a node removes its edges. "
      + "Each edit saves a version. Pass revision to refuse the edit if the graph changed meanwhile. Free.",
    inputSchema: {
      graphId,
      operations: z.array(graphOperationSchema).min(1).max(MAX_GRAPH_OPERATIONS).describe("Operations, applied in order."),
      revision: z.number().int().min(0).optional().describe("The revision the edit is based on; omit to apply to the latest."),
    },
  }, (args) => run("update_graph", async () => {
    const input = graphOperationsRequestSchema.parse({ operations: args.operations, revision: args.revision });
    const graph = await editGraph(db, principal.sub, args.graphId, input, { actor: "agent" });
    return result({ graph: summary(graph) }, `Updated "${graph.document.title}" (revision ${graph.revision}).`);
  }));

  server.registerTool("query_graph", {
    ...meta("query_graph", "Query Graph", true),
    description: `Run a read-only query and return the matched nodeIds and edgeIds, the row count and the first rows. It doesn't change what the app shows; call select_graph_elements for that. ${GRAPH_QUERY_GUIDE}`,
    inputSchema: { graphId, query: z.string().trim().min(1).max(MAX_QUERY_LENGTH).describe("The query.") },
  }, (args) => run("query_graph", async () => {
    const { document } = await getGraph(db, args.graphId, principal.sub);
    return result({ result: queryGraphDocument(document, args.query) });
  }));

  server.registerTool("select_graph_elements", {
    ...meta("select_graph_elements", "Select Graph Elements", false),
    description: "Pick out elements in the app's view of a graph you own, the next time it loads or refreshes: mode highlight dims the rest, isolate shows only them. Give a query, or nodeIds and edgeIds, or clear: true to show the whole graph again. Adds no version.",
    inputSchema: {
      graphId,
      mode: z.enum(GRAPH_SELECTION_MODES).optional().describe("highlight (default) or isolate."),
      query: z.string().trim().min(1).max(MAX_QUERY_LENGTH).optional().describe("Selects what this query matches."),
      nodeIds: z.array(graphElementId).max(MAX_SELECTION_IDS).optional().describe("Nodes to pick out, instead of a query."),
      edgeIds: z.array(graphElementId).max(MAX_SELECTION_IDS).optional().describe("Edges to pick out, instead of a query."),
      clear: z.boolean().optional().describe("Removes the current selection."),
    },
  }, (args) => run("select_graph_elements", async () => {
    if (args.clear) return result({ selection: await setGraphSelection(db, principal.sub, args.graphId, null) }, "Cleared the selection.");
    if (args.query && (args.nodeIds || args.edgeIds)) throw new ApiError(400, "INVALID_ARGUMENTS", "Give a query or ids, not both");
    if (!args.query && !args.nodeIds?.length && !args.edgeIds?.length) throw new ApiError(400, "INVALID_ARGUMENTS", "Give a query, or nodeIds and edgeIds, or clear: true");
    const { graph } = await getOwnedGraph(db, args.graphId, principal.sub);
    const matched = args.query ? queryGraphDocument(graph.document, args.query) : { nodeIds: args.nodeIds ?? [], edgeIds: args.edgeIds ?? [] };
    const selection = await setGraphSelection(db, principal.sub, args.graphId, { mode: args.mode ?? "highlight", nodeIds: matched.nodeIds, edgeIds: matched.edgeIds, query: args.query ?? null });
    return result({ selection });
  }));

  server.registerTool("upload_graph_image", {
    ...meta("upload_graph_image", "Upload Graph Image", false),
    description: "Store an image for a graph and return its lasting https URL, for a node or edge's images. Give uploadKey from create_upload (PUT the bytes first) or a public url. Images are re-encoded as JPEG (max 2048 px, metadata stripped).",
    inputSchema: {
      graphId,
      uploadKey: z.string().trim().min(1).max(300).optional().describe("The key from create_upload."),
      url: z.string().trim().url().max(4096).optional().describe("A public image URL to copy."),
    },
  }, (args) => run("upload_graph_image", async () => {
    if (Boolean(args.uploadKey) === Boolean(args.url)) throw new ApiError(400, "INVALID_ARGUMENTS", "Give exactly one of uploadKey or url");
    const { summary: owned } = await getOwnedGraph(db, args.graphId, principal.sub);
    return result({ image: await storeDocumentImage(db, principal.sub, owned.id, { uploadKey: args.uploadKey, url: args.url }) });
  }));
}
