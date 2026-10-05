import { z } from "zod";
import { ALLOWED_TTL_DAYS } from "@/lib/config";
import { IMAGE_STYLES, SUMMARY_KINDS, SUMMARY_SOURCES, VISIBILITIES } from "@/lib/db/schema";

export const CATEGORIES = [
  "Technology", "Science", "Business", "Finance", "Politics", "World", "Health", "Sports",
  "Entertainment", "Culture", "Education", "Lifestyle", "Travel", "Food", "Opinion", "Research", "Other",
] as const;
export type Category = (typeof CATEGORIES)[number];

export const OUTPUT_LANGUAGES = ["auto", "en", "zh-Hans", "zh-Hant", "ja", "ko", "es", "fr", "de"] as const;
export type OutputLanguage = (typeof OUTPUT_LANGUAGES)[number];

/** Languages a summary can be translated into (and read in). */
export const TRANSLATION_LANGUAGES = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "es", "fr", "de"] as const satisfies readonly Exclude<OutputLanguage, "auto">[];
export type TranslationLanguage = (typeof TRANSLATION_LANGUAGES)[number];

export const MAX_UPLOAD_BYTES = 25 * 1024 * 1024;
export const MAX_WEBPAGE_CONTENT = 60_000;
/** The page's main-content markup from the device, so the kept document has its links and images. */
export const MAX_WEBPAGE_HTML = 400_000;
export const MAX_TEXT_LENGTH = 200_000;

export const httpUrl = z.string().trim().max(4096).refine((value) => {
  try {
    const url = new URL(value);
    return url.protocol === "http:" || url.protocol === "https:";
  } catch {
    return false;
  }
}, "must be an http(s) URL");

export const ttlDaysSchema = z.union([
  z.literal(null),
  z.number().int().refine((value) => (ALLOWED_TTL_DAYS as readonly number[]).includes(value), {
    message: `must be one of ${ALLOWED_TTL_DAYS.join(", ")} or null`,
  }),
]);

export const sourceSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("url"), url: httpUrl }),
  z.object({
    type: z.literal("webpage"),
    url: httpUrl,
    title: z.string().max(1000).nullish(),
    // Clients truncate to 60k; allow a little slack for multi-byte counting differences.
    content: z.string().max(MAX_WEBPAGE_CONTENT + 5_000).nullish(),
    html: z.string().max(MAX_WEBPAGE_HTML).nullish(),
    siteName: z.string().max(300).nullish(),
    lang: z.string().max(35).nullish(),
  }),
  z.object({
    type: z.literal("pdf"),
    uploadKey: z.string().min(1).max(300),
    filename: z.string().max(300).nullish(),
    sourceUrl: httpUrl.nullish(),
  }),
  z.object({
    type: z.literal("text"),
    text: z.string().max(MAX_TEXT_LENGTH).refine((value) => value.trim().length > 0, "must not be empty"),
    title: z.string().max(1000).nullish(),
  }),
  /** Text the device read from a local file. Summarised, then discarded: the file stays on the device. */
  z.object({
    type: z.literal("local"),
    kind: z.enum(["pdf", "text"]),
    text: z.string().max(MAX_TEXT_LENGTH).refine((value) => value.trim().length > 0, "must not be empty"),
    filename: z.string().trim().min(1).max(300),
  }),
]);
export type SourceInput = z.infer<typeof sourceSchema>;

const tagSchema = z.string().trim().min(1).max(40).transform((value) => value.toLowerCase());

export const createSummarySchema = z.object({
  source: sourceSchema,
  language: z.enum(OUTPUT_LANGUAGES).default("auto"),
  imageStyle: z.enum(IMAGE_STYLES).default("graphic"),
  ttlDays: ttlDaysSchema.optional(),
  visibility: z.enum(VISIBILITIES).default("public"),
  /**
   * The client can read pages in an on-device web view. A page the server cannot read then fails
   * with `SOURCE_NEEDS_DEVICE` (`details.url`) so the client resubmits it as a `webpage`, instead of
   * erroring (`url`) or falling back to the shared text (`text`).
   */
  deviceReader: z.boolean().optional(),
  /** `text` sources judged to be a shared link read that page instead (default). False after the device failed to read it too. */
  followLinks: z.boolean().optional(),
  /**
   * Local files (`local`, and `pdf` uploads without a `sourceUrl`) are not kept by default; true
   * keeps their text, rewritten as Markdown, for reading later. Links and text are always kept.
   */
  keepSourceText: z.boolean().optional(),
});
export type CreateSummaryInput = z.infer<typeof createSummarySchema>;

/**
 * `POST /api/v1/summaries/import` — a summary written elsewhere (another app, a script, an agent),
 * saved as given together with its tags and raw source text. No model summarises it; the server only
 * checks it for duplicates, designs the cover and indexes it for search.
 */
export const importSummarySchema = z.object({
  title: z.string().trim().min(1).max(200),
  summary: z.string().trim().min(1).max(1200),
  /** The raw source text; kept as the summary's source document (plain text is valid Markdown). */
  text: z.string().max(MAX_TEXT_LENGTH).refine((value) => value.trim().length > 0, "must not be empty"),
  tags: z.array(tagSchema).max(12).default([]),
  highlights: z.array(z.string().trim().min(1).max(300)).max(5).default([]),
  category: z.enum(CATEGORIES).default("Other"),
  keywords: z.array(z.string().trim().min(1).max(60)).max(10).default([]),
  /** BCP-47 code of the language the title and summary are written in. */
  language: z.string().trim().min(1).max(35).default("en"),
  sourceUrl: httpUrl.nullish(),
  sourceTitle: z.string().trim().max(1000).nullish(),
  siteName: z.string().trim().max(300).nullish(),
  imageStyle: z.enum(IMAGE_STYLES).default("graphic"),
  ttlDays: ttlDaysSchema.optional(),
  visibility: z.enum(VISIBILITIES).default("public"),
  /**
   * Imports are checked against the caller's library first: one with the same source, title or
   * content is refused with `409 DUPLICATE_SUMMARY` (`details.duplicate`). True saves it anyway.
   */
  allowDuplicate: z.boolean().default(false),
}).strict();
export type ImportSummaryInput = z.infer<typeof importSummarySchema>;

export const patchSummarySchema = z.object({
  visibility: z.enum(VISIBILITIES).optional(),
  ttlDays: ttlDaysSchema.optional(),
  title: z.string().trim().min(1).max(200).optional(),
  tags: z.array(tagSchema).max(12).optional(),
  /** Owner only: the language to read the summary in from now on (translated on first use); null = as written. */
  displayLanguage: z.enum(TRANSLATION_LANGUAGES).nullable().optional(),
}).strict();
export type PatchSummaryInput = z.infer<typeof patchSummarySchema>;

export const regenerateImageSchema = z.object({ imageStyle: z.enum(IMAGE_STYLES) });

export const createUploadSchema = z.object({
  filename: z.string().trim().min(1).max(300),
  mimeType: z.literal("application/pdf"),
  byteSize: z.number().int().positive().max(MAX_UPLOAD_BYTES),
});

export const recordViewSchema = z.object({ slug: z.string().trim().min(1).max(64) });

const limitSchema = z.coerce.number().int().min(1).max(50).default(20);
const optionalString = (max: number) => z.string().trim().max(max).optional().transform((value) => value || undefined);

export const LIBRARY_SCOPES = ["all", "mine", "viewed", "liked"] as const;

export const listQuerySchema = z.object({
  /** `mine` = created by the caller, `viewed` = others' public summaries the caller opened, `liked` = starred by the caller (newest like first). */
  scope: z.enum(LIBRARY_SCOPES).default("all"),
  q: optionalString(200),
  category: z.enum(CATEGORIES).optional(),
  tag: optionalString(40).transform((value) => value?.toLowerCase()),
  visibility: z.enum(VISIBILITIES).optional(),
  /** What the summary was made from: a web page, PDF, text, or a post/video/repo on a platform. */
  source: z.enum(SUMMARY_SOURCES).optional(),
  /** `summary` cards or `trip` diaries; both when absent. */
  kind: z.enum(SUMMARY_KINDS).optional(),
  cursor: optionalString(200),
  limit: limitSchema,
});
export type ListQuery = z.infer<typeof listQuerySchema>;

/** `GET /api/v1/facets?kind=…` — one facet list, filtered by `q` and paged (offset cursor). */
export const facetQuerySchema = z.object({
  kind: z.enum(["category", "tag"]).optional(),
  q: optionalString(40),
  cursor: optionalString(200),
  limit: limitSchema,
});
export type FacetQuery = z.infer<typeof facetQuerySchema>;

export function queryObject(request: Request): Record<string, string> {
  const params = new URL(request.url).searchParams;
  const out: Record<string, string> = {};
  for (const [key, value] of params) if (value !== "") out[key] = value;
  return out;
}

/** `POST /api/v1/api-keys` and `PATCH /api/v1/api-keys/:id` — a personal key for the MCP server. */
export const apiKeyNameSchema = z.object({
  name: z.string().trim().min(1).max(60),
}).strict();
export type ApiKeyNameInput = z.infer<typeof apiKeyNameSchema>;
