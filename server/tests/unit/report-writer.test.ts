import { describe, expect, it } from "vitest";
import { reportGraphContext } from "@/lib/ai/report-writer";
import { graphDocumentSchema } from "@/lib/contracts/graph";

const document = graphDocumentSchema.parse({
  title: "Company relationships",
  description: "Research supplied by the user",
  nodes: [
    { id: "company", label: "Acme", types: ["Company"], properties: { sector: "Energy" } },
    { id: "owner", label: "Acme Holdings", types: ["Company"], properties: { country: "Japan" } },
    { id: "supplier", label: "Components Ltd", types: ["Supplier"], properties: { product: "Batteries" } },
    { id: "peer", label: "Peer Inc", properties: { market: "Storage" } },
    { id: "unrelated", label: "Unrelated company" },
    { id: "isolated", label: "Isolated company" },
  ],
  edges: [
    { id: "ownership", source: "owner", target: "company", label: "OWNS", properties: { stake: "60%", sourceUrl: "https://example.com/filing" } },
    { id: "purchases", source: "company", target: "supplier", label: "BUYS_FROM", properties: { since: 2024 } },
    { id: "partnership", source: "company", target: "supplier", label: "PARTNERS_WITH" },
    { id: "competition", source: "peer", target: "company", label: "COMPETES_WITH", directed: false },
    { id: "self", source: "company", target: "company", label: "INTERNAL" },
    { id: "second-hop", source: "supplier", target: "unrelated", label: "BUYS_FROM" },
  ],
});

describe("report relationship context", () => {
  it("supplies named neighbors and their evidence for every incoming, outgoing and undirected connection", () => {
    const context = reportGraphContext(document, "company");
    expect(context.graph).toEqual({ title: document.title, description: document.description });
    expect(context.node).toMatchObject({ id: "company", properties: { sector: "Energy" } });
    expect(context.connectedNodes.map((node) => node.id)).toEqual(["owner", "supplier", "peer"]);
    expect(context.connectedNodes[0]).toMatchObject({ label: "Acme Holdings", types: ["Company"], properties: { country: "Japan" } });
    expect(context.edges.map((edge) => edge.id)).toEqual(["ownership", "purchases", "partnership", "competition", "self"]);
    expect(context.edges[0]).toMatchObject({ source: "owner", target: "company", directed: true, properties: { stake: "60%", sourceUrl: "https://example.com/filing" } });
    expect(context.edges[3].directed).toBe(false);
    const endpoints = new Set([context.node.id, ...context.connectedNodes.map((node) => node.id)]);
    expect(context.edges.every((edge) => endpoints.has(edge.source) && endpoints.has(edge.target))).toBe(true);
  });

  it("omits presentation definitions without changing the graph or dropping relationship data", () => {
    const graph = structuredClone(document);
    const view = { root: "text", elements: { text: { type: "Text" as const, props: { text: "PRESENTATION_ONLY" } } } };
    graph.nodes.forEach((node) => { node.view = view; });
    graph.edges.forEach((edge) => { edge.view = view; });
    const before = structuredClone(graph);
    const serialized = JSON.stringify(reportGraphContext(graph, "company"));
    expect(serialized).not.toContain("PRESENTATION_ONLY");
    expect(serialized).toContain("Batteries");
    expect(graph).toEqual(before);
  });

  it("keeps an isolated node's context empty and rejects unknown nodes", () => {
    expect(reportGraphContext(document, "isolated")).toMatchObject({ node: { id: "isolated" }, connectedNodes: [], edges: [] });
    expect(() => reportGraphContext(document, "missing")).toThrow("Report node not found");
  });
});
