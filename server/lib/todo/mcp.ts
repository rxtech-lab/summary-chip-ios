import { finishDocumentImageUpload } from "@/lib/services/document-images";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";
import type { Database } from "@/lib/db/client";
import type { McpPrincipal } from "@/lib/mcp/oauth-tokens";
import { securitySchemes } from "@/lib/mcp/oauth-config";
import { todoDocumentSchema, createTodoSchema } from "@/lib/contracts/todo";
import { createTodoList, getTodoList, listTodoLists, updateTodoList } from "@/lib/services/todo-lists";
import { deleteSummary } from "@/lib/services/summaries";

type Run = (name: string, action: () => Promise<{ result: CallToolResult }>) => Promise<CallToolResult>;
export function registerTodoTools(server: McpServer, context: { db: Database; principal: McpPrincipal }, run: Run) {
  const { db, principal } = context;
  const meta = (name: string, readOnlyHint = false, destructiveHint = false) => ({
    _meta: { securitySchemes: securitySchemes(name) },
    annotations: { readOnlyHint, destructiveHint, idempotentHint: readOnlyHint, openWorldHint: false },
  });
  const result = (body: unknown): { result: CallToolResult } => ({ result: { content: [{ type: "text", text: JSON.stringify(body) }] } });
  server.registerTool("finish_document_image_upload", {
    ...meta("finish_document_image_upload"), description: "After create_upload and PUT directly to its signed S3 URL, compress an owned image into WebP (max 2048px, metadata stripped). Returns a lasting capability URL for Markdown images in todo descriptions or rich documents. Anyone with that URL can read the image.",
    inputSchema: { uploadKey: z.string().min(1).max(300) },
  }, (args) => run("finish_document_image_upload", async () => result({ image: await finishDocumentImageUpload(db, principal.sub, args.uploadKey) })));
  const id = z.string().min(1).max(100);
  server.registerTool("create_todo_list", {
    ...meta("create_todo_list"),
    description: "Create a todo list chip. Give title, Markdown description (https image links supported), an ISO deadline with timezone and items with stable unique ids, title, individual deadline and completed flag. Creation by AI notifies the owner; unfinished lists and items notify at their deadlines. Private by default. Upload images with create_upload then finish_document_image_upload.",
    inputSchema: { document: todoDocumentSchema, visibility: z.enum(["private", "public"]).optional() },
  }, (args) => run("create_todo_list", async () => result({ todoList: await createTodoList(db, principal, createTodoSchema.parse(args), "agent") })));
  server.registerTool("list_todo_lists", { ...meta("list_todo_lists", true), description: "List your todo lists, deadlines and progress.", inputSchema: {} },
    () => run("list_todo_lists", async () => result(await listTodoLists(db, principal.sub))));
  server.registerTool("get_todo_list", { ...meta("get_todo_list", true), description: "Read a todo list and its revision before editing.", inputSchema: { id } },
    (args) => run("get_todo_list", async () => result({ todoList: await getTodoList(db, args.id, principal.sub) })));
  server.registerTool("update_todo_list", {
    ...meta("update_todo_list", false, true), description: "Replace a todo list using the revision from get_todo_list. Set completed to finish an item; unfinished deadlines generate alerts. Reload on revision conflict.",
    inputSchema: { id, revision: z.number().int().min(0), document: todoDocumentSchema },
  }, (args) => run("update_todo_list", async () => result({ todoList: await updateTodoList(db, principal.sub, args.id, args, "agent") })));
  server.registerTool("delete_todo_list", { ...meta("delete_todo_list", false, true), description: "Permanently delete a todo list only when requested by the user.", inputSchema: { id } },
    (args) => run("delete_todo_list", async () => {
      await getTodoList(db, args.id, principal.sub, true);
      await deleteSummary(db, principal.sub, args.id);
      return result({ deleted: true });
    }));
}
