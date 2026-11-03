import { eq } from "drizzle-orm";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import * as graphsRoute from "@/app/api/v1/graphs/route";
import * as graphRoute from "@/app/api/v1/graphs/[id]/route";
import * as operationsRoute from "@/app/api/v1/graphs/[id]/operations/route";
import * as queryRoute from "@/app/api/v1/graphs/[id]/query/route";
import * as selectionRoute from "@/app/api/v1/graphs/[id]/selection/route";
import * as summaryRoute from "@/app/api/v1/summaries/[id]/route";
import * as versionsRoute from "@/app/api/v1/summaries/[id]/versions/route";
import * as restoreRoute from "@/app/api/v1/summaries/[id]/versions/[version]/restore/route";
import { graphChatInstructions, graphChatTools } from "@/lib/ai/graph-agent";
import { MockAiProvider } from "@/lib/ai/mock";
import { graphs, summaries } from "@/lib/db/schema";
import type { GraphJson } from "@/lib/services/graphs";
import { apiRequest, params, setupTestEnv, type TestEnv } from "../helpers/setup";

let env: TestEnv;

beforeEach(async () => {
  env = await setupTestEnv();
});

afterEach(() => env.teardown());

const DOCUMENT = {
  title: "Computing pioneers",
  nodes: [
    { id: "ada", label: "Ada Lovelace", types: ["Person"], properties: { born: 1815, field: "mathematics", address: { city: "London" } } },
    { id: "babbage", label: "Charles Babbage", types: ["Person"], properties: { born: 1791 }, images: [{ url: "https://example.com/babbage.jpg", caption: "Portrait" }] },
    { id: "engine", label: "Analytical Engine", types: ["Machine"], properties: { year: 1837 } },
    { id: "turing", label: "Alan Turing", types: ["Person"], properties: { born: 1912, field: "mathematics" } },
  ],
  edges: [
    { id: "e1", source: "ada", target: "babbage", label: "WORKED_WITH", directed: false, properties: { since: 1833 } },
    { id: "e2", source: "babbage", target: "engine", label: "DESIGNED" },
    { id: "e3", source: "ada", target: "engine", label: "PROGRAMMED" },
  ],
  queries: [{ id: "people", name: "People", query: "MATCH (n:Person) RETURN n" }],
};

async function create(document: unknown = DOCUMENT, token = env.tokens.alice, visibility = "private"): Promise<GraphJson> {
  const response = await graphsRoute.POST(apiRequest("POST", "/api/v1/graphs", { token, body: { document, visibility } }));
  expect(response.status).toBe(201);
  return (await response.json()).graph;
}

const get = (id: string, token = env.tokens.alice) => graphRoute.GET(apiRequest("GET", `/api/v1/graphs/${id}`, { token }), params({ id }));
const operate = (id: string, body: unknown, token = env.tokens.alice) => operationsRoute.POST(apiRequest("POST", `/api/v1/graphs/${id}/operations`, { token, body }), params({ id }));
const query = (id: string, text: string, token = env.tokens.alice) => queryRoute.POST(apiRequest("POST", `/api/v1/graphs/${id}/query`, { token, body: { query: text } }), params({ id }));
const select = (id: string, selection: unknown, token = env.tokens.alice) => selectionRoute.PUT(apiRequest("PUT", `/api/v1/graphs/${id}/selection`, { token, body: { selection } }), params({ id }));

describe("graph documents", () => {
  it("creates a library item and its document", async () => {
    const graph = await create();
    expect(graph).toMatchObject({ revision: 0, isOwner: true, visibility: "private", selection: null });
    expect(graph.document.nodes[0].images).toEqual([]);
    expect(graph.document.edges[1].directed).toBe(true);

    const [row] = await env.handle.db.select().from(summaries).where(eq(summaries.id, graph.id));
    expect(row).toMatchObject({ kind: "graph", title: "Computing pioneers", tags: ["graph"], expiresAt: null });
    expect(row.summary).toBe("A graph of 4 nodes and 3 edges.");
    expect(row.contentText).toContain("Ada Lovelace (Person)");
    const summary = await summaryRoute.GET(apiRequest("GET", `/api/v1/summaries/${graph.id}`, { token: env.tokens.alice }), params({ id: graph.id }));
    expect((await summary.json()).kind).toBe("graph");
  });

  it.each([
    ["an edge to a missing node", { title: "x", nodes: [{ id: "a", label: "A" }], edges: [{ id: "e", source: "a", target: "nope", label: "X" }] }],
    ["duplicate node ids", { title: "x", nodes: [{ id: "a", label: "A" }, { id: "a", label: "B" }] }],
    ["a non-https image", { title: "x", nodes: [{ id: "a", label: "A", images: [{ url: "http://example.com/a.jpg" }] }] }],
    ["a broken view", { title: "x", nodes: [{ id: "a", label: "A", view: { root: "nope", elements: {} } }] }],
    ["an unparseable saved query", { title: "x", queries: [{ id: "q", name: "Q", query: "SELECT *" }] }],
    ["a reserved property name", { title: "x", nodes: [{ id: "a", label: "A", properties: { constructor: 1 } }] }],
  ])("refuses %s", async (_, document) => {
    const response = await graphsRoute.POST(apiRequest("POST", "/api/v1/graphs", { token: env.tokens.alice, body: { document } }));
    expect(response.status).toBe(400);
  });

  it("drops a __proto__ property rather than storing it", async () => {
    const graph = await create({ title: "x", nodes: [{ id: "a", label: "A", properties: JSON.parse('{"__proto__": {"polluted": true}, "kept": 1}') }] });
    expect(graph.document.nodes[0].properties).toEqual({ kept: 1 });
    expect(({} as Record<string, unknown>).polluted).toBeUndefined();
  });

  it("adds, changes and removes elements, each save a version", async () => {
    const graph = await create();
    const added = await operate(graph.id, { operations: [
      { op: "upsert_node", node: { id: "hopper", label: "Grace Hopper", types: ["Person"], properties: { born: 1906 } } },
      { op: "upsert_edge", edge: { id: "e4", source: "hopper", target: "turing", label: "ADMIRED" } },
    ] });
    expect(added.status).toBe(200);
    const saved = (await added.json()).graph as GraphJson;
    expect(saved.revision).toBe(1);
    expect(saved.document.nodes).toHaveLength(5);

    const patched = await operate(graph.id, { operations: [
      { op: "update_node", id: "ada", changes: { label: "Countess Lovelace", properties: { born: null, title: "Countess" } } },
    ] });
    const node = ((await patched.json()).graph as GraphJson).document.nodes.find((candidate) => candidate.id === "ada")!;
    expect(node.label).toBe("Countess Lovelace");
    expect(node.properties).toEqual({ field: "mathematics", address: { city: "London" }, title: "Countess" });

    const removed = await operate(graph.id, { operations: [{ op: "delete", collection: "nodes", id: "hopper" }] });
    const after = (await removed.json()).graph as GraphJson;
    expect(after.document.nodes.map((candidate) => candidate.id)).not.toContain("hopper");
    expect(after.document.edges.map((edge) => edge.id)).not.toContain("e4");

    const history = await versionsRoute.GET(apiRequest("GET", `/api/v1/summaries/${graph.id}/versions`, { token: env.tokens.alice }), params({ id: graph.id }));
    const { items } = await history.json();
    expect(items).toHaveLength(4);
    expect(items[0]).toMatchObject({ kind: "graph", title: "Computing pioneers", isCurrent: true });
  });

  it("refuses an edit that breaks the graph or targets a stale revision", async () => {
    const graph = await create();
    const dangling = await operate(graph.id, { operations: [{ op: "upsert_edge", edge: { id: "bad", source: "ada", target: "nobody", label: "X" } }] });
    expect(dangling.status).toBe(422);
    expect((await dangling.json()).error.code).toBe("GRAPH_INVALID");
    const unknown = await operate(graph.id, { operations: [{ op: "update_node", id: "nobody", changes: { label: "X" } }] });
    expect(unknown.status).toBe(422);

    await operate(graph.id, { operations: [{ op: "set_meta", title: "Renamed" }] });
    const stale = await operate(graph.id, { revision: 0, operations: [{ op: "set_meta", title: "Stale" }] });
    expect(stale.status).toBe(409);
    expect((await stale.json()).error.code).toBe("GRAPH_REVISION_CONFLICT");
    expect(((await (await get(graph.id)).json()).graph as GraphJson).document.title).toBe("Renamed");
    const [row] = await env.handle.db.select().from(summaries).where(eq(summaries.id, graph.id));
    expect(row.title).toBe("Renamed");
  });

  it("restores an earlier version", async () => {
    const graph = await create();
    await operate(graph.id, { operations: [{ op: "delete", collection: "nodes", id: "ada" }] });
    const restored = await restoreRoute.POST(apiRequest("POST", `/api/v1/summaries/${graph.id}/versions/1/restore`, { token: env.tokens.alice }), params({ id: graph.id, version: "1" }));
    expect(restored.status).toBe(200);
    const body = await restored.json();
    expect(body.graph.document.nodes.map((node: { id: string }) => node.id)).toContain("ada");
    expect(body.graph.revision).toBe(2);
    expect(body.version).toMatchObject({ actor: "restore", restoredFrom: 1 });
  });

  it("deletes the graph with its summary", async () => {
    const graph = await create();
    const response = await graphRoute.DELETE(apiRequest("DELETE", `/api/v1/graphs/${graph.id}`, { token: env.tokens.alice }), params({ id: graph.id }));
    expect(response.status).toBe(204);
    expect(await env.handle.db.select().from(graphs).where(eq(graphs.summaryId, graph.id))).toEqual([]);
    expect((await get(graph.id)).status).toBe(404);
  });

  it("keeps a private graph to its owner and never lets others edit", async () => {
    const hidden = await create();
    expect((await get(hidden.id, env.tokens.bob)).status).toBe(404);
    expect((await query(hidden.id, "MATCH (n) RETURN n", env.tokens.bob)).status).toBe(404);

    const shared = await create(DOCUMENT, env.tokens.alice, "public");
    await select(shared.id, { mode: "isolate", nodeIds: ["ada"], edgeIds: [] });
    const read = (await (await get(shared.id, env.tokens.bob)).json()).graph as GraphJson;
    expect(read).toMatchObject({ isOwner: false, selection: null });
    expect((await query(shared.id, "MATCH (n:Machine) RETURN n", env.tokens.bob)).status).toBe(200);
    expect((await operate(shared.id, { operations: [{ op: "set_meta", title: "Mine now" }] }, env.tokens.bob)).status).toBe(403);
    expect((await select(shared.id, null, env.tokens.bob)).status).toBe(403);
  });
});

describe("queries and selections", () => {
  it("names what a query matched", async () => {
    const graph = await create();
    const response = await query(graph.id, "MATCH (a:Person)-[r:PROGRAMMED]->(b:Machine) RETURN a, r, b.label");
    expect(response.status).toBe(200);
    const { result } = await response.json();
    expect(result).toMatchObject({ nodeIds: ["ada", "engine"], edgeIds: ["e3"], rowCount: 1, truncated: false });
    expect(result.rows[0]).toEqual({ a: "ada", r: "e3", "b.label": "Analytical Engine" });
  });

  it("reports a syntax error instead of an empty result", async () => {
    const graph = await create();
    const response = await query(graph.id, "MATCH (n RETURN n");
    expect(response.status).toBe(422);
    expect((await response.json()).error.code).toBe("GRAPH_QUERY_INVALID");
  });

  it("keeps a selection without adding a version and drops deleted elements", async () => {
    const graph = await create();
    const saved = await select(graph.id, { mode: "isolate", nodeIds: ["ada", "nobody", "turing"], edgeIds: ["e1"], query: "MATCH (n) RETURN n" });
    expect((await saved.json()).selection).toEqual({ mode: "isolate", nodeIds: ["ada", "turing"], edgeIds: ["e1"], query: "MATCH (n) RETURN n" });
    expect(((await (await get(graph.id)).json()).graph as GraphJson).revision).toBe(0);

    await operate(graph.id, { operations: [{ op: "delete", collection: "nodes", id: "ada" }] });
    const after = ((await (await get(graph.id)).json()).graph as GraphJson).selection;
    expect(after).toEqual({ mode: "isolate", nodeIds: ["turing"], edgeIds: [], query: "MATCH (n) RETURN n" });

    await select(graph.id, null);
    expect(((await (await get(graph.id)).json()).graph as GraphJson).selection).toBeNull();
  });
});

describe("graph agent", () => {
  const call = async (tool: { execute?: unknown }, input: unknown) => (tool.execute as (input: unknown, options: unknown) => Promise<Record<string, unknown>>)(input, {});
  const tools = (id: string) => graphChatTools(env.handle.db, "user-alice", id, new MockAiProvider());

  it("edits, with refusals returned for repair", async () => {
    const graph = await create();
    const { updateGraph } = tools(graph.id);
    const done = await call(updateGraph, { changeSummary: "Added Hopper", operations: [{ op: "upsert_node", node: { id: "hopper", label: "Grace Hopper" } }] });
    expect(done).toMatchObject({ applied: 1, revision: 1, nodeCount: 5, changeSummary: "Added Hopper" });
    const refused = await call(updateGraph, { operations: [{ op: "upsert_edge", edge: { id: "x", source: "nobody", target: "ada", label: "X" } }] });
    expect(refused.error).toContain("invalid");
    expect(refused.issues).toEqual(expect.arrayContaining([expect.objectContaining({ path: "edges.3.source" })]));
    const malformed = await call(updateGraph, { operations: [{ op: "explode" }] });
    expect(malformed.error).toContain("malformed");
  });

  it("queries and lights elements up", async () => {
    const graph = await create();
    const { queryGraph, selectGraphElements } = tools(graph.id);
    const found = await call(queryGraph, { query: "MATCH (n:Machine) RETURN n" });
    expect(found.graphQuery).toMatchObject({ nodeIds: ["engine"] });
    expect((await call(queryGraph, { query: "nonsense" })).error).toBeTruthy();

    const shown = await call(selectGraphElements, { mode: "isolate", query: "MATCH (n:Person) RETURN n" });
    expect(shown.graphSelection).toMatchObject({ mode: "isolate", nodeIds: ["ada", "babbage", "turing"], query: "MATCH (n:Person) RETURN n" });
    expect(((await (await get(graph.id)).json()).graph as GraphJson).selection?.mode).toBe("isolate");

    const cleared = await call(selectGraphElements, { mode: "clear" });
    expect(cleared).toMatchObject({ graphSelection: null, cleared: true });
  });

  it("outlines a large document instead of inlining it", () => {
    const nodes = Array.from({ length: 800 }, (_, index) => ({ id: `n${index}`, label: `Node ${index}`, types: [], properties: { note: "x".repeat(60) }, images: [] }));
    const instructions = graphChatInstructions("g", { version: 1, title: "Big", nodes, edges: [], queries: [] });
    expect(instructions).toContain("readGraphElements");
    expect(instructions).not.toContain("x".repeat(60));
    expect(instructions.length).toBeLessThan(40_000);
  });
});
