import { z } from "zod";

// ISO instants include an offset so deadlines never depend on the server's timezone.
const deadline = z.iso.datetime({ offset: true });
/** Images and files pasted or picked into an item; URLs come from document-images or document-files. */
export const todoAttachmentSchema = z.object({
  id: z.string().trim().min(1).max(100),
  url: z.url({ protocol: /^https?$/ }).max(4096),
  name: z.string().trim().min(1).max(200),
  contentType: z.string().trim().min(1).max(200),
  size: z.number().int().min(0),
});
export const todoItemSchema = z.object({
  id: z.string().trim().min(1).max(100),
  title: z.string().trim().min(1).max(300),
  deadline,
  completed: z.boolean().default(false),
  attachments: z.array(todoAttachmentSchema).max(20).default([]),
});
export const todoDocumentSchema = z.object({
  title: z.string().trim().min(1).max(200),
  description: z.string().max(100_000).default(""),
  deadline,
  items: z.array(todoItemSchema).max(500),
}).refine((doc) => new Set(doc.items.map((item) => item.id)).size === doc.items.length, "Item ids must be unique");
export const createTodoSchema = z.object({
  document: todoDocumentSchema,
  visibility: z.enum(["private", "public"]).default("private"),
});
export const updateTodoSchema = z.object({ document: todoDocumentSchema, revision: z.number().int().min(0) });
export type TodoDocument = z.infer<typeof todoDocumentSchema>;
