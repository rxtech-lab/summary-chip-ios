import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import type { Database } from "@/lib/db/client";
import { securitySchemes } from "@/lib/mcp/oauth-config";
import { jsonValue, miniAppInputSchema, miniAppCatalog, miniId, validateFields, type MiniAppDocument } from "@/lib/contracts/mini-app";
import { ApiError } from "@/lib/http/errors";
import { regenerateImage } from "@/lib/services/summaries";
import { addMiniRecords, createMiniApp, getMiniApp, listMiniApps, MINI_SEED_MAX_RECORDS, miniAccess, miniEnabled, queryMiniRecords, updateMiniApp } from "./service";
import { attachMiniAppFile, attachMiniFileSchema } from "./files";
import { validateMiniApp } from "./validation";

const recordData = z.record(miniId, jsonValue);
const seedRecords = z.record(miniId, z.array(recordData).max(MINI_SEED_MAX_RECORDS)).optional()
  .describe("Initial data: table id → records (field → value, as declared in tables), at most 100 per table. Personal tables are filled for you only; shared tables for everyone with access. Files go in json fields as references from upload_mini_app_file.");

/** Checks seed records against the document's tables before the app is saved, so a bad record saves nothing. */
function checkSeed(document: MiniAppDocument, records: Record<string, Record<string, unknown>[]> = {}) {
  for (const [table, rows] of Object.entries(records)) {
    const schema = document.tables[table];
    if (!schema) throw new ApiError(422, "MINI_RECORD_INVALID", `records.${table}: the document has no table ${table}`);
    rows.forEach((row, index) => {
      try { validateFields(row, schema.fields); } catch { throw new ApiError(422, "MINI_RECORD_INVALID", `records.${table}.${index} does not match the table's fields`, { fields: schema.fields }); }
    });
  }
}

export function registerMiniAppTools(server: McpServer, db: Database, userId: string, run: (name: string, fn: () => Promise<{ result: CallToolResult }>) => Promise<CallToolResult>) {
  const result = (payload: object): { result: CallToolResult } => ({ result: { content: [{ type: "text", text: JSON.stringify(payload) }], structuredContent: payload as Record<string, unknown> } });
  const meta = (name: string, read: boolean) => ({ _meta: { securitySchemes: securitySchemes(name) }, annotations: { readOnlyHint: read, destructiveHint: false, openWorldHint: false } });
  server.registerTool("get_mini_app_catalog", { title: "Mini App Catalog", description: "Read the native component catalog, JSON expression/action schemas, script contract and example before creating a Mini App. Secrets are configured by the user in Chippy, never in documents.", inputSchema: {}, ...meta("get_mini_app_catalog", true) }, () => run("get_mini_app_catalog", async () => { miniEnabled(); return result(miniAppCatalog()); }));
  server.registerTool("validate_mini_app", { title: "Validate Mini App", description: "Validate a Mini App definition and JavaScript syntax and isolated fixture behavior without saving or accessing live data or connections. Returns field diagnostics to repair.", inputSchema: { document: miniAppInputSchema }, ...meta("validate_mini_app", true) }, args => run("validate_mini_app", async () => { miniEnabled(); return result(await validateMiniApp(args.document)); }));
  server.registerTool("create_mini_app", { title: "Create Mini App", description: "Save a new private interactive Mini App in Chippy. First get_mini_app_catalog, then provide a validated document. Pass records to start its tables with initial data. Creates version 1 and an AI-illustrated cover (this can take a minute). Declared connectors remain disconnected until the user authorizes them in Chippy.", inputSchema: { document: miniAppInputSchema, records: seedRecords }, ...meta("create_mini_app", false) }, args => run("create_mini_app", async () => {
    miniEnabled(); checkSeed(args.document, args.records);
    const app = await createMiniApp(db, userId, args.document, "agent", { cover: true });
    const seeded: Record<string, number> = {};
    for (const [table, rows] of Object.entries(args.records ?? {})) seeded[table] = (await addMiniRecords(db, app.id, userId, table, rows)).count;
    return result({ app, records: seeded, validation: { ok: true, issues: [] }, connectionSetup: Object.entries(app.document.connectors).filter(([, c]) => c.auth.type !== "none").map(([key]) => key) });
  }));
  server.registerTool("get_mini_app", { title: "Get Mini App", description: "Read a Mini App definition and revision. Never returns live private records or credentials.", inputSchema: { appId: z.string().uuid() }, ...meta("get_mini_app", true) }, args => run("get_mini_app", async () => { miniEnabled(); return result({ app: await getMiniApp(db, args.appId, userId) }); }));
  server.registerTool("list_mini_apps", { title: "List Mini Apps", description: "List up to ten owned Mini Apps. Pass nextCursor back as cursor.", inputSchema: { cursor: z.string().uuid().optional() }, ...meta("list_mini_apps", true) }, args => run("list_mini_apps", async () => { miniEnabled(); return result(await listMiniApps(db, userId, args.cursor)); }));
  server.registerTool("update_mini_app", { title: "Update Mini App", description: "Replace an owned Mini App definition using the revision from get_mini_app. Validates and saves an agent-authored version. Live records and credentials are preserved; incompatible populated table changes are refused.", inputSchema: { appId: z.string().uuid(), revision: z.number().int().nonnegative(), document: miniAppInputSchema }, ...meta("update_mini_app", false) }, args => run("update_mini_app", async () => { miniEnabled(); const app = await updateMiniApp(db, args.appId, userId, args.document, args.revision, "agent"); return result({ app, validation: { ok: true, issues: [] }, connectionSetup: Object.entries(app.document.connectors).filter(([, c]) => c.auth.type !== "none").map(([key]) => key) }); }));
  server.registerTool("regenerate_mini_app_cover", { title: "Regenerate Mini App Cover", description: "Draw a new AI-illustrated cover for an owned Mini App's library card. Apps without a designed cover also get a new theme from their current definition. Can take a minute.", inputSchema: { appId: z.string().uuid() }, ...meta("regenerate_mini_app_cover", false) }, args => run("regenerate_mini_app_cover", async () => { miniEnabled(); await miniAccess(db, args.appId, userId, true); const summary = await regenerateImage(db, userId, args.appId, "illustration"); return result({ app: await getMiniApp(db, args.appId, userId), ogImageUrl: summary.ogImageUrl }); }));
  server.registerTool("add_mini_app_records", { title: "Add Mini App Records", description: "Add initial data to a table of a Mini App you can write to: up to 100 records (field → value, matching the table's declared fields) per call. All records are checked before any is saved. Personal tables are filled for the signed-in user only. For images or files, store the reference from upload_mini_app_file in a json field. Free.", inputSchema: { appId: z.string().uuid(), table: miniId, records: z.array(recordData).min(1).max(MINI_SEED_MAX_RECORDS) }, ...meta("add_mini_app_records", false) }, args => run("add_mini_app_records", async () => { miniEnabled(); return result(await addMiniRecords(db, args.appId, userId, args.table, args.records)); }));
  server.registerTool("list_mini_app_records", { title: "List Mini App Records", description: "Read records of a Mini App table the signed-in user can access (their own rows of a personal table), 50 per page. Pass nextCursor back as cursor.", inputSchema: { appId: z.string().uuid(), table: miniId, cursor: z.string().regex(/^\d{1,6}$/).optional() }, ...meta("list_mini_app_records", true) }, args => run("list_mini_app_records", async () => { miniEnabled(); return result(await queryMiniRecords(db, args.appId, userId, { table: args.table, filters: [], limit: 50 }, {}, args.cursor)); }));
  server.registerTool("upload_mini_app_file", { title: "Upload Mini App File", description: "Store an image or file for a Mini App and return a file reference {id, url, name, contentType, size, width?, height?}. Give uploadKey from create_upload (PUT the bytes first) or a public url. Images are re-encoded as JPEG (max 2048 px, metadata stripped); other files are served as downloads. Put the reference in a json record field (add_mini_app_records) or initialState, and show images with an Image element whose url is the reference's url. Up to 25 MB.", inputSchema: { appId: z.string().uuid(), uploadKey: z.string().trim().min(1).max(300).optional(), url: z.string().url().max(4096).optional(), name: z.string().trim().min(1).max(200).optional() }, ...meta("upload_mini_app_file", false) }, args => run("upload_mini_app_file", async () => { miniEnabled(); const { appId, ...input } = args; return result({ file: await attachMiniAppFile(db, appId, userId, attachMiniFileSchema.parse(input)) }); }));
}
