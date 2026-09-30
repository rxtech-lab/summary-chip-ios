import { sql } from "drizzle-orm";
import { index, integer, primaryKey, sqliteTable, text, uniqueIndex } from "drizzle-orm/sqlite-core";

export const SOURCE_TYPES = ["url", "webpage", "pdf", "text"] as const;
/** What kind of content a summary was made from, independent of how it was submitted. Extend as new kinds land. */
export const SUMMARY_SOURCES = ["web", "pdf", "text"] as const;
export const IMAGE_STYLES = ["graphic", "illustration"] as const;
export const VISIBILITIES = ["public", "private"] as const;

export type SourceType = (typeof SOURCE_TYPES)[number];
export type SummarySource = (typeof SUMMARY_SOURCES)[number];
export type ImageStyle = (typeof IMAGE_STYLES)[number];
export type Visibility = (typeof VISIBILITIES)[number];

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
  sourceType: text("source_type", { enum: SOURCE_TYPES }).notNull(),
  source: text("source", { enum: SUMMARY_SOURCES }).notNull().default("web"),
  sourceUrl: text("source_url"),
  sourceTitle: text("source_title"),
  siteName: text("site_name"),
  sourceFileKey: text("source_file_key"),
  contentExcerpt: text("content_excerpt").notNull().default(""),
  /** The full extracted source text (capped at `SOURCE_TEXT_LIMIT`); grounds the per-summary chat. */
  contentText: text("content_text").notNull().default(""),
  title: text("title").notNull(),
  summary: text("summary").notNull(),
  highlights: text("highlights", { mode: "json" }).$type<string[]>().notNull(),
  category: text("category").notNull(),
  tags: text("tags", { mode: "json" }).$type<string[]>().notNull(),
  keywords: text("keywords", { mode: "json" }).$type<string[]>().notNull(),
  language: text("language").notNull(),
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
export type NewSummaryRow = typeof summaries.$inferInsert;
