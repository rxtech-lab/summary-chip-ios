/**
 * Graph queries: a read-only subset of Cypher, run in memory over a graph document.
 *
 *   MATCH (a:Person {city: "Paris"})-[r:KNOWS*1..2]->(b)
 *   WHERE a.age >= 30 AND NOT b.name CONTAINS "x"
 *   RETURN a, b.name LIMIT 20
 *
 * The result names the nodes and edges to light up. Without `RETURN` (or with `RETURN *`) that is
 * everything matched; otherwise only the returned variables. The work is capped, so a query with a
 * huge cross product stops early and reports `truncated` instead of holding the request.
 * Spec: `docs/graphs.md`.
 */

export interface QueryableNode { id: string; label: string; types: string[]; properties: Record<string, unknown> }
export interface QueryableEdge { id: string; source: string; target: string; label: string; directed: boolean; properties: Record<string, unknown> }
export interface QueryableGraph { nodes: QueryableNode[]; edges: QueryableEdge[] }

export interface GraphQueryResult {
  nodeIds: string[];
  edgeIds: string[];
  /** Matches found, up to the cap. */
  rowCount: number;
  /** The first matches, as `{variable or expression: value}`; variables hold element ids. */
  rows: Record<string, unknown>[];
  /** The work cap or row cap stopped the search before it finished. */
  truncated: boolean;
}

export class GraphQuerySyntaxError extends Error {}

/** How to write a query, for agents. */
export const GRAPH_QUERY_GUIDE = "Queries are a read-only subset of Cypher: MATCH (a:Type {prop: value})-[r:LABEL*1..3]->(b), comma-separated patterns, "
  + "WHERE with = <> < <= > >= CONTAINS, STARTS WITH, ENDS WITH, IN, IS [NOT] NULL, AND, OR, NOT; RETURN variables or expressions (AS, or * / omitted for everything matched); LIMIT. "
  + "n.prop reads a property (dots go deeper); id, label, types, source and target read the element's own fields when no property has that name. Functions: id, label, type, types, labels, degree, size, toLower, toUpper. "
  + "Types and relationship labels match case-insensitively; (n:Person) matches a node's types and [r:KNOWS] an edge's label.";

export const MAX_QUERY_LENGTH = 2000;
const MAX_MATCHES = 5000;
const MAX_STEPS = 500_000;
const MAX_RESULT_ROWS = 50;
const DEFAULT_MAX_HOPS = 5;
const MAX_HOPS = 8;
const FORBIDDEN_KEYS = new Set(["__proto__", "prototype", "constructor"]);

/* ---------------------------------------- Tokens ---------------------------------------- */

type Token =
  | { kind: "word"; value: string; at: number }
  | { kind: "string"; value: string; at: number }
  | { kind: "number"; value: number; at: number }
  | { kind: "symbol"; value: string; at: number }
  | { kind: "end"; at: number };

const SYMBOLS = ["<>", "!=", "<=", ">=", "->", "<-", "..", "(", ")", "[", "]", "{", "}", ":", ",", ".", "-", "*", "|", "=", "<", ">", ";"];

function tokenize(source: string): Token[] {
  const tokens: Token[] = [];
  let at = 0;
  while (at < source.length) {
    const char = source[at];
    if (/\s/.test(char)) { at += 1; continue; }
    if (/[A-Za-z_]/.test(char)) {
      const start = at;
      while (at < source.length && /[A-Za-z0-9_]/.test(source[at])) at += 1;
      tokens.push({ kind: "word", value: source.slice(start, at), at: start });
      continue;
    }
    if (char === "`") {
      const end = source.indexOf("`", at + 1);
      if (end < 0) throw new GraphQuerySyntaxError(`Unclosed \` at position ${at}`);
      tokens.push({ kind: "word", value: source.slice(at + 1, end), at });
      at = end + 1;
      continue;
    }
    if (/[0-9]/.test(char)) {
      const start = at;
      while (at < source.length && /[0-9]/.test(source[at])) at += 1;
      // `1..3` is a range, not a decimal point.
      if (source[at] === "." && /[0-9]/.test(source[at + 1] ?? "")) {
        at += 1;
        while (at < source.length && /[0-9]/.test(source[at])) at += 1;
      }
      tokens.push({ kind: "number", value: Number(source.slice(start, at)), at: start });
      continue;
    }
    if (char === '"' || char === "'") {
      const start = at;
      let value = "";
      at += 1;
      while (at < source.length && source[at] !== char) {
        if (source[at] === "\\" && at + 1 < source.length) at += 1;
        value += source[at];
        at += 1;
      }
      if (at >= source.length) throw new GraphQuerySyntaxError(`Unclosed string at position ${start}`);
      at += 1;
      tokens.push({ kind: "string", value, at: start });
      continue;
    }
    const symbol = SYMBOLS.find((candidate) => source.startsWith(candidate, at));
    if (!symbol) throw new GraphQuerySyntaxError(`Unexpected "${char}" at position ${at}`);
    tokens.push({ kind: "symbol", value: symbol, at });
    at += symbol.length;
  }
  tokens.push({ kind: "end", at: source.length });
  return tokens;
}

/* ---------------------------------------- Syntax ---------------------------------------- */

type Literal = string | number | boolean | null;
type Operand =
  | { type: "literal"; value: Literal }
  | { type: "list"; items: Operand[] }
  | { type: "property"; variable: string; path: string[] }
  | { type: "variable"; variable: string }
  | { type: "call"; name: string; argument: Operand };
type Comparison = "=" | "!=" | "<" | "<=" | ">" | ">=" | "contains" | "starts" | "ends" | "in";
type Condition =
  | { type: "and" | "or"; left: Condition; right: Condition }
  | { type: "not"; condition: Condition }
  | { type: "compare"; op: Comparison; left: Operand; right: Operand }
  | { type: "isNull"; operand: Operand; negated: boolean }
  | { type: "truthy"; operand: Operand };

interface NodePattern { variable: string | null; types: string[]; properties: [string, Literal][] }
interface RelationPattern {
  variable: string | null;
  labels: string[];
  properties: [string, Literal][];
  direction: "out" | "in" | "both";
  minHops: number;
  maxHops: number;
}
interface PathPattern { start: NodePattern; steps: { relation: RelationPattern; node: NodePattern }[] }
interface ReturnItem { operand: Operand; name: string }
export interface ParsedGraphQuery {
  patterns: PathPattern[];
  where: Condition | null;
  /** null: everything matched. */
  returns: ReturnItem[] | null;
  limit: number | null;
}

class Parser {
  private index = 0;
  constructor(private readonly tokens: Token[], private readonly source: string) {}

  private get token(): Token { return this.tokens[this.index]; }
  private fail(expected: string): never {
    const found = this.token.kind === "end" ? "the end of the query" : `"${this.source.slice(this.token.at, this.token.at + 12).split(/\s/)[0]}"`;
    throw new GraphQuerySyntaxError(`Expected ${expected} but found ${found} at position ${this.token.at}`);
  }
  private symbol(value: string): boolean {
    if (this.token.kind === "symbol" && this.token.value === value) { this.index += 1; return true; }
    return false;
  }
  private expectSymbol(value: string) { if (!this.symbol(value)) this.fail(`"${value}"`); }
  private keyword(value: string): boolean {
    if (this.token.kind === "word" && this.token.value.toUpperCase() === value) { this.index += 1; return true; }
    return false;
  }
  private identifier(what: string): string {
    if (this.token.kind !== "word") this.fail(what);
    const { value } = this.token as Extract<Token, { kind: "word" }>;
    this.index += 1;
    return value;
  }

  parse(): ParsedGraphQuery {
    if (!this.keyword("MATCH")) this.fail("MATCH");
    const patterns = [this.path()];
    while (this.symbol(",")) patterns.push(this.path());
    const where = this.keyword("WHERE") ? this.or() : null;
    let returns: ReturnItem[] | null = null;
    if (this.keyword("RETURN")) {
      this.keyword("DISTINCT");
      if (!this.symbol("*")) {
        returns = [this.returnItem()];
        while (this.symbol(",")) returns.push(this.returnItem());
      }
    }
    let limit: number | null = null;
    if (this.keyword("LIMIT")) {
      const token = this.token;
      if (token.kind !== "number" || !Number.isInteger(token.value)) this.fail("a whole number after LIMIT");
      limit = (token as Extract<Token, { kind: "number" }>).value;
      this.index += 1;
    }
    this.symbol(";");
    if (this.token.kind !== "end") this.fail("the end of the query");
    return { patterns, where, returns, limit };
  }

  private path(): PathPattern {
    const start = this.node();
    const steps: PathPattern["steps"] = [];
    while (this.token.kind === "symbol" && (this.token.value === "-" || this.token.value === "<-" || this.token.value === "->")) {
      const relation = this.relation();
      steps.push({ relation, node: this.node() });
    }
    return { start, steps };
  }

  private node(): NodePattern {
    this.expectSymbol("(");
    const variable = this.token.kind === "word" ? this.identifier("a variable") : null;
    const types: string[] = [];
    if (this.symbol(":")) {
      types.push(this.identifier("a type"));
      while (this.symbol("|") || this.symbol(":")) types.push(this.identifier("a type"));
    }
    const properties = this.token.kind === "symbol" && this.token.value === "{" ? this.properties() : [];
    this.expectSymbol(")");
    return { variable, types, properties };
  }

  private relation(): RelationPattern {
    // `-->` and `--` tokenise as `-` `->` and `-` `-`.
    const incoming = this.symbol("<-");
    if (!incoming && this.symbol("->")) {
      return { variable: null, labels: [], properties: [], direction: "out", minHops: 1, maxHops: 1 };
    }
    if (!incoming) this.expectSymbol("-");
    let variable: string | null = null;
    const labels: string[] = [];
    let properties: [string, Literal][] = [];
    let minHops = 1;
    let maxHops = 1;
    if (this.symbol("[")) {
      if (this.token.kind === "word") variable = this.identifier("a variable");
      if (this.symbol(":")) {
        labels.push(this.identifier("a relationship label"));
        while (this.symbol("|")) { this.symbol(":"); labels.push(this.identifier("a relationship label")); }
      }
      if (this.symbol("*")) [minHops, maxHops] = this.hops();
      if (this.token.kind === "symbol" && this.token.value === "{") properties = this.properties();
      this.expectSymbol("]");
    }
    let outgoing = false;
    if (this.symbol("->")) outgoing = true;
    else this.expectSymbol("-");
    if (incoming && outgoing) throw new GraphQuerySyntaxError("A relationship can't point both ways; drop an arrow to match either direction");
    return { variable, labels, properties, direction: incoming ? "in" : outgoing ? "out" : "both", minHops, maxHops };
  }

  private hops(): [number, number] {
    const whole = (): number | null => {
      if (this.token.kind !== "number") return null;
      const { value } = this.token as Extract<Token, { kind: "number" }>;
      this.index += 1;
      return Math.trunc(value);
    };
    const first = whole();
    let min = first ?? 1;
    let max = first ?? DEFAULT_MAX_HOPS;
    if (this.symbol("..")) max = whole() ?? DEFAULT_MAX_HOPS;
    if (min > max) [min, max] = [max, min];
    if (max > MAX_HOPS) throw new GraphQuerySyntaxError(`A relationship can span at most ${MAX_HOPS} hops`);
    return [min, max];
  }

  private properties(): [string, Literal][] {
    this.expectSymbol("{");
    const entries: [string, Literal][] = [];
    if (!this.symbol("}")) {
      do {
        const key = this.identifier("a property name");
        this.expectSymbol(":");
        entries.push([key, this.literal()]);
      } while (this.symbol(","));
      this.expectSymbol("}");
    }
    return entries;
  }

  private literal(): Literal {
    const operand = this.primary();
    if (operand.type !== "literal") this.fail("a value");
    return (operand as Extract<Operand, { type: "literal" }>).value;
  }

  private returnItem(): ReturnItem {
    const start = this.token.at;
    const operand = this.operand();
    const end = this.token.at;
    const name = this.keyword("AS") ? this.identifier("a name") : this.source.slice(start, end).trim();
    return { operand, name };
  }

  private or(): Condition {
    let left = this.and();
    while (this.keyword("OR")) left = { type: "or", left, right: this.and() };
    return left;
  }

  private and(): Condition {
    let left = this.not();
    while (this.keyword("AND")) left = { type: "and", left, right: this.not() };
    return left;
  }

  private not(): Condition {
    if (this.keyword("NOT")) return { type: "not", condition: this.not() };
    if (this.token.kind === "symbol" && this.token.value === "(") {
      this.index += 1;
      const inner = this.or();
      this.expectSymbol(")");
      return inner;
    }
    return this.comparison();
  }

  private comparison(): Condition {
    const left = this.operand();
    if (this.keyword("IS")) {
      const negated = this.keyword("NOT");
      if (!this.keyword("NULL")) this.fail("NULL");
      return { type: "isNull", operand: left, negated };
    }
    // `a.x <-5` tokenises as an arrow; here it can only be "less than minus five".
    if (this.symbol("<-")) {
      const next = this.token;
      if (next.kind !== "number") this.fail("a number");
      this.index += 1;
      return { type: "compare", op: "<", left, right: { type: "literal", value: -(next as Extract<Token, { kind: "number" }>).value } };
    }
    for (const op of ["=", "<>", "!=", "<=", ">=", "<", ">"]) {
      if (this.symbol(op)) return { type: "compare", op: (op === "<>" ? "!=" : op) as Comparison, left, right: this.operand() };
    }
    if (this.keyword("CONTAINS")) return { type: "compare", op: "contains", left, right: this.operand() };
    if (this.keyword("IN")) return { type: "compare", op: "in", left, right: this.operand() };
    if (this.keyword("STARTS")) {
      if (!this.keyword("WITH")) this.fail("WITH");
      return { type: "compare", op: "starts", left, right: this.operand() };
    }
    if (this.keyword("ENDS")) {
      if (!this.keyword("WITH")) this.fail("WITH");
      return { type: "compare", op: "ends", left, right: this.operand() };
    }
    return { type: "truthy", operand: left };
  }

  private operand(): Operand { return this.primary(); }

  private primary(): Operand {
    const token = this.token;
    if (token.kind === "string") { this.index += 1; return { type: "literal", value: token.value }; }
    if (token.kind === "number") { this.index += 1; return { type: "literal", value: token.value }; }
    if (token.kind === "symbol" && token.value === "-") {
      this.index += 1;
      const next = this.token;
      if (next.kind !== "number") this.fail("a number");
      this.index += 1;
      return { type: "literal", value: -(next as Extract<Token, { kind: "number" }>).value };
    }
    if (token.kind === "symbol" && token.value === "[") {
      this.index += 1;
      const items: Operand[] = [];
      if (!this.symbol("]")) {
        do { items.push(this.operand()); } while (this.symbol(","));
        this.expectSymbol("]");
      }
      return { type: "list", items };
    }
    if (token.kind !== "word") this.fail("a value");
    const word = this.identifier("a value");
    const upper = word.toUpperCase();
    if (upper === "TRUE") return { type: "literal", value: true };
    if (upper === "FALSE") return { type: "literal", value: false };
    if (upper === "NULL") return { type: "literal", value: null };
    if (this.symbol("(")) {
      const name = word.toLowerCase();
      if (!FUNCTIONS.has(name)) throw new GraphQuerySyntaxError(`Unknown function "${word}". Available: ${[...FUNCTIONS].join(", ")}`);
      const argument = this.operand();
      this.expectSymbol(")");
      return { type: "call", name, argument };
    }
    const path: string[] = [];
    while (this.symbol(".")) path.push(this.identifier("a property name"));
    return path.length ? { type: "property", variable: word, path } : { type: "variable", variable: word };
  }
}

const FUNCTIONS = new Set(["id", "label", "type", "types", "labels", "degree", "size", "tolower", "toupper"]);

function variablesOf(operand: Operand, into: Set<string>) {
  if (operand.type === "property" || operand.type === "variable") into.add(operand.variable);
  else if (operand.type === "call") variablesOf(operand.argument, into);
  else if (operand.type === "list") operand.items.forEach((item) => variablesOf(item, into));
}

function conditionVariables(condition: Condition, into: Set<string>) {
  switch (condition.type) {
    case "and": case "or": conditionVariables(condition.left, into); conditionVariables(condition.right, into); break;
    case "not": conditionVariables(condition.condition, into); break;
    case "compare": variablesOf(condition.left, into); variablesOf(condition.right, into); break;
    case "isNull": case "truthy": variablesOf(condition.operand, into); break;
  }
}

/** Parses a query, refusing unknown variables so a typo is an error rather than an empty result. */
export function parseGraphQuery(source: string): ParsedGraphQuery {
  const text = source.trim();
  if (!text) throw new GraphQuerySyntaxError("The query is empty");
  if (text.length > MAX_QUERY_LENGTH) throw new GraphQuerySyntaxError(`A query can be at most ${MAX_QUERY_LENGTH} characters`);
  const parsed = new Parser(tokenize(text), text).parse();
  const declared = new Set<string>();
  for (const pattern of parsed.patterns) {
    if (pattern.start.variable) declared.add(pattern.start.variable);
    for (const step of pattern.steps) {
      if (step.relation.variable) declared.add(step.relation.variable);
      if (step.node.variable) declared.add(step.node.variable);
    }
  }
  const used = new Set<string>();
  if (parsed.where) conditionVariables(parsed.where, used);
  parsed.returns?.forEach((item) => variablesOf(item.operand, used));
  for (const variable of used) {
    if (!declared.has(variable)) throw new GraphQuerySyntaxError(`Unknown variable "${variable}". Name it in MATCH first`);
  }
  return parsed;
}

/* --------------------------------------- Execution --------------------------------------- */

interface Link { edge: QueryableEdge; to: QueryableNode }
type Bound = QueryableNode | QueryableEdge | QueryableEdge[];
type Row = Map<string, Bound>;

function isEdge(value: Bound): value is QueryableEdge { return !Array.isArray(value) && "source" in value; }

function readPath(root: unknown, path: string[]): unknown {
  let value = root;
  for (const key of path) {
    if (FORBIDDEN_KEYS.has(key) || value === null || typeof value !== "object" || Array.isArray(value)) return null;
    value = (value as Record<string, unknown>)[key];
  }
  return value === undefined ? null : value;
}

/** `n.age` reads the properties; `id`, `label` and friends fall back to the element's own fields. */
function readProperty(element: QueryableNode | QueryableEdge, path: string[]): unknown {
  const value = readPath(element.properties, path);
  if (value !== null || path.length !== 1) return value;
  const key = path[0];
  if (key === "id" || key === "label") return element[key];
  if ("source" in element) return key === "source" ? element.source : key === "target" ? element.target : null;
  return key === "types" ? element.types : null;
}

function matchesProperties(element: QueryableNode | QueryableEdge, wanted: [string, Literal][]): boolean {
  return wanted.every(([key, value]) => looseEqual(readProperty(element, [key]), value));
}

function looseEqual(left: unknown, right: unknown): boolean {
  if (left === null || right === null) return false;
  if (typeof left !== "object" && typeof right !== "object") return left === right;
  return JSON.stringify(left) === JSON.stringify(right);
}

function matchesType(wanted: string[], actual: string[]): boolean {
  return wanted.length === 0 || wanted.some((type) => actual.some((candidate) => candidate.toLowerCase() === type.toLowerCase()));
}

function matchesNode(node: QueryableNode, pattern: NodePattern): boolean {
  return matchesType(pattern.types, node.types) && matchesProperties(node, pattern.properties);
}

function ordered(left: unknown, right: unknown): number | null {
  if (typeof left === "number" && typeof right === "number") return left - right;
  if (typeof left === "string" && typeof right === "string") return left < right ? -1 : left > right ? 1 : 0;
  return null;
}

/**
 * Runs a query. A malformed one throws `GraphQuerySyntaxError`; whichever element a query reads,
 * properties are data only and nothing they contain is ever evaluated.
 */
export function runGraphQuery(graph: QueryableGraph, source: string): GraphQueryResult {
  const query = parseGraphQuery(source);
  const nodesById = new Map(graph.nodes.map((node) => [node.id, node]));
  const outgoing = new Map<string, Link[]>();
  const incoming = new Map<string, Link[]>();
  const add = (index: Map<string, Link[]>, key: string, link: Link) => {
    const links = index.get(key);
    if (links) links.push(link); else index.set(key, [link]);
  };
  const degree = new Map<string, number>();
  for (const edge of graph.edges) {
    const from = nodesById.get(edge.source);
    const to = nodesById.get(edge.target);
    if (!from || !to) continue;
    degree.set(from.id, (degree.get(from.id) ?? 0) + 1);
    if (from.id !== to.id) degree.set(to.id, (degree.get(to.id) ?? 0) + 1);
    add(outgoing, from.id, { edge, to });
    add(incoming, to.id, { edge, to: from });
    if (!edge.directed && from.id !== to.id) {
      add(outgoing, to.id, { edge, to: from });
      add(incoming, from.id, { edge, to });
    }
  }

  const linksFrom = (id: string, direction: RelationPattern["direction"]): Link[] => {
    if (direction === "out") return outgoing.get(id) ?? [];
    if (direction === "in") return incoming.get(id) ?? [];
    const seen = new Set<string>();
    return [...(outgoing.get(id) ?? []), ...(incoming.get(id) ?? [])].filter((link) => {
      const key = `${link.edge.id}>${link.to.id}`;
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    });
  };

  const operandValue = (operand: Operand, row: Row): unknown => {
    switch (operand.type) {
      case "literal": return operand.value;
      case "list": return operand.items.map((item) => operandValue(item, row));
      case "variable": {
        const bound = row.get(operand.variable);
        if (!bound) return null;
        return Array.isArray(bound) ? bound.map((edge) => edge.id) : bound.id;
      }
      case "property": {
        const bound = row.get(operand.variable);
        if (!bound || Array.isArray(bound)) return null;
        return readProperty(bound, operand.path);
      }
      case "call": {
        if (operand.argument.type === "variable") {
          const bound = row.get(operand.argument.variable);
          if (bound && !Array.isArray(bound)) {
            switch (operand.name) {
              case "id": return bound.id;
              case "label": case "type": return bound.label;
              case "types": case "labels": return isEdge(bound) ? [bound.label] : bound.types;
              case "degree": return isEdge(bound) ? null : degree.get(bound.id) ?? 0;
            }
          }
        }
        const value = operandValue(operand.argument, row);
        if (operand.name === "size") return Array.isArray(value) || typeof value === "string" ? value.length : null;
        if (operand.name === "tolower") return typeof value === "string" ? value.toLowerCase() : null;
        if (operand.name === "toupper") return typeof value === "string" ? value.toUpperCase() : null;
        return null;
      }
    }
  };

  const holds = (condition: Condition, row: Row): boolean => {
    switch (condition.type) {
      case "and": return holds(condition.left, row) && holds(condition.right, row);
      case "or": return holds(condition.left, row) || holds(condition.right, row);
      case "not": return !holds(condition.condition, row);
      case "isNull": {
        const value = operandValue(condition.operand, row);
        return (value === null) !== condition.negated;
      }
      case "truthy": {
        const value = operandValue(condition.operand, row);
        return value !== null && value !== false && value !== 0 && value !== "";
      }
      case "compare": {
        const left = operandValue(condition.left, row);
        const right = operandValue(condition.right, row);
        switch (condition.op) {
          case "=": return looseEqual(left, right);
          case "!=": return left !== null && right !== null && !looseEqual(left, right);
          case "<": { const order = ordered(left, right); return order !== null && order < 0; }
          case "<=": { const order = ordered(left, right); return order !== null && order <= 0; }
          case ">": { const order = ordered(left, right); return order !== null && order > 0; }
          case ">=": { const order = ordered(left, right); return order !== null && order >= 0; }
          case "contains":
            if (Array.isArray(left)) return left.some((item) => looseEqual(item, right));
            return typeof left === "string" && typeof right === "string" && left.includes(right);
          case "starts": return typeof left === "string" && typeof right === "string" && left.startsWith(right);
          case "ends": return typeof left === "string" && typeof right === "string" && left.endsWith(right);
          case "in": return Array.isArray(right) && right.some((item) => looseEqual(left, item));
        }
      }
    }
  };

  // Anonymous elements still light up when everything matched is shown.
  const matchedNodes = new Set<string>();
  const matchedEdges = new Set<string>();
  const rows: Record<string, unknown>[] = [];
  const limit = Math.min(query.limit ?? MAX_MATCHES, MAX_MATCHES);
  let steps = 0;
  let matches = 0;
  let truncated = false;

  const record = (row: Row, nodes: QueryableNode[], edges: QueryableEdge[]) => {
    if (query.where && !holds(query.where, row)) return;
    matches += 1;
    if (query.returns) {
      for (const item of query.returns) {
        const names = new Set<string>();
        variablesOf(item.operand, names);
        for (const name of names) {
          const bound = row.get(name);
          if (!bound) continue;
          if (Array.isArray(bound)) bound.forEach((edge) => matchedEdges.add(edge.id));
          else if (isEdge(bound)) matchedEdges.add(bound.id);
          else matchedNodes.add(bound.id);
        }
      }
    } else {
      nodes.forEach((node) => matchedNodes.add(node.id));
      edges.forEach((edge) => matchedEdges.add(edge.id));
    }
    if (rows.length < MAX_RESULT_ROWS) {
      const output: Record<string, unknown> = {};
      if (query.returns) for (const item of query.returns) output[item.name] = operandValue(item.operand, row);
      else for (const [name] of row) output[name] = operandValue({ type: "variable", variable: name }, row);
      rows.push(output);
    }
  };

  const finished = () => matches >= limit;
  const spent = () => {
    steps += 1;
    if (steps > MAX_STEPS) truncated = true;
    return truncated;
  };

  /** Joins the comma-separated patterns; the `row` carries variables they share. */
  const walkPatterns = (index: number, row: Row, nodes: QueryableNode[], edges: QueryableEdge[]) => {
    if (finished() || spent()) return;
    if (index === query.patterns.length) { record(row, nodes, edges); return; }
    const pattern = query.patterns[index];
    const bound = pattern.start.variable ? row.get(pattern.start.variable) : undefined;
    const candidates = bound ? (isNodeBound(bound) ? [bound] : []) : graph.nodes;
    for (const node of candidates) {
      if (finished() || spent()) return;
      if (!matchesNode(node, pattern.start)) continue;
      const next = bindVariable(row, pattern.start.variable, node);
      walkSteps(index, pattern, 0, node, next, [...nodes, node], edges, new Set());
    }
  };

  const walkSteps = (patternIndex: number, pattern: PathPattern, stepIndex: number, at: QueryableNode, row: Row, nodes: QueryableNode[], edges: QueryableEdge[], used: Set<string>) => {
    if (finished() || spent()) return;
    if (stepIndex === pattern.steps.length) { walkPatterns(patternIndex + 1, row, nodes, edges); return; }
    const { relation, node: target } = pattern.steps[stepIndex];
    // A relationship isn't walked twice in one path (Cypher's rule), so cycles end.
    const hop = (current: QueryableNode, trail: QueryableEdge[], trailNodes: QueryableNode[], walked: Set<string>) => {
      if (finished() || spent()) return;
      if (trail.length >= relation.minHops && matchesNode(current, target)) {
        const boundTarget = target.variable ? row.get(target.variable) : undefined;
        if (!boundTarget || boundTarget === current) {
          const value: Bound = relation.maxHops === 1 ? trail[0] : trail;
          const withRelation = relation.variable && trail.length ? bindVariable(row, relation.variable, value) : row;
          const nextRow = bindVariable(withRelation, target.variable, current);
          walkSteps(patternIndex, pattern, stepIndex + 1, current, nextRow, [...nodes, ...trailNodes], [...edges, ...trail], walked);
        }
      }
      if (trail.length >= relation.maxHops) return;
      for (const link of linksFrom(current.id, relation.direction)) {
        if (walked.has(link.edge.id)) continue;
        if (!matchesType(relation.labels, [link.edge.label]) || !matchesProperties(link.edge, relation.properties)) continue;
        const nextWalked = new Set(walked);
        nextWalked.add(link.edge.id);
        hop(link.to, [...trail, link.edge], [...trailNodes, link.to], nextWalked);
        if (finished() || truncated) return;
      }
    };
    hop(at, [], [], used);
  };

  walkPatterns(0, new Map(), [], []);
  if (matches >= MAX_MATCHES) truncated = true;
  return { nodeIds: [...matchedNodes], edgeIds: [...matchedEdges], rowCount: matches, rows, truncated };
}

function isNodeBound(value: Bound): value is QueryableNode { return !Array.isArray(value) && !("source" in value); }

function bindVariable(row: Row, variable: string | null, value: Bound): Row {
  if (!variable) return row;
  const next = new Map(row);
  next.set(variable, value);
  return next;
}
