import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";
import { ALLOWED_TTL_DAYS } from "@/lib/config";
import { CATEGORIES, LIBRARY_SCOPES, importSummarySchema, type ListQuery, type TranslationLanguage } from "@/lib/contracts/api";
import type { Database } from "@/lib/db/client";
import { VIEW_GUIDE } from "@/lib/ai/trip-agent";
import { createTripSchema, ingestTripSchema, MAX_PLACE_PHOTOS, photoSchema, placePatchSchema, tripDocumentSchema, tripOperationSchema, tripOperationsRequestSchema } from "@/lib/contracts/trip";
import { SUMMARY_KINDS, SUMMARY_SOURCES, VISIBILITIES } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { recordApiKeyUsage, type ApiKeyPrincipal } from "@/lib/services/api-keys";
import { importSummary, listSummaries } from "@/lib/services/summaries";
import type { SummaryJson } from "@/lib/services/serialize";
import { uploadTripImage, uploadTripImageSchema } from "@/lib/services/trip-images";
import { addToTripFromSource, applyTripOperations, createTrip, getTrip, listTrips, type TripJson } from "@/lib/services/trips";
import type { BillingEnvironment } from "@/lib/subscription/config";

export const TOOL_NAMES = {
  addSummary: "add_summary",
  searchSummaries: "search_summaries",
  listSummaries: "list_summaries",
  listTrips: "list_trips",
  getTrip: "get_trip",
  createTrip: "create_trip",
  updateTrip: "update_trip",
  updatePlace: "update_place",
  uploadTripImage: "upload_trip_image",
  addToTripFromSource: "add_to_trip_from_source",
} as const;
export const MAX_SEARCH_RESULTS = 50;
export const MAX_LIST_RESULTS = 200;

export const INSTRUCTIONS = "Chippy is the user's library of summary cards (\"chips\"). Use search_summaries to find chips by meaning "
  + "(natural language), list_summaries to browse the library newest first by source, category, tag or visibility, and "
  + "add_summary to save a summary you wrote together with its raw source text. Nothing is re-summarised on add, and each "
  + "added chip counts against the user's summary allowance. Trips are structured travel diaries (days, places, trains and "
  + "flights, hotels, expenses, and custom views such as a fare comparison table): list_trips and get_trip read them, create_trip saves a new TripDocument, update_trip applies "
  + "entity-level operations (upsert or delete records by id; free), update_place changes a place's details (description, "
  + "photos, hours, prices, website, phone…) without resending it, upload_trip_image stores a photo for a place or view and "
  + "returns its URL, and add_to_trip_from_source lets Chippy's trip agent "
  + "add a web page or text (a booking, a timetable) to a trip, which costs points.";

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

/** What the trip tools return for a trip: the document with its id, revision and link. */
function tripPayload(trip: TripJson) {
  return { id: trip.id, revision: trip.revision, visibility: trip.visibility, shareUrl: trip.shareUrl, updatedAt: trip.updatedAt, document: trip.document };
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
    if (error.code === "TRIP_REVISION_CONFLICT") return `${error.message} Call get_trip for the latest document, then update_trip again. (${error.code})`;
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
    .describe("all: the user's own chips and others' public chips they opened (default). mine: only chips the user created. viewed: only others' chips the user opened. liked: only chips the user starred, most recently starred first."),
  source: z.enum(SUMMARY_SOURCES).optional().describe("Only chips made from this kind of source."),
  category: z.enum(CATEGORIES).optional().describe("Only chips in this category."),
  tag: z.string().trim().max(40).optional().describe("Only chips with this tag."),
  visibility: z.enum(VISIBILITIES).optional().describe("Only public or only private chips."),
  kind: z.enum(SUMMARY_KINDS).optional().describe("summary: only summary cards. trip: only trip diaries (open them with get_trip)."),
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
    kind: args.kind,
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
    const page = await listSummaries(db, principal.sub, listQuery({ ...args, q: args.query, limit: args.limit ?? 10 }), { accepted: context.accepted, billingEnvironment: async () => context.billingEnvironment });
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
    const page = await listSummaries(db, principal.sub, listQuery({ ...args, limit: args.limit ?? 50 }), { accepted: context.accepted, billingEnvironment: async () => context.billingEnvironment });
    return { result: success(listPayload(page)) };
  }));

  server.registerTool(TOOL_NAMES.listTrips, {
    title: "List Trips",
    description: "List the user's trips: ongoing and upcoming first (soonest start first), then past ones. Each has its id, "
      + "title, dates, revision and how many days and places it has; open one with get_trip.",
    inputSchema: {},
    annotations: { title: "List Trips", readOnlyHint: true, openWorldHint: false },
  }, () => run(async () => {
    const { trips } = await listTrips(db, principal.sub);
    return { result: success({ count: trips.length, trips }) };
  }));

  server.registerTool(TOOL_NAMES.getTrip, {
    title: "Get Trip",
    description: "Read a trip's full TripDocument (days with moments and routes, places with coordinates, transports with "
      + "train and flight segments, hotels, expenses, notes, sources, custom views) and its current revision. Pass the revision to "
      + "update_trip to make sure nobody changed the trip in between.",
    inputSchema: { tripId: z.string().trim().min(1).max(100).describe("The trip's id, from list_trips.") },
    annotations: { title: "Get Trip", readOnlyHint: true, openWorldHint: false },
  }, (args) => run(async () => {
    const trip = await getTrip(db, args.tripId, principal.sub);
    return { result: success({ trip: tripPayload(trip) }) };
  }));

  server.registerTool(TOOL_NAMES.createTrip, {
    title: "Create Trip",
    description: "Create a trip from a complete TripDocument (see docs/trips.md: version 1, title, startDate, endDate, "
      + "timeZone, currency, places, days, transports, hotels, expenses, notes, sources). Records reference each other by "
      + "id, and every referenced id must exist. The trip appears in the user's library; it does not count against the "
      + "summary allowance.",
    inputSchema: {
      document: tripDocumentSchema.describe("The trip document."),
      visibility: z.enum(VISIBILITIES).optional().describe("private: only the user (default). public: anyone with the share link."),
    },
    annotations: { title: "Create Trip", readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
  }, (args) => run(async () => {
    const input = createTripSchema.parse({ document: args.document, visibility: args.visibility });
    const trip = await createTrip(db, principal, input, { billingEnvironment: context.billingEnvironment });
    return { result: success({ trip: tripPayload(trip) }, `Created trip "${trip.document.title}" (${trip.visibility}).\n${trip.shareUrl}`) };
  }));

  server.registerTool(TOOL_NAMES.updateTrip, {
    title: "Update Trip",
    description: "Edit a trip with operations applied in order, as one change: set_meta (title, dates, intro…), "
      + "upsert_place / upsert_day / upsert_transport / upsert_hotel / upsert_expense / upsert_note / upsert_view (a full "
      + "record; the same id replaces it, a new id adds it), update_place (id, changes: only the fields to change, addPhotos), add_source, and delete (collection + id; references to it are cleared). "
      + `${VIEW_GUIDE} `
      + "Places can carry guidebook details: description, photos ([{ url, caption, credit, sourceUrl }], direct https "
      + "image URLs you have verified, e.g. from Wikimedia Commons or the place's own site), hours, visitDuration, pricing "
      + "([{ label, price: { amount, currency }, note }]), website and phone; the app shows them with directions to the coordinate. "
      + "Copy unchanged fields when upserting an existing record. Use kebab-case ids for new records. Pass the revision "
      + "from get_trip to refuse the edit if the trip changed meanwhile. Free.",
    inputSchema: {
      tripId: z.string().trim().min(1).max(100).describe("The trip's id."),
      operations: z.array(tripOperationSchema).min(1).max(200).describe("Operations, applied in order."),
      revision: z.number().int().min(0).optional().describe("The revision the edit is based on; omit to apply to the latest."),
    },
    annotations: { title: "Update Trip", readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false },
  }, (args) => run(async () => {
    const input = tripOperationsRequestSchema.parse({ operations: args.operations, revision: args.revision });
    const trip = await applyTripOperations(db, principal.sub, args.tripId, input);
    return { result: success({ trip: tripPayload(trip) }, `Updated "${trip.document.title}" (revision ${trip.revision}).`) };
  }));

  server.registerTool(TOOL_NAMES.updatePlace, {
    title: "Update Place",
    description: "Change some fields of one of a trip's places, like a guidebook entry: description (what it is, why go), "
      + "hours, visitDuration, pricing ([{ label, price: { amount, currency }, note }] — omit price for free; replaces the "
      + "list), website, phone, address, note, name, kind, coordinate, major, photos (replaces the list). Fields you leave "
      + "out stay as they are; null clears one. addPhotos appends photos ({ url, caption, credit, sourceUrl }; direct https "
      + "image URLs, ideally from upload_trip_image) after the existing ones, at most 12 in all. Free.",
    inputSchema: {
      tripId: z.string().trim().min(1).max(100).describe("The trip's id."),
      placeId: z.string().trim().min(1).max(80).describe("The place's id (from get_trip)."),
      changes: placePatchSchema.optional().describe("The fields to change."),
      addPhotos: z.array(photoSchema).max(MAX_PLACE_PHOTOS).optional().describe("Photos to add after the existing ones."),
      revision: z.number().int().min(0).optional().describe("The revision the edit is based on; omit to apply to the latest."),
    },
    annotations: { title: "Update Place", readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  }, (args) => run(async () => {
    const current = await getTrip(db, args.tripId, principal.sub);
    if (!current.document.places.some((place) => place.id === args.placeId)) {
      return { result: failure(`The trip has no place "${args.placeId}". Places: ${current.document.places.map((place) => place.id).join(", ") || "none"}.`) };
    }
    const input = tripOperationsRequestSchema.parse({
      operations: [{ op: "update_place", id: args.placeId, changes: args.changes ?? {}, addPhotos: args.addPhotos ?? [] }],
      revision: args.revision,
    });
    const trip = await applyTripOperations(db, principal.sub, args.tripId, input);
    const place = trip.document.places.find((candidate) => candidate.id === args.placeId);
    return { result: success({ place, revision: trip.revision }, `Updated "${place?.name ?? args.placeId}" (revision ${trip.revision}).`) };
  }));

  server.registerTool(TOOL_NAMES.uploadTripImage, {
    title: "Upload Trip Image",
    description: "Store a photo for one of the user's trips and get a lasting https URL for a place's photos (update_place "
      + "addPhotos) or an Image / Gallery view. Give either url (a public image, copied so it keeps working when the page "
      + "changes or blocks hotlinking) or data (the image as base64). JPEG, PNG, WebP, GIF, AVIF or HEIC up to 15 MB; it's "
      + "re-encoded as a JPEG of at most 2048 px with location and camera metadata removed. Only upload images you may use "
      + "(e.g. the place's own site, Wikimedia Commons) and credit them. Free.",
    inputSchema: {
      tripId: z.string().trim().min(1).max(100).describe("The trip's id."),
      url: z.string().trim().url().max(4096).optional().describe("A public image URL to copy."),
      data: z.string().trim().optional().describe("The image as base64 (or a data: URL)."),
    },
    annotations: { title: "Upload Trip Image", readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true },
  }, (args) => run(async () => {
    const input = uploadTripImageSchema.parse({ url: args.url, data: args.data });
    const image = await uploadTripImage(db, principal.sub, args.tripId, input);
    return { result: success({ image }, `Uploaded a ${image.width}×${image.height} image.\n${image.url}`) };
  }));

  server.registerTool(TOOL_NAMES.addToTripFromSource, {
    title: "Add to Trip from Source",
    description: "Have Chippy's trip agent read a web page (url) or text (a booking confirmation, a timetable, a hotel "
      + "page, notes) and add what it contributes to a trip: transports with train or flight details, hotels, places, "
      + "expenses, notes. Optional instructions steer it (\"use the 10:15 ferry\"). Costs points; takes up to about 3 minutes.",
    inputSchema: {
      tripId: z.string().trim().min(1).max(100).describe("The trip's id."),
      url: z.string().optional().describe("http(s) URL of the page to read."),
      text: z.string().optional().describe("Text to read instead of a URL, at most 200,000 characters."),
      instructions: z.string().max(2000).optional().describe("What to do with it, in the user's words."),
    },
    annotations: { title: "Add to Trip from Source", readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true },
  }, (args) => run(async () => {
    if (!args.url === !args.text) throw new ApiError(400, "VALIDATION_ERROR", "Pass either url or text.");
    const input = ingestTripSchema.parse({
      source: args.url ? { type: "url", url: args.url } : { type: "text", text: args.text },
      instructions: args.instructions || undefined,
    });
    const run = await addToTripFromSource(db, principal.sub, args.tripId, input, { billingEnvironment: context.billingEnvironment });
    return {
      result: success(
        { changeSummary: run.changeSummary, operationsApplied: run.applied, trip: tripPayload(run.trip) },
        `${run.changeSummary || "No changes."} (${run.applied} operation${run.applied === 1 ? "" : "s"}, revision ${run.trip.revision})`,
      ),
    };
  }));

  return server;
}
