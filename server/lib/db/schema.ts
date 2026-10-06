import { sql } from "drizzle-orm";
import type { TripDocument } from "@/lib/contracts/trip";
import type { ProviderFlight } from "@/lib/flights/provider";
import { blob, index, integer, primaryKey, sqliteTable, text, uniqueIndex } from "drizzle-orm/sqlite-core";

/** `local`: a file on the user's device; its text is summarised but never stored. */
export const SOURCE_TYPES = ["url", "webpage", "pdf", "text", "local"] as const;
/** What kind of content a summary was made from, independent of how it was submitted. Extend as new kinds land. */
export const SUMMARY_SOURCES = ["web", "pdf", "text", "x", "facebook", "youtube", "github"] as const;
export const IMAGE_STYLES = ["graphic", "illustration"] as const;
export const VISIBILITIES = ["public", "private"] as const;
/** What a library item is: a summary card, or a trip diary (its structured document lives in `trips`). */
export const SUMMARY_KINDS = ["summary", "trip"] as const;

export type SourceType = (typeof SOURCE_TYPES)[number];
export type SummarySource = (typeof SUMMARY_SOURCES)[number];
export type ImageStyle = (typeof IMAGE_STYLES)[number];
export type Visibility = (typeof VISIBILITIES)[number];
export type SummaryKind = (typeof SUMMARY_KINDS)[number];

export interface SummaryTheme {
  colors: string[];
  mode: "light" | "dark";
  emoji: string;
  accent: string;
}

const now = sql`(cast(unixepoch('subsecond') * 1000 as integer))`;

export const users = sqliteTable("users", {
  id: text("id").primaryKey(),
  email: text("email"),
  name: text("name"),
  /** Pending account deletion iff non-null; see `lib/services/account-deletion.ts`. */
  deletionScheduledAt: integer("deletion_scheduled_at", { mode: "timestamp_ms" }),
  deletionRequestedAt: integer("deletion_requested_at", { mode: "timestamp_ms" }),
  /** Fencing token: a sweep only finalizes the schedule it read, never a cancelled-and-renewed one. */
  deletionRequestId: text("deletion_request_id"),
  createdAt: integer("created_at", { mode: "timestamp_ms" }).notNull().default(now),
}, (table) => [
  index("users_deletion_scheduled_idx").on(table.deletionScheduledAt),
]);

export const summaries = sqliteTable("summaries", {
  id: text("id").primaryKey(),
  slug: text("slug").notNull(),
  ownerId: text("owner_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  kind: text("kind", { enum: SUMMARY_KINDS }).notNull().default("summary"),
  sourceType: text("source_type", { enum: SOURCE_TYPES }).notNull(),
  source: text("source", { enum: SUMMARY_SOURCES }).notNull().default("web"),
  sourceUrl: text("source_url"),
  sourceTitle: text("source_title"),
  siteName: text("site_name"),
  sourceFileKey: text("source_file_key"),
  contentExcerpt: text("content_excerpt").notNull().default(""),
  /** The full extracted source text (capped at `SOURCE_TEXT_LIMIT`); grounds the per-summary chat. */
  contentText: text("content_text").notNull().default(""),
  /**
   * The source rewritten as clean Markdown by the model, for reading in the app. Kept for links,
   * shared pages and text; for local files only when the owner opted in. Null when not kept.
   */
  contentMarkdown: text("content_markdown"),
  title: text("title").notNull(),
  summary: text("summary").notNull(),
  highlights: text("highlights", { mode: "json" }).$type<string[]>().notNull(),
  category: text("category").notNull(),
  tags: text("tags", { mode: "json" }).$type<string[]>().notNull(),
  keywords: text("keywords", { mode: "json" }).$type<string[]>().notNull(),
  language: text("language").notNull(),
  /** The language the owner chose to read this summary in (a `TRANSLATION_LANGUAGES` code); null = as written. */
  displayLanguage: text("display_language"),
  theme: text("theme", { mode: "json" }).$type<SummaryTheme>().notNull(),
  /** The OG image headline chosen by the model; not part of the public JSON. */
  ogHeadline: text("og_headline"),
  imageStyle: text("image_style", { enum: IMAGE_STYLES }).notNull().default("graphic"),
  ogImageKey: text("og_image_key"),
  /** The OG artwork without any text (library tiles draw their own title over it). */
  artImageKey: text("art_image_key"),
  visibility: text("visibility", { enum: VISIBILITIES }).notNull().default("public"),
  ttlDays: integer("ttl_days"),
  expiresAt: integer("expires_at", { mode: "timestamp_ms" }),
  viewCount: integer("view_count").notNull().default(0),
  createdAt: integer("created_at", { mode: "timestamp_ms" }).notNull().default(now),
  updatedAt: integer("updated_at", { mode: "timestamp_ms" }).notNull().default(now),
}, (table) => [
  uniqueIndex("summaries_slug_unique").on(table.slug),
  index("summaries_owner_created_idx").on(table.ownerId, table.createdAt, table.id),
  index("summaries_expires_idx").on(table.expiresAt),
]);

export const summaryTags = sqliteTable("summary_tags", {
  summaryId: text("summary_id").notNull().references(() => summaries.id, { onDelete: "cascade" }),
  tag: text("tag").notNull(),
}, (table) => [
  primaryKey({ columns: [table.summaryId, table.tag] }),
  index("summary_tags_tag_idx").on(table.tag),
]);

export const summaryViews = sqliteTable("summary_views", {
  userId: text("user_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  summaryId: text("summary_id").notNull().references(() => summaries.id, { onDelete: "cascade" }),
  viewedAt: integer("viewed_at", { mode: "timestamp_ms" }).notNull().default(now),
}, (table) => [
  primaryKey({ columns: [table.userId, table.summaryId] }),
  index("summary_views_user_viewed_idx").on(table.userId, table.viewedAt),
  index("summary_views_summary_idx").on(table.summaryId),
]);

/** Summaries a user starred: their own, or others' public ones. Listed with `scope=liked`, newest like first. */
export const summaryLikes = sqliteTable("summary_likes", {
  userId: text("user_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  summaryId: text("summary_id").notNull().references(() => summaries.id, { onDelete: "cascade" }),
  likedAt: integer("liked_at", { mode: "timestamp_ms" }).notNull().default(now),
}, (table) => [
  primaryKey({ columns: [table.userId, table.summaryId] }),
  index("summary_likes_user_liked_idx").on(table.userId, table.likedAt),
  index("summary_likes_summary_idx").on(table.summaryId),
]);

/**
 * One embedding per summary for natural-language search. Kept out of `summaries` so list queries
 * never load the vectors. `embedding` holds a libSQL `vector32` blob and is only compared to
 * vectors of the same `model` (dimensions differ between models). Searched exactly with
 * `vector_distance_cos` — no vector index, since Turso Cloud's MVCC mode rejects virtual tables.
 */
export const summaryEmbeddings = sqliteTable("summary_embeddings", {
  summaryId: text("summary_id").primaryKey().references(() => summaries.id, { onDelete: "cascade" }),
  model: text("model").notNull(),
  embedding: blob("embedding", { mode: "buffer" }).notNull(),
  updatedAt: integer("updated_at", { mode: "timestamp_ms" }).notNull().default(now),
}, (table) => [
  index("summary_embeddings_model_idx").on(table.model),
]);

/**
 * A summary translated into one of `TRANSLATION_LANGUAGES`: its title, summary and highlights, and
 * the kept source document. `contentMarkdown` follows the `summaries` convention: "" while the
 * translation is being written, null when there is no source to translate (or it failed).
 */
export const summaryTranslations = sqliteTable("summary_translations", {
  summaryId: text("summary_id").notNull().references(() => summaries.id, { onDelete: "cascade" }),
  language: text("language").notNull(),
  title: text("title").notNull(),
  summary: text("summary").notNull(),
  highlights: text("highlights", { mode: "json" }).$type<string[]>().notNull(),
  contentMarkdown: text("content_markdown"),
  /** Display labels in canonical tag order; null for translations that still need chip labels. */
  tags: text("tags", { mode: "json" }).$type<string[]>(),
  /** The translated OG headline; null for translations written before it was translated. */
  headline: text("headline"),
  /** The OG card drawn over the summary's art with the translated headline (rendered on first request). */
  ogImageKey: text("og_image_key"),
  createdAt: integer("created_at", { mode: "timestamp_ms" }).notNull().default(now),
  updatedAt: integer("updated_at", { mode: "timestamp_ms" }).notNull().default(now),
}, (table) => [
  primaryKey({ columns: [table.summaryId, table.language] }),
]);

export type SummaryTranslationRow = typeof summaryTranslations.$inferSelect;

/** Presigned PDF uploads. Rows never attached to a summary are swept by the cleanup cron. */
export const uploads = sqliteTable("uploads", {
  key: text("key").primaryKey(),
  ownerId: text("owner_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  filename: text("filename").notNull(),
  byteSize: integer("byte_size").notNull(),
  summaryId: text("summary_id"),
  attachedAt: integer("attached_at", { mode: "timestamp_ms" }),
  createdAt: integer("created_at", { mode: "timestamp_ms" }).notNull().default(now),
}, (table) => [
  index("uploads_orphan_idx").on(table.attachedAt, table.createdAt),
]);

export type SummaryRow = typeof summaries.$inferSelect;

/**
 * The structured trip diary of a `kind = "trip"` summary (1:1). `revision` counts saves, for
 * optimistic concurrency between app edits and agent edits; `startDate`/`endDate` mirror the
 * document for sorting. The summary row carries the title, search text and sharing.
 */
export const trips = sqliteTable("trips", {
  summaryId: text("summary_id").primaryKey().references(() => summaries.id, { onDelete: "cascade" }),
  document: text("document", { mode: "json" }).$type<TripDocument>().notNull(),
  revision: integer("revision").notNull().default(0),
  startDate: text("start_date"),
  endDate: text("end_date"),
  updatedAt: integer("updated_at", { mode: "timestamp_ms" }).notNull().default(now),
});

export type TripRow = typeof trips.$inferSelect;

/** One pending batch per trip. Later saves extend its quiet period and final document. */
export const tripNotificationBatches = sqliteTable("trip_notification_batches", {
  id: text("id").primaryKey(),
  tripId: text("trip_id").notNull().references(() => trips.summaryId, { onDelete: "cascade" }),
  revision: integer("revision").notNull(),
  beforeDocument: text("before_document", { mode: "json" }).$type<TripDocument>().notNull(),
  afterDocument: text("after_document", { mode: "json" }).$type<TripDocument>().notNull(),
  dueAt: integer("due_at", { mode: "timestamp_ms" }).notNull(),
  status: text("status", { enum: ["pending", "ready"] }).notNull().default("pending"),
  changeSummary: text("change_summary"),
  runnerId: text("runner_id"),
  leaseUntil: integer("lease_until", { mode: "timestamp_ms" }),
}, (table) => [
  uniqueIndex("trip_notifications_pending_unique").on(table.tripId).where(sql`${table.status} = 'pending'`),
  index("trip_notifications_due_idx").on(table.dueAt),
]);

/** Successful installations are skipped on workflow retries; tokens are never stored here. */
export const tripNotificationDeliveries = sqliteTable("trip_notification_deliveries", {
  batchId: text("batch_id").notNull().references(() => tripNotificationBatches.id, { onDelete: "cascade" }),
  installationId: text("installation_id").notNull(),
  userId: text("user_id").notNull().references(() => users.id, { onDelete: "cascade" }),
}, (table) => [primaryKey({ columns: [table.batchId, table.installationId, table.userId] })]);

/**
 * A trip's texts translated into one of `TRANSLATION_LANGUAGES`, as a dictionary from each original
 * text to its translation: a later edit only needs its new texts translated, and the document's
 * ids, dates and numbers are never touched. `revision` is the trip revision last translated.
 */
export const tripTranslations = sqliteTable("trip_translations", {
  summaryId: text("summary_id").notNull().references(() => summaries.id, { onDelete: "cascade" }),
  language: text("language").notNull(),
  strings: text("strings", { mode: "json" }).$type<Record<string, string>>().notNull(),
  revision: integer("revision").notNull(),
  /** A background run (`workflows/translate-trip.ts`) is translating the missing texts since then; null when none is. */
  translatingSince: integer("translating_since", { mode: "timestamp_ms" }),
  createdAt: integer("created_at", { mode: "timestamp_ms" }).notNull().default(now),
  updatedAt: integer("updated_at", { mode: "timestamp_ms" }).notNull().default(now),
}, (table) => [
  primaryKey({ columns: [table.summaryId, table.language] }),
]);

export type TripTranslationRow = typeof tripTranslations.$inferSelect;
export type NewSummaryRow = typeof summaries.$inferInsert;

/** An installation belongs to its most recently signed-in account. */
export const pushDevices = sqliteTable("push_devices", {
  installationId: text("installation_id").primaryKey(),
  ownerId: text("owner_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  token: text("token").notNull(),
  environment: text("environment", { enum: ["sandbox", "production"] }).notNull(),
  platform: text("platform", { enum: ["ios", "macos"] }).notNull(),
  /** ActivityKit push-to-start token for flight Live Activities (hex); null until the app sends one. */
  liveActivityStartToken: text("live_activity_start_token"),
  updatedAt: integer("updated_at", { mode: "timestamp_ms" }).notNull().default(now),
}, (table) => [
  uniqueIndex("push_devices_token_environment_idx").on(table.token, table.environment),
  index("push_devices_owner_idx").on(table.ownerId),
]);

export const FLIGHT_STATES = ["pending", "found", "not_found"] as const;
export const FLIGHT_TRACKING_STATES = ["idle", "tracking", "finished"] as const;
export type FlightState = (typeof FLIGHT_STATES)[number];
export type FlightTrackingState = (typeof FLIGHT_TRACKING_STATES)[number];

/** What a flight's last alerts said, so the next refresh only alerts on real changes. */
export interface FlightAlertState {
  /** The departure delay (minutes) last announced. */
  delayMinutes: number;
}

/**
 * One flight on one day (`CX520-2026-10-12`), shared by every trip on it. `data` is the provider's
 * normalized answer; the `trackFlight` workflow refreshes it. Spec: `docs/flights.md`.
 */
export const flights = sqliteTable("flights", {
  id: text("id").primaryKey(),
  flightNumber: text("flight_number").notNull(),
  date: text("date").notNull(),
  provider: text("provider").notNull(),
  state: text("state", { enum: FLIGHT_STATES }).notNull().default("pending"),
  data: text("data", { mode: "json" }).$type<ProviderFlight>(),
  /** Best known departure / arrival (actual, else estimated, else scheduled). */
  departureAt: integer("departure_at", { mode: "timestamp_ms" }),
  arrivalAt: integer("arrival_at", { mode: "timestamp_ms" }),
  /** When the plane landed (or when the backend first saw it landed). */
  landedAt: integer("landed_at", { mode: "timestamp_ms" }),
  alertState: text("alert_state", { mode: "json" }).$type<FlightAlertState>(),
  fetchedAt: integer("fetched_at", { mode: "timestamp_ms" }),
  trackingState: text("tracking_state", { enum: FLIGHT_TRACKING_STATES }).notNull().default("idle"),
  trackingRunId: text("tracking_run_id"),
  createdAt: integer("created_at", { mode: "timestamp_ms" }).notNull().default(now),
  updatedAt: integer("updated_at", { mode: "timestamp_ms" }).notNull().default(now),
}, (table) => [
  index("flights_tracking_idx").on(table.trackingState),
]);

export type FlightRow = typeof flights.$inferSelect;

/** A flight segment of a trip that is tracked; rebuilt from the trip document on every save. */
export const flightSubscriptions = sqliteTable("flight_subscriptions", {
  tripId: text("trip_id").notNull().references(() => summaries.id, { onDelete: "cascade" }),
  transportId: text("transport_id").notNull(),
  optionId: text("option_id").notNull(),
  segmentIndex: integer("segment_index").notNull(),
  flightId: text("flight_id").notNull().references(() => flights.id, { onDelete: "cascade" }),
  ownerId: text("owner_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  /** When the backend push-started (or the app reported) this flight's Live Activity for the owner. */
  liveActivityStartedAt: integer("live_activity_started_at", { mode: "timestamp_ms" }),
  createdAt: integer("created_at", { mode: "timestamp_ms" }).notNull().default(now),
}, (table) => [
  primaryKey({ columns: [table.tripId, table.transportId, table.optionId, table.segmentIndex] }),
  index("flight_subscriptions_flight_idx").on(table.flightId),
  index("flight_subscriptions_owner_idx").on(table.ownerId),
]);

export type FlightSubscriptionRow = typeof flightSubscriptions.$inferSelect;

/** A running flight Live Activity on one installation, with its ActivityKit update token. */
export const flightLiveActivities = sqliteTable("flight_live_activities", {
  flightId: text("flight_id").notNull().references(() => flights.id, { onDelete: "cascade" }),
  installationId: text("installation_id").notNull(),
  ownerId: text("owner_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  token: text("token").notNull(),
  environment: text("environment", { enum: ["sandbox", "production"] }).notNull(),
  updatedAt: integer("updated_at", { mode: "timestamp_ms" }).notNull().default(now),
}, (table) => [
  primaryKey({ columns: [table.flightId, table.installationId] }),
]);

/**
 * Personal API keys for the hosted MCP server (`/api/mcp`). Only the SHA-256 of a key is stored;
 * the key itself is shown once, when it is created. `hint` (prefix…last four) identifies it in lists.
 */
export const apiKeys = sqliteTable("api_keys", {
  id: text("id").primaryKey(),
  ownerId: text("owner_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  name: text("name").notNull(),
  keyHash: text("key_hash").notNull(),
  hint: text("hint").notNull(),
  toolCallCount: integer("tool_call_count").notNull().default(0),
  summariesAddedCount: integer("summaries_added_count").notNull().default(0),
  lastUsedAt: integer("last_used_at", { mode: "timestamp_ms" }),
  createdAt: integer("created_at", { mode: "timestamp_ms" }).notNull().default(now),
}, (table) => [
  uniqueIndex("api_keys_key_hash_unique").on(table.keyHash),
  index("api_keys_owner_created_idx").on(table.ownerId, table.createdAt),
]);

export type ApiKeyRow = typeof apiKeys.$inferSelect;

/** Public MCP OAuth clients use authorization code + PKCE; no client secrets are issued. */
export const mcpOAuthClients = sqliteTable("mcp_oauth_clients", {
  id: text("id").primaryKey(),
  name: text("name").notNull(),
  redirectUris: text("redirect_uris", { mode: "json" }).$type<string[]>().notNull(),
  createdAt: integer("created_at", { mode: "timestamp_ms" }).notNull().default(now),
}, (table) => [index("mcp_oauth_clients_created_idx").on(table.createdAt)]);

/** Short-lived login/consent state. Upstream access and refresh tokens are never persisted. */
export const mcpOAuthRequests = sqliteTable("mcp_oauth_requests", {
  id: text("id").primaryKey(),
  stateHash: text("state_hash").notNull().unique(),
  clientId: text("client_id").notNull().references(() => mcpOAuthClients.id, { onDelete: "cascade" }),
  redirectUri: text("redirect_uri").notNull(),
  clientState: text("client_state"),
  challenge: text("challenge").notNull(),
  scope: text("scope").notNull(),
  upstreamVerifier: text("upstream_verifier").notNull(),
  loginClaimedAt: integer("login_claimed_at", { mode: "timestamp_ms" }),
  ownerId: text("owner_id").references(() => users.id, { onDelete: "cascade" }),
  consentHash: text("consent_hash"),
  expiresAt: integer("expires_at", { mode: "timestamp_ms" }).notNull(),
}, (table) => [index("mcp_oauth_requests_expiry_idx").on(table.expiresAt)]);

export const mcpOAuthGrants = sqliteTable("mcp_oauth_grants", {
  id: text("id").primaryKey(),
  ownerId: text("owner_id").notNull().references(() => users.id, { onDelete: "cascade" }),
  clientId: text("client_id").notNull().references(() => mcpOAuthClients.id, { onDelete: "cascade" }),
  resource: text("resource").notNull(),
  scope: text("scope").notNull(),
  revokedAt: integer("revoked_at", { mode: "timestamp_ms" }),
  expiresAt: integer("expires_at", { mode: "timestamp_ms" }).notNull(),
}, (table) => [index("mcp_oauth_grants_owner_idx").on(table.ownerId), index("mcp_oauth_grants_expiry_idx").on(table.expiresAt)]);

/** Codes and tokens are stored only as SHA-256 hashes. */
export const mcpOAuthCodes = sqliteTable("mcp_oauth_codes", {
  hash: text("hash").primaryKey(),
  grantId: text("grant_id").notNull().references(() => mcpOAuthGrants.id, { onDelete: "cascade" }),
  redirectUri: text("redirect_uri").notNull(),
  challenge: text("challenge").notNull(),
  usedAt: integer("used_at", { mode: "timestamp_ms" }),
  expiresAt: integer("expires_at", { mode: "timestamp_ms" }).notNull(),
}, (table) => [index("mcp_oauth_codes_expiry_idx").on(table.expiresAt)]);

export const mcpOAuthTokens = sqliteTable("mcp_oauth_tokens", {
  hash: text("hash").primaryKey(),
  grantId: text("grant_id").notNull().references(() => mcpOAuthGrants.id, { onDelete: "cascade" }),
  kind: text("kind", { enum: ["access", "refresh"] }).notNull(),
  usedAt: integer("used_at", { mode: "timestamp_ms" }),
  expiresAt: integer("expires_at", { mode: "timestamp_ms" }).notNull(),
}, (table) => [index("mcp_oauth_tokens_grant_idx").on(table.grantId), index("mcp_oauth_tokens_expiry_idx").on(table.expiresAt)]);
