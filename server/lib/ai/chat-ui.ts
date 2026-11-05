import { jsonSchema, tool, type JSONSchema7 } from "ai";
import { z } from "zod";
import { viewElementSchema, viewSpecIssues, viewText } from "@/lib/contracts/trip-view";

// Share the diary's native catalog. Place needs a trip's environment, so chat views use
// self-contained components. No HTML, JavaScript, or mutation actions are accepted.
const chatSpecSchema = z.object({
  root: z.string().trim().min(1).max(80),
  elements: z.record(z.string().trim().min(1).max(80),
    z.discriminatedUnion("type", [viewElementSchema.options[0], ...viewElementSchema.options.slice(1).filter((option) => option.shape.type.value !== "Place")])),
});
const renderSchema = z.object({
  title: z.string().trim().min(1).max(200),
  currency: z.string().regex(/^[A-Z]{3}$/).default("USD"),
  spec: chatSpecSchema,
  nodeId: z.string().trim().min(1).max(200).optional().describe("Existing node ID in the current graph. Required when the user asks to show UI on top of, above, or on a node; omit to render inline in the chat message list."),
});

export const CHAT_UI_GUIDE = `
- Use renderUI when a native table, chart, comparison, statistics panel or checklist makes the answer easier to understand, or the user asks for a visual. Simple answers can stay text.
- renderUI displays UI inline in the chat message list by default. When the user asks to show UI on top of, above, or on a graph node, call renderUI with nodeId set to that existing node ID so it opens a popover anchored above the node. Resolve the node ID from the current graph; never invent it. Omit nodeId when the user wants inline chat UI. This is a temporary display and does not persist a node view. Supply title, currency (ISO 4217) and spec: {root, elements}. elements maps ids to {type, props, children?}; root names the top element. Containers Stack {direction: vertical|horizontal, gap: none|small|medium|large}, Grid {columns: 1-4}, Card {title, subtitle, tone}, Disclosure {title, expanded} reference children by id. Each id is used once, with at most 300 elements and 24 levels.
- Leaves: Heading {text, level: 1|2|3}, Text {text, tone, size, weight}, Badge {text, tone}, Stat {label, value, format, currency, detail}, Callout {title, text, tone: info|tip|warning|success}, KeyValue {items: [{label, value, format, currency}]}, List {items: [text], ordered}, Table {columns: [{key, label, align, format, currency, total}], rows: [{cells: {key: value | {value, detail, tone}}}], caption, totalLabel}, BarChart/LineChart/AreaChart {title, format, currency, items: [{label, value}]}, Divider {}, Link {title, url}, Image {url, caption, credit, aspect}, Gallery {images: [{url, caption, credit}]}.
- format is text|number|money|percent. tone is default|muted|accent|positive|negative|warning unless otherwise stated. Links must be http/https; images must be direct https URLs from sources or the user. Use only supported components and grounded facts. If validation returns an error, fix the spec and retry. Do not paste the JSON into your text answer. This tool displays a view; it does not save or change trip records.
`;

export function chatUITools() {
  // Match the trip tools' provider-compatible schema (anyOf in place of oneOf).
  const schema = JSON.parse(JSON.stringify(z.toJSONSchema(renderSchema, { io: "input" })).replaceAll('"oneOf":', '"anyOf":')) as JSONSchema7;
  delete schema.$schema;
  return {
    renderUI: tool({
      description: "Show native tables, charts, lists and cards inline in the chat message list. When the user asks to show UI on top of, above, or on a graph node, you MUST supply nodeId using that existing node ID; this opens a popover above the node. Resolve the node from the current graph before calling; never invent an ID. Omit nodeId for inline chat UI. Does not persist changes to the node. Returns validation errors for repair.",
      inputSchema: jsonSchema<{ title?: unknown; currency?: unknown; spec?: unknown; nodeId?: unknown }>(schema),
      execute: async (input) => {
        const parsed = renderSchema.safeParse(input);
        if (!parsed.success) return { error: "The view could not be rendered. Fix its fields and retry.", issues: parsed.error.issues.slice(0, 8).map((issue) => `${issue.path.join(".")}: ${issue.message}`) };
        const { spec } = parsed.data;
        const issues = viewSpecIssues(spec).map((issue) => `${issue.path.join(".")}: ${issue.message}`);
        // A valid root alone is insufficient: disconnected elements never reach
        // the native renderer, leaving an apparently successful but partial view.
        const reachable = new Set<string>();
        const pending = [spec.root];
        while (pending.length) {
          const id = pending.pop()!;
          if (reachable.has(id)) continue;
          reachable.add(id);
          const element = spec.elements[id];
          if (element && "children" in element) pending.push(...(element.children ?? []));
        }
        for (const id of Object.keys(spec.elements)) {
          if (!reachable.has(id)) issues.push(`${id}: element is not reachable from root; connect it through a container's children or remove it`);
        }
        for (const [id, element] of Object.entries(spec.elements)) {
          if (element.type === "Link" && !/^https?:\/\//i.test(element.props.url)) issues.push(`${id}: links must use http or https`);
        }
        // The native renderer cuts off at 24 levels. Reject deeper trees instead of
        // accepting a view whose content would silently disappear on the device.
        if (!issues.length) {
          const stack = [{ id: spec.root, depth: 0 }];
          while (stack.length) {
            const { id, depth } = stack.pop()!;
            if (depth >= 24) { issues.push("The view must have at most 24 levels."); break; }
            const element = spec.elements[id];
            if ("children" in element) for (const child of element.children ?? []) stack.push({ id: child, depth: depth + 1 });
          }
        }
        if (issues.length) return { error: "The view could not be rendered. Fix its structure and retry.", issues: issues.slice(0, 8) };
        return { ui: parsed.data, text: viewText(spec).join("\n").slice(0, 6000) };
      },
    }),
  };
}
