import { ApiError } from "@/lib/http/errors";
import { tool } from "ai";
import { z } from "zod";
import type { Database } from "@/lib/db/client";
import { miniAppCatalog, miniAppInputSchema } from "@/lib/contracts/mini-app";
import { getMiniApp, listMiniApps, updateMiniApp } from "@/lib/mini-app/service";
import { validateMiniApp } from "@/lib/mini-app/validation";
export const MINI_CHAT_GUIDE = `
Mini Apps are saved native interactive apps. When asked to build an app, call getMiniAppCatalog, compose only supported components and logic, then previewMiniApp. The preview card lets the user try it with isolated sample data and save it. Never request API keys or OAuth secrets in chat; declare connectors and direct the user to Connections. All opening/search/refresh/change events must use read actions. Scripts are JSON-in/JSON-out function bodies with input, with no host APIs. For existing apps getMiniApp before updateMiniApp, use the exact current revision, and preserve data schemas. A save never changes live records. Only update an existing app when requested. Never execute connection operations through authoring tools.`;
export function miniChatTools(db: Database, userId: string) {
  return {
    getMiniAppCatalog: tool({ description: "Native Mini App component and logic schemas with an example.", inputSchema: z.object({}), execute: async () => miniAppCatalog() }),
    previewMiniApp: tool({ description: "Validate and show a Mini App draft for interactive isolated preview and saving by the user.", inputSchema: z.object({ document: miniAppInputSchema }), execute: async ({ document }) => { const result = await validateMiniApp(document); return result.ok ? { miniAppDraft: result.document, text: `Mini App draft: ${document.title}. Preview uses sample data; Save creates the app.` } : result; } }),
    listMiniApps: tool({ description: "List the user's saved Mini Apps, ten at a time.", inputSchema: z.object({ cursor: z.string().optional() }), execute: async ({ cursor }) => listMiniApps(db, userId, cursor) }),
    getMiniApp: tool({ description: "Read a Mini App definition before discussing or editing it.", inputSchema: z.object({ appId: z.string().uuid() }), execute: async ({ appId }) => ({ app: await getMiniApp(db, appId, userId) }) }),
    updateMiniApp: tool({ description: "Save a requested edit of an owned Mini App as a new version. Never changes live records or credentials.", inputSchema: z.object({ appId: z.string().uuid(), revision: z.number().int().nonnegative(), document: miniAppInputSchema }), execute: async ({ appId, revision, document }) => { try { return { app: await updateMiniApp(db, appId, userId, document, revision, "chat") }; } catch (error) { return { error: error instanceof Error ? error.message : "Could not save", diagnostics: error instanceof ApiError ? error.details : undefined }; } } }),
  };
}
