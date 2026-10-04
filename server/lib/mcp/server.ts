import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";
import { ALLOWED_TTL_DAYS } from "@/lib/config";
import { CATEGORIES, LIBRARY_SCOPES, importSummarySchema, type ListQuery, type TranslationLanguage } from "@/lib/contracts/api";
import type { Database } from "@/lib/db/client";
import { SUMMARY_SOURCES, VISIBILITIES } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { recordApiKeyUsage, type ApiKeyPrincipal } from "@/lib/services/api-keys";
import { importSummary, listSummaries } from "@/lib/services/summaries";
import type { SummaryJson } from "@/lib/services/serialize";
import type { BillingEnvironment } from "@/lib/subscription/config";

export const TOOL_NAMES = { addSummary: "add_summary", searchSummaries: "search_summaries", listSummaries: "list_summaries" } as const;
export const MAX_SEARCH_RESULTS = 50;
export const MAX_LIST_RESULTS = 200;

export const INSTRUCTIONS = "Chippy is the user's library of summary cards (\"chips\"). Use search_summaries to find chips by meaning "
  + "(natural language), list_summaries to browse the library newest first by source, category, tag or visibility, and "
  + "add_summary to save a summary you wrote together with its raw source text. Nothing is re-summarised on add, and each "
  + "added chip counts against the user's summary allowance.";

export interface McpContext {
  db: Database;
  principal: ApiKeyPrincipal;
  billingEnvironment?: BillingEnvironment;
  /** The caller's `Accept-Language`: others' chips come back translated into it. */
  accepted: TranslationLanguage | null;
}

/** What the tools return for a chip: everything an agent needs to cite or open it, no artwork URLs. */
function chipPayload(summary: SummaryJson) {
  return {
    id: summary.id,
    title: summary.title,
    summary: summary.summary,
    keyPoints: summary.highlights,
    category: summary.category,
    tags: summary.tags,
    source: summary.source,
    sourceUrl: summary.sourceUrl,
    sourceTitle: summary.sourceTitle,
    siteName: summary.siteName,
    shareUrl: summary.shareUrl,
    visibility: summary.visibility,
    language: summary.language,
    isOwner: summary.isOwner,
    hasSourceText: summary.hasSourceMarkdown,
    createdAt: summary.createdAt,
    viewedAt: summary.viewedAt,
  };
}

/** Structured content plus the same JSON as text, for clients that only read text blocks. */
function success(payload: Record<string, unknown>, text?: string): CallToolResult {
  const json = JSON.stringify(payload);
  return {
    content: [...(text ? [{ type: "text" as const, text }] : []), { type: "text" as const, text: json }],
    structuredContent: payload,
  };
}

function failure(message: string): CallToolResult {
  return { content: [{ type: "text", text: message }], isError: true };
}

function listPayload(page: { items: SummaryJson[]; nextCursor: string | null }) {
  // An explicit null tells the agent there is nothing more to fetch.
  return { count: page.items.length, items: page.items.map(chipPayload), nextCursor: page.nextCursor };
}

function describe(error: unknown): string {
  if (error instanceof ApiError) {
    if (error.code === "DUPLICATE_SUMMARY") {
      const details = error.details as { reason?: string; duplicate?: SummaryJson } | undefined;
      let message = "Not added: this chip is already in the library";
      if (details?.duplicate) message += ` as "${details.duplicate.title}" (${details.duplicate.shareUrl})`;
      message += ".";
      if (details?.reason) message += ` Reason: ${details.reason}`;
      return `${message} Call add_summary again with allowDuplicate: true to save it anyway.`;
    }
    return `${error.message} (${error.code})`;
  }
  if (error instanceof z.ZodError) {
    // Named as the tool's arguments: the import schema calls key points `highlights`.
    const argument = (path: PropertyKey[]) => path.map((part) => (part === "highlights" ? "keyPoints" : String(part))).join(".") || "arguments";
    return error.issues.slice(0, 3).map((issue) => `Invalid ${argument(issue.path)}: ${issue.message}`).join("; ");
  }
  console.error("[mcp] tool failed", error);
  return "An unexpected error occurred. Please try again.";
}

const filters = {
  scope: z.enum(LIBRARY_SCOPES).optional()
    .describe("all: the user's own chips and others' public chips they opened (default). mine: only chips the user created. viewed: only others' chips the user opened."),
  source: z.enum(SUMMARY_SOURCES).optional().describe("Only chips made from this kind of source."),
  category: z.enum(CATEGORIES).optional().describe("Only chips in this category."),
  tag: z.string().trim().max(40).optional().describe("Only chips with this tag."),
  visibility: z.enum(VISIBILITIES).optional().describe("Only public or only private chips."),
};

type Filters = { [K in keyof typeof filters]?: z.infer<(typeof filters)[K]> };

function listQuery(args: Filters & { q?: string; cursor?: string; limit: number }): ListQuery {
  return {
    scope: args.scope ?? "all",
    q: args.q,
    category: args.category,
    tag: args.tag?.toLowerCase() || undefined,
    visibility: args.visibility,
    source: args.source,
    cursor: args.cursor || undefined,
    limit: args.limit,
  };
}

/** A fresh server per request: the endpoint is stateless, so every call carries its own API key. */
export function createMcpServer(context: McpContext): McpServer {
  const { db, principal } = context;
  const server = new McpServer({ name: "chippy", title: "Chippy", version: "1.0.0" }, { instructions: INSTRUCTIONS });

  /** Runs a tool and counts it against the key, whether or not it succeeds. */
  async function run(action: () => Promise<{ result: CallToolResult; summaryAdded?: boolean }>): Promise<CallToolResult> {
    let summaryAdded = false;
    let result: CallToolResult;
    try {
      ({ result, summaryAdded = false } = await action());
    } catch (error) {
      result = failure(describe(error));
    }
    await recordApiKeyUsage(db, principal.apiKeyId, { summaryAdded }).catch((error) => console.error("[mcp] usage not recorded", error));
    return result;
  }

  server.registerTool(TOOL_NAMES.addSummary, {
    title: "Add Summary",
    description: "Save a summary to the user's Chippy library, with its key points, tags and the raw source text. "
      + "Nothing is re-summarised: write the title, summary and key points yourself. The server designs the cover, indexes "
      + "the chip for search and returns the created summary with its share link. A chip already in the library (same "
      + "source, title or content) is refused unless allowDuplicate is true. Counts as one summary against the user's allowance. "
      + "Takes up to about 3 minutes.",
    inputSchema: {
      title: z.string().describe("Title of the chip, at most 200 characters."),
      summary: z.string().describe("The summary, at most 1200 characters."),
      text: z.string().describe("The raw source text the summary was written from, at most 200,000 characters. Kept as the chip's source document."),
      keyPoints: z.array(z.string()).optional().describe("Key points shown under the summary; at most 5, each at most 300 characters."),
      tags: z.array(z.string()).optional().describe("Tags; at most 12, lowercased by the server."),
      keywords: z.array(z.string()).optional().describe("Search keywords; at most 10."),
      category: z.enum(CATEGORIES).optional().describe("Category of the chip. Default Other."),
      language: z.string().optional().describe("BCP-47 code of the language the title and summary are written in, e.g. en, zh-Hant. Default en."),
      sourceUrl: z.string().optional().describe("http(s) URL the text came from."),
      sourceTitle: z.string().optional().describe("Title of the source."),
      siteName: z.string().optional().describe("Name of the source site."),
      visibility: z.enum(VISIBILITIES).optional().describe("public: anyone with the share link can open it (default). private: only the user."),
      ttlDays: z.union([z.number().int(), z.literal("never")]).optional()
        .describe(`How long the public link stays alive: ${ALLOWED_TTL_DAYS.join(", ")} days, or "never". Default: the server's default.`),
      allowDuplicate: z.boolean().optional().describe("Save even when the library already has this chip. Default false."),
    },
    annotations: { title: "Add Summary", readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
  }, (args) => run(async () => {
    // The import route's own validation, so the limits and messages are the API's.
    const input = importSummarySchema.parse({
      title: args.title,
      summary: args.summary,
      text: args.text,
      highlights: args.keyPoints,
      tags: args.tags,
      keywords: args.keywords,
      category: args.category,
      language: args.language || undefined,
      sourceUrl: args.sourceUrl || undefined,
      sourceTitle: args.sourceTitle || undefined,
      siteName: args.siteName || undefined,
      // Agent-added chips get an illustrated cover, never the SVG "graphic" style.
      imageStyle: "illustration",
      ttlDays: args.ttlDays === "never" ? null : args.ttlDays,
      visibility: args.visibility,
      allowDuplicate: args.allowDuplicate,
    });
    const summary = await importSummary(db, principal, input, { billingEnvironment: context.billingEnvironment });
    return {
      result: success({ summary: chipPayload(summary) }, `Added "${summary.title}" (${summary.visibility}).\n${summary.shareUrl}`),
      summaryAdded: true,
    };
  }));

  server.registerTool(TOOL_NAMES.searchSummaries, {
    title: "Search Summaries",
    description: "Search the user's Chippy library with a natural-language query. Matches by meaning and keywords and returns "
      + "the most relevant chips first. Optionally narrow by source (web, x, facebook, youtube, github, pdf, text), category, "
      + "tag, visibility or scope.",
    inputSchema: {
      query: z.string().trim().min(1).max(200).describe("What to look for, in natural language, e.g. \"articles about battery recycling\". At most 200 characters."),
      ...filters,
      limit: z.number().int().min(1).max(MAX_SEARCH_RESULTS).optional().describe(`Results per page, 1–${MAX_SEARCH_RESULTS}. Default 10.`),
      cursor: z.string().max(200).optional().describe("nextCursor from a previous search_summaries call, for the next page."),
    },
    annotations: { title: "Search Summaries", readOnlyHint: true, openWorldHint: false },
  }, (args) => run(async () => {
    const page = await listSummaries(db, principal.sub, listQuery({ ...args, q: args.query, limit: args.limit ?? 10 }), { accepted: context.accepted });
    return { result: success(listPayload(page)) };
  }));

  server.registerTool(TOOL_NAMES.listSummaries, {
    title: "List Summaries",
    description: "List the chips in the user's Chippy library, newest first, filtered by source, category, tag, visibility and "
      + `scope. Use search_summaries instead to find chips by topic. Returns up to ${MAX_LIST_RESULTS} chips per call; pass `
      + "nextCursor back to continue.",
    inputSchema: {
      ...filters,
      limit: z.number().int().min(1).max(MAX_LIST_RESULTS).optional().describe(`How many chips to return, 1–${MAX_LIST_RESULTS}. Default 50.`),
      cursor: z.string().max(200).optional().describe("nextCursor from a previous list_summaries call, for the next page."),
    },
    annotations: { title: "List Summaries", readOnlyHint: true, openWorldHint: false },
  }, (args) => run(async () => {
    const page = await listSummaries(db, principal.sub, listQuery({ ...args, limit: args.limit ?? 50 }), { accepted: context.accepted });
    return { result: success(listPayload(page)) };
  }));

  return server;
}
