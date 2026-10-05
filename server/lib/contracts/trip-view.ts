import { z } from "zod";

/**
 * Custom trip views: small UIs (comparison tables, budgets, checklists…) described as JSON and
 * rendered natively by the apps, in the spirit of Vercel's json-render. A view is a flat map of
 * elements keyed by id plus the id of its root; containers list their children by id. Every
 * element's `type` comes from the fixed catalog below, so agents can only compose components the
 * clients know how to draw. Swift renderer: `summary-chip/Trip/TripCustomView.swift`. Spec: `docs/trips.md`.
 */

const elementId = z.string().trim().min(1).max(80);
const label = z.string().trim().max(300);
const text = z.string().trim().max(4000);

export const VIEW_TONES = ["default", "muted", "accent", "positive", "negative", "warning"] as const;
export const VIEW_FORMATS = ["text", "number", "money", "percent"] as const;

const tone = z.enum(VIEW_TONES).nullish();
const format = z.enum(VIEW_FORMATS).nullish();
/** ISO 4217 for `money` values; the trip's currency when absent. */
const currency = z.string().trim().regex(/^[A-Z]{3}$/, "must be an ISO 4217 code").nullish();
/** A displayed value: text as is, numbers formatted by the surrounding `format`. */
const value = z.union([z.string().trim().max(300), z.number(), z.null()]);

/** A table cell: a bare value, or a value with a line of detail under it and its own tone. */
const cell = z.union([value, z.object({ value, detail: label.nullish(), tone })]);

const tableColumn = z.object({
  key: elementId,
  label: label.min(1),
  align: z.enum(["leading", "center", "trailing"]).nullish(),
  format,
  currency,
  /** Adds a total row summing the column's numeric cells (rows with `style: "total"` are not counted). */
  total: z.boolean().nullish(),
});

const tableRow = z.object({
  cells: z.record(elementId, cell),
  style: z.enum(["default", "muted", "emphasis", "total"]).nullish(),
});

// `props` may be omitted when none are required: `prefault` still validates the empty object.
const withoutChildren = <K extends string, T extends z.ZodRawShape>(type: K, props: T) =>
  z.object({ type: z.literal(type), props: z.object(props).prefault({} as never), children: z.array(elementId).max(0, "only Stack, Grid, Card and Disclosure have children").optional() });

const withChildren = <K extends string, T extends z.ZodRawShape>(type: K, props: T) =>
  z.object({ type: z.literal(type), props: z.object(props).prefault({} as never), children: z.array(elementId).max(50).default([]) });

/** The component catalog. Containers: Stack, Grid, Card, Disclosure. Everything else is a leaf. */
export const viewElementSchema = z.discriminatedUnion("type", [
  withChildren("Stack", {
    direction: z.enum(["vertical", "horizontal"]).nullish(),
    gap: z.enum(["none", "small", "medium", "large"]).nullish(),
  }),
  withChildren("Grid", { columns: z.number().int().min(1).max(4).nullish() }),
  withChildren("Card", { title: label.nullish(), subtitle: label.nullish(), tone }),
  /** Collapsed content with a title, like `<details>`. */
  withChildren("Disclosure", { title: label.min(1), expanded: z.boolean().nullish() }),
  withoutChildren("Heading", { text: label.min(1), level: z.union([z.literal(1), z.literal(2), z.literal(3)]).nullish() }),
  withoutChildren("Text", {
    text: text.min(1),
    tone,
    size: z.enum(["small", "body", "large"]).nullish(),
    weight: z.enum(["regular", "semibold", "bold"]).nullish(),
  }),
  withoutChildren("Badge", { text: label.min(1), tone }),
  /** A big number with a label: a total, a saving. */
  withoutChildren("Stat", { label: label.min(1), value, format, currency, detail: label.nullish(), tone }),
  withoutChildren("Callout", { title: label.nullish(), text: text.min(1), tone: z.enum(["info", "tip", "warning", "success"]).nullish() }),
  withoutChildren("KeyValue", {
    items: z.array(z.object({ label: label.min(1), value, format, currency, tone })).max(50),
  }),
  withoutChildren("List", { items: z.array(text.min(1)).max(50), ordered: z.boolean().nullish() }),
  withoutChildren("Table", {
    caption: label.nullish(),
    columns: z.array(tableColumn).min(1).max(8),
    rows: z.array(tableRow).max(100),
    totalLabel: label.nullish(),
  }),
  /** Horizontal bars comparing a few values (e.g. pass vs pay-as-you-go). */
  withoutChildren("BarChart", {
    title: label.nullish(),
    format,
    currency,
    items: z.array(z.object({ label: label.min(1), value: z.number(), detail: label.nullish(), tone })).min(1).max(20),
  }),
  withoutChildren("Divider", {}),
  withoutChildren("Link", { title: label.min(1), url: z.string().trim().url().max(4096) }),
]);
export type ViewElement = z.infer<typeof viewElementSchema>;

export const VIEW_ELEMENT_TYPES = viewElementSchema.options.map((option) => option.shape.type.value);
export const VIEW_CONTAINER_TYPES = ["Stack", "Grid", "Card", "Disclosure"] as const;

export const MAX_VIEW_ELEMENTS = 300;

export const viewSpecSchema = z.object({
  root: elementId,
  elements: z.record(elementId, viewElementSchema),
});
export type ViewSpec = z.infer<typeof viewSpecSchema>;

/** Problems with a spec's tree: a missing root or child, an element used twice, too many elements. */
export function viewSpecIssues(spec: ViewSpec): { path: (string | number)[]; message: string }[] {
  const issues: { path: (string | number)[]; message: string }[] = [];
  const ids = Object.keys(spec.elements);
  if (ids.length > MAX_VIEW_ELEMENTS) issues.push({ path: ["elements"], message: `at most ${MAX_VIEW_ELEMENTS} elements` });
  if (!spec.elements[spec.root]) {
    issues.push({ path: ["root"], message: `unknown element "${spec.root}"` });
    return issues;
  }
  // Walk the tree from the root: every child must exist and appear once, which also rules out cycles.
  const seen = new Set<string>([spec.root]);
  const stack = [spec.root];
  while (stack.length) {
    const parent = stack.pop()!;
    const element = spec.elements[parent];
    (("children" in element ? element.children : undefined) ?? []).forEach((child, index) => {
      if (!spec.elements[child]) issues.push({ path: ["elements", parent, "children", index], message: `unknown element "${child}"` });
      else if (seen.has(child)) issues.push({ path: ["elements", parent, "children", index], message: `element "${child}" is used more than once` });
      else {
        seen.add(child);
        stack.push(child);
      }
    });
  }
  return issues;
}

/** The readable text in a view, for search and for the agent's plain-text picture of the trip. */
export function viewText(spec: ViewSpec): string[] {
  const lines: string[] = [];
  const show = (v: unknown) => (v === null || v === undefined ? "" : String(v));
  const visit = (id: string, depth: number) => {
    const element = spec.elements[id];
    if (!element || depth > 40) return;
    switch (element.type) {
      case "Card": case "Disclosure":
        if (element.props.title) lines.push(element.props.title);
        break;
      case "Heading": case "Text": case "Badge":
        lines.push(element.props.text);
        break;
      case "Callout":
        lines.push([element.props.title, element.props.text].filter(Boolean).join(": "));
        break;
      case "Stat":
        lines.push(`${element.props.label}: ${show(element.props.value)}`);
        break;
      case "KeyValue":
        for (const item of element.props.items) lines.push(`${item.label}: ${show(item.value)}`);
        break;
      case "List":
        lines.push(...element.props.items.map((item) => `- ${item}`));
        break;
      case "Table":
        if (element.props.caption) lines.push(element.props.caption);
        lines.push(element.props.columns.map((column) => column.label).join(" | "));
        for (const row of element.props.rows) {
          lines.push(element.props.columns.map((column) => {
            const c = row.cells[column.key];
            return c !== null && typeof c === "object" ? show(c.value) : show(c);
          }).join(" | "));
        }
        break;
      case "BarChart":
        if (element.props.title) lines.push(element.props.title);
        for (const item of element.props.items) lines.push(`${item.label}: ${item.value}`);
        break;
      default:
        break;
    }
    if ("children" in element) for (const child of element.children ?? []) visit(child, depth + 1);
  };
  visit(spec.root, 0);
  return lines;
}
