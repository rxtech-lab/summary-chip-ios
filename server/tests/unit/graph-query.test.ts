import { describe, expect, it } from "vitest";
import { GraphQuerySyntaxError, parseGraphQuery, runGraphQuery, type QueryableGraph } from "@/lib/graph/query";

const node = (id: string, types: string[] = [], properties: Record<string, unknown> = {}) => ({ id, label: id.toUpperCase(), types, properties });
const edge = (id: string, source: string, target: string, label: string, properties: Record<string, unknown> = {}, directed = true) => ({ id, source, target, label, directed, properties });

const GRAPH: QueryableGraph = {
  nodes: [
    node("a", ["Person"], { age: 30, name: "Ada", tags: ["math", "code"], address: { city: "London" } }),
    node("b", ["Person", "Admin"], { age: 41, name: "Bob" }),
    node("c", ["Person"], { age: 25, name: "Cleo", nickname: null }),
    node("m", ["Machine"], { year: 1837 }),
    node("alone", ["Machine"]),
  ],
  edges: [
    edge("ab", "a", "b", "KNOWS", { since: 2001 }),
    edge("bc", "b", "c", "KNOWS", { since: 2010 }),
    edge("cm", "c", "m", "USES"),
    edge("ac", "a", "c", "FRIEND", {}, false),
  ],
};

const ids = (query: string) => {
  const result = runGraphQuery(GRAPH, query);
  return { nodes: [...result.nodeIds].sort(), edges: [...result.edgeIds].sort() };
};

describe("graph query matching", () => {
  it("matches nodes by type, inline properties and case-insensitive types", () => {
    expect(ids("MATCH (n:Person) RETURN n").nodes).toEqual(["a", "b", "c"]);
    expect(ids("match (n:person|machine {year: 1837}) return n").nodes).toEqual(["m"]);
    expect(ids('MATCH (n {name: "Bob"}) RETURN n').nodes).toEqual(["b"]);
  });

  it("follows direction", () => {
    expect(ids("MATCH (a {name: 'Ada'})-[:KNOWS]->(b) RETURN b").nodes).toEqual(["b"]);
    expect(ids("MATCH (b {name: 'Bob'})<-[:KNOWS]-(a) RETURN a").nodes).toEqual(["a"]);
    expect(ids("MATCH (b {name: 'Bob'})-[:KNOWS]-(x) RETURN x").nodes).toEqual(["a", "c"]);
    expect(ids("MATCH (a {name: 'Ada'})-->(x) RETURN x").nodes).toEqual(["b", "c"]);
    expect(ids("MATCH (b {name: 'Bob'})<--(x) RETURN x").nodes).toEqual(["a"]);
  });

  it("walks an undirected edge both ways", () => {
    expect(ids("MATCH (c {name: 'Cleo'})-[:FRIEND]->(x) RETURN x").nodes).toEqual(["a"]);
    expect(ids("MATCH (c {name: 'Cleo'})<-[:FRIEND]-(x) RETURN x").nodes).toEqual(["a"]);
  });

  it("walks variable-length paths without reusing an edge", () => {
    const result = ids("MATCH (a {name: 'Ada'})-[r:KNOWS*1..2]->(x) RETURN r, x");
    expect(result.nodes).toEqual(["b", "c"]);
    expect(result.edges).toEqual(["ab", "bc"]);
    // A cycle ends: each edge is walked once.
    const cyclic: QueryableGraph = { nodes: [node("x"), node("y")], edges: [edge("xy", "x", "y", "T"), edge("yx", "y", "x", "T")] };
    expect(runGraphQuery(cyclic, "MATCH (a)-[*1..8]->(b) RETURN b").rowCount).toBe(4);
  });

  it("joins comma-separated patterns on shared variables", () => {
    expect(ids("MATCH (a)-[:KNOWS]->(b), (b)-[:KNOWS]->(c) RETURN a, c").nodes).toEqual(["a", "c"]);
  });

  it("evaluates WHERE", () => {
    expect(ids("MATCH (n:Person) WHERE n.age >= 30 AND NOT n.name = 'Bob' RETURN n").nodes).toEqual(["a"]);
    expect(ids("MATCH (n:Person) WHERE n.age < 26 OR n.age > 40 RETURN n").nodes).toEqual(["b", "c"]);
    expect(ids("MATCH (n) WHERE n.name STARTS WITH 'A' RETURN n").nodes).toEqual(["a"]);
    expect(ids("MATCH (n) WHERE n.name ENDS WITH 'b' RETURN n").nodes).toEqual(["b"]);
    expect(ids("MATCH (n) WHERE n.tags CONTAINS 'math' RETURN n").nodes).toEqual(["a"]);
    expect(ids("MATCH (n) WHERE n.name IN ['Ada', 'Cleo'] RETURN n").nodes).toEqual(["a", "c"]);
    expect(ids("MATCH (n:Machine) WHERE n.year IS NULL RETURN n").nodes).toEqual(["alone"]);
    expect(ids("MATCH (n:Machine) WHERE n.year IS NOT NULL RETURN n").nodes).toEqual(["m"]);
    expect(ids("MATCH (n) WHERE n.address.city = 'London' RETURN n").nodes).toEqual(["a"]);
    expect(ids("MATCH (n) WHERE (n.age > 40 OR n.age < 26) AND n.name <> 'Bob' RETURN n").nodes).toEqual(["c"]);
    expect(ids("MATCH (n) WHERE n.age > -5 AND n.age <-5 RETURN n").nodes).toEqual([]);
  });

  it("offers element fields and functions", () => {
    expect(ids("MATCH (n) WHERE n.id = 'a' RETURN n").nodes).toEqual(["a"]);
    expect(ids("MATCH (n) WHERE n.label = 'ALONE' RETURN n").nodes).toEqual(["alone"]);
    expect(ids("MATCH (n) WHERE degree(n) = 0 RETURN n").nodes).toEqual(["alone"]);
    expect(ids("MATCH (n) WHERE toLower(n.name) = 'ada' RETURN n").nodes).toEqual(["a"]);
    expect(ids("MATCH (n) WHERE size(labels(n)) = 2 RETURN n").nodes).toEqual(["b"]);
    expect(ids("MATCH ()-[r]->() WHERE type(r) = 'USES' RETURN r").edges).toEqual(["cm"]);
    expect(ids("MATCH ()-[r]->() WHERE r.source = 'a' AND r.since = 2001 RETURN r").edges).toEqual(["ab"]);
  });

  it("returns everything matched without RETURN, and only the named variables with it", () => {
    expect(ids("MATCH (a {name: 'Ada'})-[:KNOWS]->(b)")).toEqual({ nodes: ["a", "b"], edges: ["ab"] });
    expect(ids("MATCH (a {name: 'Ada'})-[:KNOWS]->(b) RETURN *")).toEqual({ nodes: ["a", "b"], edges: ["ab"] });
    expect(ids("MATCH (a {name: 'Ada'})-[r:KNOWS]->(b) RETURN b")).toEqual({ nodes: ["b"], edges: [] });
  });

  it("projects rows and applies LIMIT", () => {
    const result = runGraphQuery(GRAPH, "MATCH (n:Person) RETURN n.name AS who, n LIMIT 2;");
    expect(result.rowCount).toBe(2);
    expect(result.rows).toEqual([{ who: "Ada", n: "a" }, { who: "Bob", n: "b" }]);
  });

  it("stops a runaway query and says so", () => {
    const large: QueryableGraph = { nodes: Array.from({ length: 2000 }, (_, index) => node(`n${index}`)), edges: [] };
    const result = runGraphQuery(large, "MATCH (a), (b), (c) RETURN a");
    expect(result.truncated).toBe(true);
    expect(result.rowCount).toBeLessThanOrEqual(5000);
  });

  it("never reads through the prototype chain", () => {
    expect(ids("MATCH (n) WHERE n.constructor IS NOT NULL RETURN n").nodes).toEqual([]);
    expect(ids("MATCH (n) WHERE n.address.__proto__ IS NOT NULL RETURN n").nodes).toEqual([]);
  });
});

describe("graph query syntax", () => {
  it.each([
    ["", "empty"],
    ["SELECT * FROM nodes", "MATCH"],
    ["MATCH (n", '")"'],
    ["MATCH (n) WHERE", "a value"],
    ["MATCH (n) WHERE m.age > 1 RETURN n", 'Unknown variable "m"'],
    ["MATCH (n) RETURN m", 'Unknown variable "m"'],
    ["MATCH (n) WHERE explode(n) RETURN n", 'Unknown function "explode"'],
    ["MATCH (a)<-[r]->(b)", "both ways"],
    ["MATCH (a)-[*1..99]->(b)", "at most 8 hops"],
    ['MATCH (n {name: "x', "Unclosed string"],
    ["MATCH (n) RETURN n EXTRA", "the end of the query"],
    ["MATCH (n) SET n.x = 1", "the end of the query"],
    ["MATCH (n) DELETE n", "the end of the query"],
  ])("rejects %j", (query, message) => {
    expect(() => parseGraphQuery(query)).toThrow(GraphQuerySyntaxError);
    expect(() => parseGraphQuery(query)).toThrow(message);
  });

  it("rejects an overlong query", () => {
    expect(() => parseGraphQuery(`MATCH (n) WHERE n.x = "${"a".repeat(2000)}"`)).toThrow("at most");
  });
});
