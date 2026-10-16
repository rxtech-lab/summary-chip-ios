import { boundedMiniJson } from "@/lib/mini-app/bounds";
import { z } from "zod";
import { viewElementSchema, VIEW_ELEMENT_TYPES } from "./trip-view";

export type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
export const jsonValue: z.ZodType<Json> = z.lazy(() => z.union([z.null(), z.boolean(), z.number().finite(), z.string().max(100_000), z.array(jsonValue).max(1000), z.record(z.string().max(100), jsonValue)]));
export const miniId = z.string().regex(/^[A-Za-z][A-Za-z0-9_-]{0,79}$/).refine(v => !["__proto__", "prototype", "constructor"].includes(v));
const fields = z.record(miniId, z.object({ type: z.enum(["string", "number", "boolean", "date", "json"]), required: z.boolean().default(false) }).strict());
export const MINI_COMPONENTS = [...VIEW_ELEMENT_TYPES.filter(v => v !== "Place"), "Navigation", "Tabs", "Tab", "Toolbar", "Menu", "Form", "Section", "Button", "TextField", "TextEditor", "Toggle", "Picker", "DatePicker", "FilePicker", "Location", "Map", "Progress", "Empty", "Sheet", "Dialog", "Alert", "Confirmation"] as const;
export const MINI_EXPORT_FORMATS = ["text", "csv", "json"] as const;
export const MINI_EVENTS = ["press", "change", "submit", "load", "refresh", "search"] as const;
export const miniNodeSchema = z.object({
  type: z.enum(MINI_COMPONENTS), props: z.record(z.string().max(80), jsonValue).default({}),
  children: z.array(miniId).max(100).default([]), visible: jsonValue.optional(),
  repeat: z.object({ items: jsonValue }).strict().optional(),
  events: z.partialRecord(z.enum(MINI_EVENTS), miniId).default({}),
}).strict();
export const miniTableSchema = z.object({ scope: z.enum(["personal", "shared"]), fields }).strict();
export const miniQuerySchema = z.object({
  table: miniId,
  filters: z.array(z.object({ field: miniId, op: z.enum(["eq", "ne", "gt", "gte", "lt", "lte", "contains"]), value: jsonValue }).strict()).max(10).default([]),
  sort: z.object({ field: miniId, direction: z.enum(["asc", "desc"]).default("asc") }).strict().optional(),
  limit: z.number().int().min(1).max(100).default(50),
}).strict();
export type MiniStep =
  | { type: "set"; path: string; value: Json }
  | { type: "query"; query: string; into: string; cursor?: Json }
  | { type: "mutate"; table: string; operation: "create" | "update" | "delete"; recordId?: Json; revision?: Json; value?: Json }
  | { type: "request"; connector: string; operation: string; input: Json; into: string }
  | { type: "script"; script: string; input: Json; into: string }
  | { type: "if"; condition: Json; then: MiniStep[]; else?: MiniStep[] }
  | { type: "present"; target: string }
  | { type: "dismiss" }
  | { type: "export"; filename: Json; format?: "text" | "csv" | "json"; content: Json }
  | { type: "download"; url: Json; filename?: Json };
const statePath = z.string().regex(/^[A-Za-z][A-Za-z0-9_.-]{0,199}$/).refine(v => v.split(".").every(p => !["__proto__", "prototype", "constructor"].includes(p)));
export const miniStepSchema: z.ZodType<MiniStep> = z.lazy(() => z.discriminatedUnion("type", [
  z.object({ type: z.literal("set"), path: statePath, value: jsonValue }).strict(),
  z.object({ type: z.literal("query"), query: miniId, into: statePath, cursor: jsonValue.optional() }).strict(),
  z.object({ type: z.literal("mutate"), table: miniId, operation: z.enum(["create", "update", "delete"]), recordId: jsonValue.optional(), revision: jsonValue.optional(), value: jsonValue.optional() }).strict(),
  z.object({ type: z.literal("request"), connector: miniId, operation: miniId, input: jsonValue, into: statePath }).strict(),
  z.object({ type: z.literal("script"), script: miniId, input: jsonValue, into: statePath }).strict(),
  z.object({ type: z.literal("if"), condition: jsonValue, then: z.array(miniStepSchema).max(50), else: z.array(miniStepSchema).max(50).optional() }).strict(),
  z.object({ type: z.literal("present"), target: miniId }).strict(), z.object({ type: z.literal("dismiss") }).strict(),
  // Files the user saves with the native Save dialog: built from state, or fetched from an HTTPS URL by the device.
  z.object({ type: z.literal("export"), filename: jsonValue, format: z.enum(MINI_EXPORT_FORMATS).optional(), content: jsonValue }).strict(),
  z.object({ type: z.literal("download"), url: jsonValue, filename: jsonValue.optional() }).strict(),
]));
const https = z.string().url().max(2048).refine(v => { const u = new URL(v); return u.protocol === "https:" && !u.username && !u.password && !u.hash; }, "Use an HTTPS URL without credentials or fragment");
export const miniConnectorSchema = z.object({
  title: z.string().min(1).max(200), origin: https.refine(v => new URL(v).origin === v, "Use the exact HTTPS origin"),
  auth: z.discriminatedUnion("type", [
    // Public APIs that need no credential (still brokered: HTTPS, SSRF and size checks apply).
    z.object({ type: z.literal("none") }).strict(),
    z.object({ type: z.literal("apiKey"), header: z.string().regex(/^[A-Za-z][A-Za-z0-9-]{0,79}$/).refine(v => !["host", "cookie", "content-length", "content-type", "accept", "connection", "transfer-encoding", "proxy-authorization", "proxy-connection", "te", "trailer", "upgrade", "expect", "forwarded", "x-forwarded-for", "x-forwarded-host", "x-forwarded-proto"].includes(v.toLowerCase())), prefix: z.string().max(30).regex(/^[^\r\n]*$/).default("") }).strict(),
    z.object({ type: z.literal("oauth2"), authorizationUrl: https, tokenUrl: https, revocationUrl: https.optional(), clientId: z.string().min(1).max(500), scopes: z.array(z.string().regex(/^[\x21\x23-\x5b\x5d-\x7e]+$/).max(200)).max(30).default([]) }).strict(),
  ]),
  operations: z.record(miniId, z.object({
    method: z.enum(["GET", "POST", "PUT", "PATCH", "DELETE"]),
    path: z.string().regex(/^\/(?!\/)[^?#\\]*$/).max(1000).refine(v => !v.split("/").includes("..")),
    input: fields.default({}),
  }).strict()),
}).strict();
export const miniAppDocumentSchema = z.object({
  schemaVersion: z.literal(1), title: z.string().trim().min(1).max(200), description: z.string().max(1200).default(""),
  ui: z.object({ root: miniId, elements: z.record(miniId, miniNodeSchema) }).strict(),
  initialState: z.record(miniId, jsonValue).default({}), tables: z.record(miniId, miniTableSchema).default({}),
  queries: z.record(miniId, miniQuerySchema).default({}),
  actions: z.record(miniId, z.object({ trigger: z.enum(["read", "interaction"]), input: fields.default({}), steps: z.array(miniStepSchema).max(50) }).strict()).default({}),
  scripts: z.record(miniId, z.string().min(1).max(50_000)).default({}), connectors: z.record(miniId, miniConnectorSchema).default({}),
  fixtures: z.object({ records: z.record(miniId, z.array(z.record(miniId, jsonValue)).max(100)).default({}), responses: z.record(miniId, jsonValue).default({}), tests: z.array(z.object({ action: miniId, input: z.record(miniId, jsonValue).default({}), state: z.record(miniId, jsonValue).default({}), expectState: z.record(miniId, jsonValue) }).strict()).max(10).default([]) }).strict().default({ records: {}, responses: {}, tests: [] }),
}).strict();
export type MiniAppDocument = z.infer<typeof miniAppDocumentSchema>;
export type MiniQuery = z.infer<typeof miniQuerySchema>;
export type MiniConnector = z.infer<typeof miniConnectorSchema>;
export type MiniNode = z.infer<typeof miniNodeSchema>;
export const miniAppInputSchema = z.unknown().refine(boundedMiniJson, "Document is too large or deeply nested").pipe(miniAppDocumentSchema);
export const saveMiniAppSchema = z.object({ document: miniAppInputSchema, revision: z.number().int().nonnegative() }).strict();
export const miniRunSchema = z.object({ revision: z.number().int().nonnegative(), action: miniId, key: z.string().uuid(), input: z.record(miniId, jsonValue).default({}), state: z.record(miniId, jsonValue).default({}), item: jsonValue.optional() }).strict();
export type MiniRun = z.infer<typeof miniRunSchema>;

export function miniDocumentIssues(doc: MiniAppDocument): string[] {
  const issues: string[] = [];
  const add = (s: string) => { if (issues.length < 30) issues.push(s); };
  if (Buffer.byteLength(JSON.stringify(doc)) > 1024 * 1024) add("Document exceeds 1 MiB");
  if (Object.keys(doc.ui.elements).length > 300) add("At most 300 UI elements");
  for (const name of ["tables", "queries", "actions", "scripts", "connectors"] as const) if (Object.keys(doc[name]).length > 50) add(`At most 50 ${name}`);
  const expressionOps = new Set(["eq", "ne", "gt", "gte", "lt", "lte", "and", "or", "not", "add", "sub", "mul", "div", "concat", "length", "coalesce", "contains"]);
  const expression = (value: Json, location: string, depth = 0) => {
    if (depth > 24) { add(`${location}: expression is too deep`); return; }
    if (!value || typeof value !== "object") return;
    if (Array.isArray(value)) { for (const entry of value) expression(entry, location, depth + 1); return; }
    if (Object.keys(value).length === 1 && "get" in value && (typeof value.get !== "string" || !/^(state|input|item)(\.[A-Za-z0-9_-]+)*$/.test(value.get))) add(`${location}: invalid state/input/item reference`);
    if ("op" in value && "args" in value && (typeof value.op !== "string" || !expressionOps.has(value.op) || !Array.isArray(value.args))) add(`${location}: unsupported expression operation`);
    for (const child of Object.values(value)) expression(child, location, depth + 1);
  };
  for (const [id, node] of Object.entries(doc.ui.elements)) {
    for (const value of Object.values(node.props)) expression(value, id);
    if (node.visible !== undefined) expression(node.visible, id);
    if (node.repeat) expression(node.repeat.items, id);
  }
  const visiting = new Set<string>(); const heights = new Map<string, number>(); const sizes = new Map<string, number>();
  const visit = (id: string): number => {
    if (visiting.has(id)) { add(`${id}: cyclic UI`); return 24; }
    if (heights.has(id)) return heights.get(id)!;
    const node = doc.ui.elements[id];
    if (!node) { add(`${id}: missing element`); return 0; }
    visiting.add(id);
    for (const [event, action] of Object.entries(node.events)) {
      if (!action || !doc.actions[action]) add(`${id}.${event}: missing action ${action}`);
      else if (["load", "refresh", "search", "change"].includes(event) && doc.actions[action].trigger !== "read") add(`${id}.${event}: requires a read action`);
    }
    const height = 1 + Math.max(0, ...node.children.map(visit));
    if (height > 24) add(`${id}: excessively deep UI`);
    const size = Math.min(5001, (1 + node.children.reduce((n, child) => n + (sizes.get(child) ?? 0), 0)) * (node.repeat ? 100 : 1));
    if (size > 5000) add(`${id}: expanded UI exceeds 5000 nodes`);
    sizes.set(id, size);
    const binding = node.props.binding;
    if (binding !== undefined && !statePath.safeParse(binding).success) add(`${id}: binding must be a safe state path`);
    visiting.delete(id); heights.set(id, height); return height;
  };
  visit(doc.ui.root);
  for (const id of Object.keys(doc.ui.elements)) visit(id);
  for (const [id, query] of Object.entries(doc.queries)) {
    for (const filter of query.filters) expression(filter.value, `queries.${id}`);
    const table = doc.tables[query.table];
    if (!table) add(`${id}: missing table ${query.table}`);
    else for (const field of [...query.filters.map(f => f.field), ...(query.sort ? [query.sort.field] : [])]) if (!table.fields[field]) add(`${id}: unknown field ${field}`);
  }
  const steps = (list: MiniStep[], read: boolean, depth: number) => {
    if (depth > 12) { add("Actions nest too deeply"); return; }
    for (const step of list) {
      for (const key of ["value", "condition", "input", "recordId", "revision", "cursor", "filename", "content", "url"] as const) if (key in step) expression((step as unknown as Record<string, Json>)[key], `action.${step.type}.${key}`);
      if (step.type === "if") { steps(step.then, read, depth + 1); steps(step.else ?? [], read, depth + 1); }
      if (step.type === "query" && !doc.queries[step.query]) add(`Missing query ${step.query}`);
      if (step.type === "mutate" && (!doc.tables[step.table] || read)) add(`Mutation ${step.table} requires an existing table and interaction action`);
      if (step.type === "request") {
        const op = doc.connectors[step.connector]?.operations[step.operation];
        if (!op || (read && op.method !== "GET")) add(`Request ${step.connector}.${step.operation} is unavailable or writes in a read action`);
      }
      if (step.type === "script" && !doc.scripts[step.script]) add(`Missing script ${step.script}`);
      if (step.type === "present" && !doc.ui.elements[step.target]) add(`Missing presentation ${step.target}`);
      // A Save dialog never opens from loading, searching or refreshing.
      if ((step.type === "export" || step.type === "download") && read) add(`File ${step.type} requires an interaction action`);
      if (step.type === "download" && typeof step.url === "string" && !miniDownloadUrl(step.url)) add("Download url must be an HTTPS URL without credentials");
    }
  };
  for (const action of Object.values(doc.actions)) steps(action.steps, action.trigger === "read", 0);
  for (const [key, records] of Object.entries(doc.fixtures.records)) {
    if (!doc.tables[key]) { add(`fixtures.${key}: missing table`); continue; }
    for (const record of records) try { validateFields(record, doc.tables[key].fields); } catch { add(`fixtures.${key}: invalid record fields`); }
  }
  for (const fixture of doc.fixtures.tests) if (!doc.actions[fixture.action]) add(`Fixture references missing action ${fixture.action}`);
  return issues;
}

/** The URL a `download` step may hand to the device: HTTPS, no embedded credentials. */
export function miniDownloadUrl(value: Json): value is string {
  if (typeof value !== "string" || value.length > 2048 || !URL.canParse(value)) return false;
  const url = new URL(value);
  return url.protocol === "https:" && !url.username && !url.password;
}

export function validateFields(value: unknown, schema: z.infer<typeof fields>): Record<string, Json> {
  const shape = Object.fromEntries(Object.entries(schema).map(([key, field]) => {
    let type: z.ZodType = field.type === "json" ? jsonValue : field.type === "number" ? z.number().finite() : field.type === "boolean" ? z.boolean() : field.type === "date" ? z.union([z.iso.date(), z.iso.datetime({ offset: true })]) : z.string().max(100_000);
    if (!field.required) type = type.nullish();
    return [key, type];
  }));
  return z.object(shape).strict().parse(value) as Record<string, Json>;
}

export const miniAppExample = miniAppDocumentSchema.parse({
  schemaVersion: 1, title: "Personal Tracker", description: "A private list with a native creation sheet.",
  initialState: { title: "", search: "", records: [] },
  tables: { tasks: { scope: "personal", fields: { title: { type: "string", required: true } } } },
  queries: { tasks: { table: "tasks", filters: [{ field: "title", op: "contains", value: { op: "coalesce", args: [{ get: "state.search" }, ""] } }] } },
  actions: {
    load: { trigger: "read", steps: [{ type: "query", query: "tasks", into: "records" }] },
    open: { trigger: "read", steps: [{ type: "present", target: "editor" }] },
    save: { trigger: "interaction", steps: [{ type: "mutate", table: "tasks", operation: "create", value: { title: { get: "state.title" } } }, { type: "query", query: "tasks", into: "records" }, { type: "set", path: "title", value: "" }, { type: "dismiss" }] },
  },
  ui: { root: "root", elements: {
    root: { type: "Navigation", props: { title: "Personal Tracker", searchable: true }, events: { load: "load", refresh: "load", search: "load" }, children: ["add", "rows"] },
    add: { type: "Button", props: { title: "Add Task", icon: "plus" }, events: { press: "open" } },
    rows: { type: "Text", props: { text: { get: "item.data.title" } }, repeat: { items: { get: "state.records.items" } } },
    editor: { type: "Sheet", props: { title: "Add Task" }, children: ["field", "save"] },
    field: { type: "TextField", props: { title: "Title", binding: "title", required: true } },
    save: { type: "Button", props: { title: "Save", icon: "checkmark" }, events: { press: "save" } },
  } },
});

export function miniAppCatalog() {
  return { schemaVersion: 1, components: MINI_COMPONENTS, events: MINI_EVENTS, legacyComponents: z.toJSONSchema(viewElementSchema),
    documentSchema: z.toJSONSchema(miniAppDocumentSchema),
    expressions: { reference: { get: "state.path | input.path | item.path" }, operation: { op: "eq|ne|gt|gte|lt|lte|and|or|not|add|sub|mul|div|concat|length|coalesce|contains", args: [] } },
    script: "Function body with input available; return JSON. No imports, network or host APIs.",
    connectors: "auth.type none for public APIs that need no key (works without setup); apiKey or oauth2 when the user must connect an account in Chippy",
    nativeProps: {
      Navigation: "title, searchable; load/refresh/search/submit events; search text lives at state.search (search fires while typing, submit on Return); Toolbar children become native toolbar items. A present step targeting a non-root Navigation pushes it as a page (its item is the row that triggered it), so pages stack: list → detail → sub-detail, each with a native Back button; inside a Sheet it pushes within the sheet. dismiss closes the topmost layer only: an Alert/Dialog, then a page pushed in the Sheet, then the Sheet, then the top pushed page",
      Tabs: "a native tab bar; use as the root (or a Navigation's sole content) to split an app into screens. Tab children plus optional Toolbar children shared by every tab; binding (state path holding the selected Tab id), searchable (one search field for all tabs, as Navigation); change fires on tab switch",
      Tab: "title, icon (SF Symbol), badge expression; content children, its own Toolbar children (shown while selected); refresh event",
      Toolbar: "Button/Menu/Location children shown as native toolbar items; placement primary (default) | secondary | leading | bottom. Prefer toolbar actions over buttons in the content", Menu: "title, icon; Button children",
      Form: "Section and input children; use as sole content of a Navigation or Sheet", Section: "title",
      Button: "title, icon, disabled expression, role (destructive); press event",
      TextField: "title, binding (state path), required, format (number); change/submit events",
      TextEditor: "title, binding, required; change event", Toggle: "title, binding; change event",
      Picker: "title, binding, options [{label,value}]; change event", DatePicker: "title, binding (ISO date string); change event",
      Sheet: "title, height (\"half\" opens at half height and can be dragged to full; default full); content children; present opens a native sheet", Dialog: "title, message; Button children",
      Alert: "title, message; Button children", Confirmation: "title, message; Button children; destructive roles supported",
      FilePicker: "title, icon, binding (state path), accept (image | file | any, default any: a menu of Photos and Files), multiple (bool). A button that lets the user pick a photo or local file, uploads it and writes a file reference {id, url, name, contentType, size, width?, height?} to binding (an array of them with multiple), then fires change (a read action). Images are re-encoded as JPEG without location metadata; show them with an Image element whose url is {get: \"state.<binding>.url\"}. Store references in a json table field with an interaction action (mutate). In an unsaved preview the picked file stays on the device",
      Location: "title, icon, binding (state path), auto (bool); a button that asks for the device's when-in-use location and writes {latitude, longitude, accuracy} to binding, then fires change (a read action). With auto it fills in on load when access was already granted; it never prompts on its own",
      Map: "latitude, longitude, span (meters shown around the center, default 5000), markers [{id, latitude, longitude, title, icon (SF Symbol), tone (accent|positive|negative|warning)}], height (points, 120-600, default 260), interactive (default true), binding (state path receiving the selected marker id); change fires on marker selection (a read action, e.g. present a half-height Sheet). Without a center the map fits its markers",
      Progress: "title", Empty: "title, icon, message",
      export: "action step {type:\"export\", filename, format: text (default) | csv | json, content}; opens the native Save dialog with a file built from the evaluated content. csv takes an array of rows: arrays keep their column order, objects use their keys (sorted) as the header. Interaction actions only",
      download: "action step {type:\"download\", url, filename?}; the device downloads the HTTPS file (25 MiB max) and opens the native Save dialog. The filename defaults to the server's suggestion. Interaction actions only",
      all: "visible expression, repeat.items expression (each row becomes item), props expressions; form bindings are literal state paths",
    },
    examples: [miniAppExample], limits: { elements: 300, depth: 24, steps: 50, scriptMemoryMiB: 32 },
  };
}
