import { z } from "zod";
import { ALLOWED_TTL_DAYS } from "@/lib/config";
import { IMAGE_STYLES, SUMMARY_SOURCES, VISIBILITIES } from "@/lib/db/schema";

export const CATEGORIES = [
  "Technology", "Science", "Business", "Finance", "Politics", "World", "Health", "Sports",
  "Entertainment", "Culture", "Education", "Lifestyle", "Travel", "Food", "Opinion", "Research", "Other",
] as const;
export type Category = (typeof CATEGORIES)[number];

export const OUTPUT_LANGUAGES = ["auto", "en", "zh-Hans", "zh-Hant", "ja", "ko", "es", "fr", "de"] as const;
export type OutputLanguage = (typeof OUTPUT_LANGUAGES)[number];

export const MAX_UPLOAD_BYTES = 25 * 1024 * 1024;
export const MAX_WEBPAGE_CONTENT = 60_000;
export const MAX_TEXT_LENGTH = 200_000;

const httpUrl = z.string().trim().max(4096).refine((value) => {
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

export const createSummarySchema = z.object({
  source: sourceSchema,
  language: z.enum(OUTPUT_LANGUAGES).default("auto"),
  imageStyle: z.enum(IMAGE_STYLES).default("graphic"),
  ttlDays: ttlDaysSchema.optional(),
  visibility: z.enum(VISIBILITIES).default("public"),
});
export type CreateSummaryInput = z.infer<typeof createSummarySchema>;

const tagSchema = z.string().trim().min(1).max(40).transform((value) => value.toLowerCase());

export const patchSummarySchema = z.object({
  visibility: z.enum(VISIBILITIES).optional(),
  ttlDays: ttlDaysSchema.optional(),
  title: z.string().trim().min(1).max(200).optional(),
  tags: z.array(tagSchema).max(12).optional(),
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

export const LIBRARY_SCOPES = ["all", "mine", "viewed"] as const;

export const listQuerySchema = z.object({
  /** `mine` = created by the caller, `viewed` = others' public summaries the caller opened. */
  scope: z.enum(LIBRARY_SCOPES).default("all"),
  q: optionalString(200),
  category: z.enum(CATEGORIES).optional(),
  tag: optionalString(40).transform((value) => value?.toLowerCase()),
  visibility: z.enum(VISIBILITIES).optional(),
  /** What the summary was made from: a web page, PDF, text, or a post/video/repo on a platform. */
  source: z.enum(SUMMARY_SOURCES).optional(),
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
