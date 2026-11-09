import { z } from "zod";
import { VISIBILITIES } from "@/lib/db/schema";

/**
 * A rich document: blocks rendered top to bottom. Each block has a type (text, image, video, audio),
 * one or two columns, an alignment, and children (links) shown under it. Text is Markdown.
 * Spec: `docs/rich-documents.md`.
 */

export const RICH_BLOCK_TYPES = ["text", "image", "video", "audio"] as const;
export type RichBlockType = (typeof RICH_BLOCK_TYPES)[number];
export const RICH_BLOCK_ALIGNMENTS = ["leading", "center", "trailing"] as const;
export type RichBlockAlignment = (typeof RICH_BLOCK_ALIGNMENTS)[number];
export const RICH_CHILD_TYPES = ["link"] as const;

export const MAX_RICH_BLOCKS = 500;
export const MAX_RICH_COLUMNS = 2;
export const MAX_RICH_CHILDREN = 20;
/** One column's Markdown. */
export const MAX_RICH_MARKDOWN_CHARS = 50_000;
/** The whole document, serialised: a save has to fit a Vercel Function's 4.5 MB request body. */
export const MAX_RICH_DOCUMENT_CHARS = 2_000_000;
/** Markdown an agent hands over to become blocks. */
export const MAX_RICH_IMPORT_CHARS = 1_000_000;
export const MAX_RICH_OPERATIONS = 200;

export const richBlockId = z.string().trim().regex(/^[A-Za-z0-9][A-Za-z0-9_.:-]{0,119}$/, "use 1-120 letters, digits, _ . : or -");
const httpsUrl = z.string().trim().max(4096).url().refine((value) => value.startsWith("https://"), "must be an https URL");
const linkUrl = z.string().trim().max(4096).url().refine((value) => /^(https?:|mailto:)/i.test(value), "must be an http(s) or mailto URL");

/** One column of a block. Which fields it needs depends on the block's type. */
export const richColumnSchema = z.object({
  /** text: the column's Markdown (CommonMark plus GitHub tables, task lists and strikethrough). */
  markdown: z.string().max(MAX_RICH_MARKDOWN_CHARS).nullish(),
  /** image, video, audio: the media. */
  url: httpsUrl.nullish(),
  /** video: a still shown before it plays. */
  posterUrl: httpsUrl.nullish(),
  /** image: alternative text for screen readers. */
  alt: z.string().trim().max(500).nullish(),
  caption: z.string().trim().max(500).nullish(),
});
export type RichColumn = z.infer<typeof richColumnSchema>;

export const richLinkSchema = z.object({
  type: z.literal("link"),
  title: z.string().trim().min(1).max(200),
  url: linkUrl,
});
export const richChildSchema = z.discriminatedUnion("type", [richLinkSchema]);
export type RichChild = z.infer<typeof richChildSchema>;

const blockFields = {
  id: richBlockId,
  type: z.enum(RICH_BLOCK_TYPES),
  /** How the block's content sits horizontally. */
  align: z.enum(RICH_BLOCK_ALIGNMENTS).default("leading"),
  /** One column, or two side by side (stacked on narrow screens). */
  columns: z.array(richColumnSchema).min(1).max(MAX_RICH_COLUMNS),
  children: z.array(richChildSchema).max(MAX_RICH_CHILDREN).default([]),
};

/** The issues a block's columns have for its type. */
export function richBlockIssues(block: { type: RichBlockType; columns: RichColumn[] }): { path: (string | number)[]; message: string }[] {
  const issues: { path: (string | number)[]; message: string }[] = [];
  block.columns.forEach((column, index) => {
    if (block.type === "text") {
      if (!column.markdown?.trim()) issues.push({ path: ["columns", index, "markdown"], message: "a text column needs markdown" });
      if (column.url) issues.push({ path: ["columns", index, "url"], message: "a text column has no url; use an image, video or audio block" });
    } else {
      if (!column.url) issues.push({ path: ["columns", index, "url"], message: `an ${block.type} column needs a url` });
      if (column.markdown) issues.push({ path: ["columns", index, "markdown"], message: `an ${block.type} column has no markdown; use caption, or a text block` });
    }
    if (column.posterUrl && block.type !== "video") issues.push({ path: ["columns", index, "posterUrl"], message: "only a video has a posterUrl" });
  });
  return issues;
}

export const richBlockSchema = z.object(blockFields).superRefine((block, context) => {
  for (const issue of richBlockIssues(block)) context.addIssue({ code: "custom", path: issue.path, message: issue.message });
});
export type RichBlock = z.infer<typeof richBlockSchema>;

export const richDocumentSchema = z.object({
  version: z.literal(1).default(1),
  title: z.string().trim().min(1).max(200),
  description: z.string().trim().max(1200).nullish(),
  blocks: z.array(richBlockSchema).max(MAX_RICH_BLOCKS).default([]),
}).superRefine((document, context) => {
  const seen = new Set<string>();
  document.blocks.forEach((block, index) => {
    if (seen.has(block.id)) context.addIssue({ code: "custom", path: ["blocks", index, "id"], message: `"${block.id}" is used more than once` });
    seen.add(block.id);
  });
  if (JSON.stringify(document).length > MAX_RICH_DOCUMENT_CHARS) {
    context.addIssue({ code: "custom", message: `a document can be at most ${MAX_RICH_DOCUMENT_CHARS} characters of JSON` });
  }
});
export type RichDocument = z.infer<typeof richDocumentSchema>;

const markdownSource = z.string().min(1).max(MAX_RICH_IMPORT_CHARS);

/**
 * `POST /api/v1/rich-documents`: a full document, or Markdown that becomes its blocks (with `title`, or
 * the first `# heading` as the title).
 */
export const createRichDocumentSchema = z.object({
  document: richDocumentSchema.optional(),
  markdown: markdownSource.optional(),
  title: z.string().trim().min(1).max(200).optional(),
  description: z.string().trim().max(1200).nullish(),
  visibility: z.enum(VISIBILITIES).default("private"),
}).strict().superRefine((input, context) => {
  if (Boolean(input.document) === Boolean(input.markdown)) context.addIssue({ code: "custom", message: "give exactly one of document or markdown" });
});

/** Changes to named fields of a block; `id` can't change. */
const blockPatch = z.object({
  type: z.enum(RICH_BLOCK_TYPES).optional(),
  align: z.enum(RICH_BLOCK_ALIGNMENTS).optional(),
  columns: z.array(richColumnSchema).min(1).max(MAX_RICH_COLUMNS).optional(),
  children: z.array(richChildSchema).max(MAX_RICH_CHILDREN).optional(),
});

/** Where an inserted or moved block goes: after a block, or first with `after: null`. Omitted: last. */
const position = { after: richBlockId.nullish() };

export const richDocumentOperationSchema = z.discriminatedUnion("op", [
  z.object({ op: z.literal("set_meta"), title: z.string().trim().min(1).max(200).optional(), description: z.string().trim().max(1200).nullish() }),
  /** A full block: the same id replaces it in place (or moves it when `after` is given), a new id inserts it. */
  z.object({ op: z.literal("upsert_block"), block: richBlockSchema, ...position }),
  z.object({ op: z.literal("update_block"), id: richBlockId, changes: blockPatch }),
  z.object({ op: z.literal("move_block"), id: richBlockId, ...position }),
  z.object({ op: z.literal("delete_block"), id: richBlockId }),
  /** Markdown turned into blocks, inserted at the position. */
  z.object({ op: z.literal("insert_markdown"), markdown: markdownSource, ...position }),
  /** Every block replaced by the blocks of this Markdown. */
  z.object({ op: z.literal("replace_markdown"), markdown: markdownSource }),
]);
export type RichDocumentOperation = z.infer<typeof richDocumentOperationSchema>;

export const richDocumentOperationsRequestSchema = z.object({
  operations: z.array(richDocumentOperationSchema).min(1).max(MAX_RICH_OPERATIONS),
  revision: z.number().int().min(0).optional(),
}).strict();
