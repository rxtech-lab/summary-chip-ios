import { isDeepStrictEqual } from "node:util";
import { ApiError } from "@/lib/http/errors";
import {
  resumeDocumentSchema,
  type ResumeDocument,
  type ResumeOperation,
  type ResumeBaseline,
} from "@/lib/contracts/resume";
import type { TranslationLanguage } from "@/lib/contracts/api";

type Node = Record<string, unknown>;
export type Words = Record<string, string | null>;
export type Edition = { words: Words; baselines: Record<string, ResumeBaseline>; detached?: Words };
type Edit = Extract<ResumeOperation, { op: "set" | "insert" | "move" }> | { op: "remove"; path: string };
type Rule = { edit: Edit; neighbors?: string[]; baseValue?: unknown };
type Recovery = { values: Record<string, Node>; neighbors: string[]; kept: boolean };
export interface Overlay {
  rules: Rule[];
  words: Record<string, Words>;
  inherited?: Record<string, Record<string, true>>;
  baseWords: Record<string, Words>;
  authored: Record<string, { language: TranslationLanguage; value: string | null }>;
  recoveries: Record<string, Recovery>;
  baselines: Record<string, Record<string, ResumeBaseline>>;
}
export const emptyOverlay = (): Overlay => ({
  rules: [],
  words: {},
  baseWords: {},
  authored: {},
  recoveries: {},
  baselines: {},
});
export const emptyEdition = (): Edition => ({ words: {}, baselines: {} });
export function invalid(message: string): never {
  throw new ApiError(422, "RESUME_INVALID", message);
}
const id = "[A-Za-z0-9_-]+";
const section = `/sections/${id}`;
const entry = `${section}/entries/${id}`;
const bullet = `${entry}/bullets/${id}`;
const link = `/links/${id}`;
const matches = (paths: string[]) => new RegExp("^(?:" + paths.join("|") + ")$");
const wording = matches([
  "/candidateName",
  "/headline",
  "/contact/location",
  link + "/label",
  section + "/title",
  entry + "/(?:title|organization|location|description)",
  bullet + "/text",
]);
const structuralField = matches([
  "/avatarAssetId",
  "/contact/(?:email|phone)",
  link + "/url",
  section + "/kind",
  entry + "/(?:startDate|endDate|current|url)",
]);
const item = matches([section, entry, bullet, link]);
const list = matches(["/sections", "/links", section + "/entries", entry + "/bullets"]);
export const isWordingPath = (path: string) => wording.test(path);
export const under = (path: string, ancestor: string) => path === ancestor || path.startsWith(ancestor + "/");
const parent = (path: string) => path.slice(0, path.lastIndexOf("/"));
const key = (path: string) => path.slice(path.lastIndexOf("/") + 1);
const node = (v: unknown): v is Node => typeof v === "object" && v !== null && !Array.isArray(v);

export function valueAt(root: unknown, path: string): unknown {
  let current = root;
  for (const segment of path.split("/").filter(Boolean)) {
    if (Array.isArray(current)) current = current.find((x) => x.id === segment);
    else if (node(current) && Object.hasOwn(current, segment)) current = current[segment];
    else return undefined;
  }
  return current;
}

export function splitWording(doc: ResumeDocument): { structure: Node; words: Words } {
  const structure = structuredClone(doc) as Node;
  const words: Words = {};
  function visit(value: unknown, p: string) {
    if (Array.isArray(value)) {
      for (const child of value) visit(child, p + "/" + child.id);
    } else if (node(value)) {
      for (const [field, child] of Object.entries(value)) {
        const path = p + "/" + field;
        if (isWordingPath(path) && typeof child === "string") {
          words[path] = child;
          delete value[field];
        } else visit(child, path);
      }
    }
  }
  visit(structure, "");
  return { structure, words };
}

function writeField(root: Node, path: string, value: unknown): boolean {
  if (parent(path) === "/contact" && !root.contact && value != null) root.contact = {};
  const container = valueAt(root, parent(path));
  if (!node(container)) return false;
  if (value == null) {
    delete container[key(path)];
    if (parent(path) === "/contact" && !Object.keys(container).length) delete root.contact;
  } else container[key(path)] = value;
  return true;
}
export function assemble(structure: Node, ...wordSets: Words[]): ResumeDocument {
  const result = structuredClone(structure);
  for (const words of wordSets) {
    for (const [path, value] of Object.entries(words)) writeField(result, path, value);
  }
  return result as ResumeDocument;
}

function place(items: Node[], value: Node, after: string | null | undefined, neighbors?: string[]) {
  if (after === null) {
    items.unshift(value);
    return;
  }
  if (after === undefined) {
    items.push(value);
    return;
  }
  const anchors = [after, ...(neighbors ?? [])];
  for (const anchor of anchors) {
    // A fallback anchored to a successor inserts before it.
    const before = anchor.startsWith("<");
    const anchorId = before ? anchor.slice(1) : anchor;
    const index = items.findIndex((n) => n.id === anchorId);
    if (index !== -1) {
      items.splice(index + (before ? 0 : 1), 0, value);
      return;
    }
  }
  if (!neighbors) invalid("Neighbor does not exist in this list");
  items.push(value);
}
function applyRule(doc: Node, rule: Rule, replay: boolean) {
  const e = rule.edit;
  if (e.op === "set") {
    if (!isWordingPath(e.path) && !structuralField.test(e.path)) invalid("Unknown field " + e.path);
    if (!writeField(doc, e.path, e.value) && !replay) invalid("Field parent does not exist");
    return;
  }
  const inserting = e.op === "insert";
  if (!(inserting ? list : item).test(e.path)) invalid("Invalid item or list path " + e.path);
  const items = valueAt(doc, inserting ? e.path : parent(e.path));
  if (!Array.isArray(items)) {
    if (replay) return;
    invalid("List does not exist");
  }
  const index = items.findIndex((n) => n.id === (inserting ? e.value.id : key(e.path)));
  if (inserting) {
    if (index !== -1) {
      if (replay) return;
      invalid("An item with this ID already exists");
    }
    place(items, structuredClone(e.value), e.after, rule.neighbors);
  } else if (index === -1) {
    if (!replay) invalid("Item does not exist");
  } else {
    const [removed] = items.splice(index, 1);
    if (e.op === "move") place(items, removed, e.after, rule.neighbors);
  }
}

export function applyEdits(doc: ResumeDocument, ops: ResumeOperation[]): ResumeDocument {
  const result = structuredClone(doc);
  for (const op of ops) {
    if (op.op !== "remove" && op.op !== "set" && op.op !== "insert" && op.op !== "move")
      invalid("This action requires a company résumé");
    applyRule(result, { edit: op as Edit }, false);
  }
  return resumeDocumentSchema.parse(result);
}
function survivingNeighbors(doc: unknown, path: string, id: string | undefined | null): string[] {
  const siblings = valueAt(doc, path);
  if (!Array.isArray(siblings) || !id) return [];
  const index = siblings.findIndex((item) => item.id === id);
  if (index < 0) return [];
  const alternatives: string[] = [];
  for (let distance = 1; distance < siblings.length; distance++) {
    const previous = siblings[index - distance],
      next = siblings[index + distance];
    if (previous) alternatives.push(previous.id);
    if (next) alternatives.push("<" + next.id);
  }
  return alternatives;
}
/** All stable item IDs inside a newly inserted subtree. */
export function collectItemIds(value: unknown, ids = new Set<string>()): Set<string> {
  if (Array.isArray(value)) for (const child of value) collectItemIds(child, ids);
  else if (node(value)) {
    if (typeof value.id === "string") ids.add(value.id);
    for (const child of Object.values(value)) if (Array.isArray(child)) collectItemIds(child, ids);
  }
  return ids;
}
export function rulePath(rule: Rule): string {
  return rule.edit.op === "insert" ? rule.edit.path + "/" + rule.edit.value.id : rule.edit.path;
}
export function resolveOverlay(base: ResumeDocument, overlay: Overlay, language: string) {
  const document = structuredClone(base);
  for (const [path, recovery] of Object.entries(overlay.recoveries)) {
    const items = valueAt(document, parent(path));
    if (Array.isArray(items) && valueAt(document, path) === undefined) {
      const recovered = recovery.values[language] ?? Object.values(recovery.values)[0];
      place(items, structuredClone(recovered), recovery.neighbors[0] ?? null, recovery.neighbors);
    }
  }
  for (const rule of overlay.rules) applyRule(document, rule, true);
  for (const [path, author] of Object.entries(overlay.authored)) {
    if (!overlay.inherited?.[language]?.[path]) writeField(document, path, author.value);
  }
  for (const [path, value] of Object.entries(overlay.words[language] ?? {})) writeField(document, path, value);
  const reviewPaths = Object.entries(overlay.baseWords[language] ?? {})
    .filter(([p, val]) => (valueAt(base, p) ?? null) !== val)
    .map(([p]) => p);
  for (const rule of overlay.rules) {
    if (rule.edit.op === "set" && (valueAt(base, rule.edit.path) ?? null) !== rule.baseValue)
      reviewPaths.push(rule.edit.path);
  }
  const missingTranslationPaths = Object.entries(overlay.authored)
    .filter(
      ([p, a]) =>
        a.language !== language &&
        !overlay.inherited?.[language]?.[p] &&
        valueAt(document, p) !== undefined &&
        (!Object.hasOwn(overlay.words[language] ?? {}, p) || overlay.baselines[language]?.[p]?.sourceValue !== a.value),
    )
    .map(([p]) => p);
  return {
    document,
    reviewPaths,
    missingTranslationPaths,
    recoverablePaths: Object.keys(overlay.recoveries).filter((p) => !overlay.recoveries[p].kept),
  };
}

function removeKeys(map: Record<string, unknown>, path: string) {
  for (const p of Object.keys(map)) if (under(p, path)) delete map[p];
}
function clearScope(overlay: Overlay, path: string) {
  overlay.rules = overlay.rules.filter((r) => !under(rulePath(r), path));
  for (const map of [
    ...Object.values(overlay.words),
    ...Object.values(overlay.baseWords),
    ...Object.values(overlay.inherited ?? {}),
    ...Object.values(overlay.baselines),
  ])
    removeKeys(map, path);
  removeKeys(overlay.authored, path);
  removeKeys(overlay.recoveries, path);
}
export function editOverlay(
  base: ResumeDocument,
  overlay: Overlay,
  language: TranslationLanguage,
  ops: ResumeOperation[],
  translation = false,
) {
  const words = (overlay.words[language] ??= {});
  const baseWords = (overlay.baseWords[language] ??= {});
  function setWord(path: string, value: string | null) {
    if (translation && !overlay.authored[path]) invalid("Only company wording can be translated in a company");
    if (overlay.inherited?.[language]) delete overlay.inherited[language][path];
    words[path] = value;
    baseWords[path] = (valueAt(base, path) as string | undefined) ?? null;
    if (!translation && (!overlay.baselines[language]?.[path] || !overlay.authored[path])) {
      // Keep manual target wording available for three-way translation review.
      overlay.authored[path] = { language, value };
    }
  }
  for (const op of ops) {
    const current = resolveOverlay(base, overlay, language).document;
    if (op.op === "reset") {
      if (!wording.test(op.path) && !item.test(op.path) && !structuralField.test(op.path))
        invalid("Unknown override path");
      if (isWordingPath(op.path) && overlay.authored[op.path]?.language !== language) {
        delete words[op.path];
        delete baseWords[op.path];
        if (overlay.baselines[language]) delete overlay.baselines[language][op.path];
        if (overlay.authored[op.path]) {
          if (!valueAt(base, parent(op.path))) invalid("Company-only items have no inherited field to reset");
          ((overlay.inherited ??= {})[language] ??= {})[op.path] = true;
        }
      } else clearScope(overlay, op.path);
      continue;
    }
    if (op.op === "keep" || op.op === "discard") {
      if (!overlay.recoveries[op.path]) invalid("No recoverable subtree at " + op.path);
      if (op.op === "keep") overlay.recoveries[op.path].kept = true;
      else clearScope(overlay, op.path);
      continue;
    }
    const next = applyEdits(current, [op]);
    if (isDeepStrictEqual(next, current) && !translation) continue;
    if (op.op === "set" && isWordingPath(op.path)) {
      if (typeof op.value === "boolean") invalid("Wording must be text");
      setWord(op.path, op.value);
    } else {
      const rule: Rule = { edit: structuredClone(op as Edit) };
      if (op.op === "insert") {
        const path = op.path + "/" + op.value.id;
        const split = splitWording(next);
        // Store structural inserts once. Each wording field keeps its authoring language.
        (rule.edit as Extract<Edit, { op: "insert" }>).value = valueAt(split.structure, path) as typeof op.value;
        for (const [p, text] of Object.entries(split.words)) if (under(p, path)) setWord(p, text);
      }
      if (op.op === "move" || op.op === "insert")
        rule.neighbors = survivingNeighbors(current, op.op === "insert" ? op.path : parent(op.path), op.after);
      if (op.op === "set") rule.baseValue = valueAt(base, op.path) ?? null;
      if (op.op === "move" || op.op === "set")
        overlay.rules = overlay.rules.filter((r) => r.edit.op !== op.op || r.edit.path !== op.path);
      if (op.op === "remove") {
        clearScope(overlay, op.path);
        if (!valueAt(base, op.path)) continue;
      }
      overlay.rules.push(rule);
    }
  }
  for (const map of [overlay.words, overlay.baseWords, overlay.baselines]) {
    if (map[language] && !Object.keys(map[language]).length) delete map[language];
  }
  resumeDocumentSchema.parse(resolveOverlay(base, overlay, language).document);
}

export function captureDeleted(overlay: Overlay, path: string, bases: Record<string, ResumeDocument>) {
  const customized =
    overlay.rules.some((r) => under(rulePath(r), path) && !(r.edit.op === "remove" && r.edit.path === path)) ||
    Object.keys(overlay.authored).some((p) => under(p, path)) ||
    Object.keys(overlay.recoveries).some((p) => under(p, path));
  if (!customized) return;
  const values: Record<string, Node> = {};
  for (const [language, base] of Object.entries(bases)) {
    // Include already orphaned descendants when a subsequent deletion removes their parent.
    const recovered = resolveOverlay(base, { ...emptyOverlay(), recoveries: overlay.recoveries }, language).document;
    const subtree = valueAt(recovered, path);
    if (node(subtree)) values[language] = subtree;
  }
  if (Object.keys(values).length) {
    removeKeys(overlay.recoveries, path);
    overlay.recoveries[path] = {
      values,
      neighbors: survivingNeighbors(Object.values(bases)[0], parent(path), key(path)),
      kept: false,
    };
  }
}

/** Stable-ID changeset to reproduce a snapshot, usable for selective company creation and restore. */
export function diffResume(before: ResumeDocument, after: ResumeDocument): ResumeOperation[] {
  const operations: ResumeOperation[] = [];
  function visit(a: unknown, b: unknown, path: string) {
    if (Array.isArray(a) && Array.isArray(b)) {
      const order = a.map((x) => x.id).filter((id) => b.some((x) => x.id === id));
      for (const n of a) if (!order.includes(n.id)) operations.push({ op: "remove", path: path + "/" + n.id });
      for (const [index, n] of b.entries()) {
        const old = a.find((x) => x.id === n.id);
        const after = b[index - 1]?.id ?? null;
        if (!old) {
          operations.push({ op: "insert", path, value: n, after });
          order.splice(index, 0, n.id);
        } else {
          if (order[index] !== n.id) {
            operations.push({ op: "move", path: path + "/" + n.id, after });
            order.splice(order.indexOf(n.id), 1);
            order.splice(index, 0, n.id);
          }
          visit(old, n, path + "/" + n.id);
        }
      }
    } else if (node(a) || node(b)) {
      const l = node(a) ? a : {},
        r = node(b) ? b : {};
      for (const field of new Set([...Object.keys(l), ...Object.keys(r)]))
        visit(l[field], r[field], path + "/" + field);
    } else if (a !== b && (wording.test(path) || structuralField.test(path))) {
      operations.push({ op: "set", path, value: (b ?? null) as string | boolean | null });
    }
  }
  visit(before, after, "");
  return operations;
}
