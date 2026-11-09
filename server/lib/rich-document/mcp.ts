import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";
import {
  createRichDocumentSchema,
  MAX_RICH_IMPORT_CHARS,
  MAX_RICH_OPERATIONS,
  richDocumentOperationSchema,
  richDocumentOperationsRequestSchema,
  richDocumentSchema,
} from "@/lib/contracts/rich-document";
import type { Database } from "@/lib/db/client";
import { ApiError } from "@/lib/http/errors";
import { securitySchemes } from "@/lib/mcp/oauth-config";
import type { McpPrincipal } from "@/lib/mcp/oauth-tokens";
import { createRichDocument, editRichDocument, getOwnedRichDocument, getRichDocument, listRichDocuments, type RichDocumentJson } from "@/lib/services/rich-documents";
import { deleteSummary } from "@/lib/services/summaries";
import { storeDocumentImage } from "@/lib/services/trip-images";
import type { BillingEnvironment } from "@/lib/subscription/config";
import { documentToMarkdown } from "./markdown";

/** What agents read back: the document, and the same content as Markdown. */
const payload = (document: RichDocumentJson, withMarkdown = false) => ({
  id: document.id,
  revision: document.revision,
  visibility: document.visibility,
  shareUrl: document.shareUrl,
  updatedAt: document.updatedAt,
  document: document.document,
  ...(withMarkdown ? { markdown: documentToMarkdown(document.document) } : {}),
});

export const RICH_DOCUMENT_GUIDE = "A rich document is { title, description?, blocks: [{ id, type: text|image|video|audio, align?: leading|center|trailing, columns: [column] (1 or 2, side by side), children?: [{ type: \"link\", title, url }] }] }, rendered top to bottom. "
  + "A text column is { markdown } (CommonMark plus GitHub tables, task lists and strikethrough). An image, video or audio column is { url (https), caption?, alt? (images), posterUrl? (videos) }. "
  + "Markdown conventions: a line with only ![alt](https://… \"caption\") is a media block (video or audio by file extension, else image); two such lines in a row make a two-column block; lines with only [title](url) right after media become its link children; "
  + "`::: columns` / `::: center` / `::: trailing` (combinable, e.g. `::: columns center`) opens a container, `+++` starts the second column, `:::` closes it; `#` and `##` headings start new text blocks.";

type Run = (name: string, action: () => Promise<{ result: CallToolResult }>) => Promise<CallToolResult>;

/** Rich documents over MCP: an agent creates, reads, edits and deletes block-based documents. */
export function registerRichDocumentTools(server: McpServer, context: { db: Database; principal: McpPrincipal; billingEnvironment?: BillingEnvironment }, run: Run) {
  const { db, principal } = context;
  const result = (body: Record<string, unknown>, text?: string): { result: CallToolResult } => ({
    result: { content: [...(text ? [{ type: "text" as const, text }] : []), { type: "text", text: JSON.stringify(body) }], structuredContent: body },
  });
  const meta = (name: string, title: string, read: boolean, destructive = false) => ({
    title,
    _meta: { securitySchemes: securitySchemes(name) },
    annotations: { title, readOnlyHint: read, destructiveHint: destructive, idempotentHint: false, openWorldHint: false },
  });
  const documentId = z.string().trim().min(1).max(100).describe("The document's id, from list_rich_documents.");

  server.registerTool("list_rich_documents", {
    ...meta("list_rich_documents", "List Rich Documents", true),
    description: "List the user's rich documents, most recently changed first, with their id, title, revision and block count. Open one with get_rich_document.",
    inputSchema: {},
  }, () => run("list_rich_documents", async () => {
    const { documents } = await listRichDocuments(db, principal.sub);
    return result({ count: documents.length, documents });
  }));

  server.registerTool("get_rich_document", {
    ...meta("get_rich_document", "Get Rich Document", true),
    description: "Read a rich document: its blocks (with ids to edit them by) and the same content as Markdown. Pass its revision to update_rich_document to make sure nobody changed it in between.",
    inputSchema: { documentId },
  }, (args) => run("get_rich_document", async () => result({ richDocument: payload(await getRichDocument(db, args.documentId, principal.sub), true) })));

  server.registerTool("create_rich_document", {
    ...meta("create_rich_document", "Create Rich Document", false),
    description: "Create a rich document from Markdown (preferred: give markdown, and a title unless it starts with a # heading) or from a full document of blocks. "
      + `${RICH_DOCUMENT_GUIDE} Media must be https URLs; store local images with create_upload then upload_rich_document_image after creating. Designs a cover (this can take a minute). Free.`,
    inputSchema: {
      markdown: z.string().min(1).max(MAX_RICH_IMPORT_CHARS).optional().describe("The document as Markdown; becomes its blocks."),
      title: z.string().trim().min(1).max(200).optional().describe("The title; defaults to the Markdown's first # heading."),
      description: z.string().trim().max(1200).optional().describe("A short description for the library card."),
      document: richDocumentSchema.optional().describe("A full document of blocks, instead of markdown."),
      visibility: z.enum(["public", "private"]).optional().describe("Who can open its link; private unless the user asks to share it."),
    },
  }, (args) => run("create_rich_document", async () => {
    const input = createRichDocumentSchema.parse({
      markdown: args.markdown,
      document: args.document,
      title: args.title,
      description: args.description,
      visibility: args.visibility,
    });
    const created = await createRichDocument(db, principal, input, { billingEnvironment: context.billingEnvironment, actor: "agent" });
    return result({ richDocument: payload(created) }, `Created "${created.document.title}" with ${created.document.blocks.length} blocks (${created.visibility}).\n${created.shareUrl}`);
  }));

  server.registerTool("update_rich_document", {
    ...meta("update_rich_document", "Update Rich Document", false, true),
    description: "Edit a rich document with operations applied in order, as one change: set_meta (title, description); upsert_block (a full block: the same id replaces it in place, a new id inserts it; after: a block id, or null for first, omitted for last); "
      + "update_block (id, changes: only type, align, columns or children to replace); move_block (id, after); delete_block (id); insert_markdown (markdown becomes new blocks at after); replace_markdown (every block replaced by the markdown's). "
      + `${RICH_DOCUMENT_GUIDE} Each edit saves a version. Pass revision to refuse the edit if the document changed meanwhile. Free.`,
    inputSchema: {
      documentId,
      operations: z.array(richDocumentOperationSchema).min(1).max(MAX_RICH_OPERATIONS).describe("Operations, applied in order."),
      revision: z.number().int().min(0).optional().describe("The revision the edit is based on; omit to apply to the latest."),
    },
  }, (args) => run("update_rich_document", async () => {
    const input = richDocumentOperationsRequestSchema.parse({ operations: args.operations, revision: args.revision });
    const updated = await editRichDocument(db, principal.sub, args.documentId, input, { actor: "agent" });
    return result({ richDocument: payload(updated) }, `Updated "${updated.document.title}" (revision ${updated.revision}, ${updated.document.blocks.length} blocks).`);
  }));

  server.registerTool("delete_rich_document", {
    ...meta("delete_rich_document", "Delete Rich Document", false, true),
    description: "Permanently delete one of the user's rich documents, its versions, cover and share link. Only do this when the user asks.",
    inputSchema: { documentId },
  }, (args) => run("delete_rich_document", async () => {
    const { summary } = await getOwnedRichDocument(db, args.documentId, principal.sub);
    await deleteSummary(db, principal.sub, summary.id);
    return result({ deleted: true, id: summary.id }, `Deleted "${summary.title}".`);
  }));

  server.registerTool("upload_rich_document_image", {
    ...meta("upload_rich_document_image", "Upload Rich Document Image", false),
    description: "Store an image for a rich document and return its lasting https URL, for an image column or a video's posterUrl. Give uploadKey from create_upload (PUT the bytes first) or a public url. Images are re-encoded as JPEG (max 2048 px, metadata stripped).",
    inputSchema: {
      documentId,
      uploadKey: z.string().trim().min(1).max(300).optional().describe("The key from create_upload."),
      url: z.string().trim().url().max(4096).optional().describe("A public image URL to copy."),
    },
  }, (args) => run("upload_rich_document_image", async () => {
    if (Boolean(args.uploadKey) === Boolean(args.url)) throw new ApiError(400, "INVALID_ARGUMENTS", "Give exactly one of uploadKey or url");
    const { summary } = await getOwnedRichDocument(db, args.documentId, principal.sub);
    return result({ image: await storeDocumentImage(db, principal.sub, summary.id, { uploadKey: args.uploadKey, url: args.url }) });
  }));
}
