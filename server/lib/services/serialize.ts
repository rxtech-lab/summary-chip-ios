import { siteUrl } from "@/lib/config";
import { siteNameFor } from "@/lib/extract/platforms";
import { publicObjectUrl } from "@/lib/storage/r2";
import { categoryLabel } from "@/lib/og/category-labels";
import { translationLanguageFor } from "./translations";
import type { ImageStyle, SourceType, SummaryRow, SummarySource, SummaryTheme, SummaryTranslationRow, Visibility } from "@/lib/db/schema";

/** The `Summary` JSON object from docs/ARCHITECTURE.md. Field order mirrors the contract. */
export interface SummaryJson {
  id: string;
  slug: string;
  shareUrl: string;
  ogImageUrl: string;
  /** The OG artwork without text (for tiles that draw their own title); null when there is none. */
  artImageUrl: string | null;
  /** How the content was submitted (`url`, `webpage`, `pdf`, `text`). */
  sourceType: SourceType;
  /** What the content is (`web`, `pdf`, `text`, …); a `url` that serves a PDF is `pdf`. */
  source: SummarySource;
  sourceUrl: string | null;
  sourceTitle: string | null;
  siteName: string | null;
  sourceFileUrl: string | null;
  /** The source was kept as Markdown; fetch it from `GET /api/v1/summaries/:id/markdown`. */
  hasSourceMarkdown: boolean;
  /** The document agent is still writing the source; poll the summary until `hasSourceMarkdown`. */
  sourceMarkdownPending: boolean;
  title: string;
  summary: string;
  highlights: string[];
  category: string;
  tags: string[];
  /** Category and tag chip labels in the reading language; canonical values above remain filters. */
  displayCategory: string;
  displayTags: string[];
  keywords: string[];
  /** The language `title`, `summary` and `highlights` are in: a translation's, else `originalLanguage`. */
  language: string;
  /** The language the summary was written in. */
  originalLanguage: string;
  /** Owner only: the language they chose to read it in; null = as written (and for everyone else). */
  displayLanguage: string | null;
  /** A translation into the reader's language is being written; fetch the summary again shortly. */
  translationPending: boolean;
  /** The translated source document is being written; `GET …/markdown` serves the original until then. */
  sourceTranslationPending: boolean;
  theme: SummaryTheme;
  imageStyle: ImageStyle;
  visibility: Visibility;
  ttlDays: number | null;
  expiresAt: string | null;
  viewCount: number;
  isOwner: boolean;
  /** When the caller last opened this (someone else's) summary; null for their own. */
  viewedAt: string | null;
  createdAt: string;
  updatedAt: string;
}

export function shareUrlFor(slug: string): string {
  return `${siteUrl()}/s/${slug}`;
}

export function ogImageUrlFor(row: Pick<SummaryRow, "slug" | "updatedAt">): string {
  return `${shareUrlFor(row.slug)}/og.png?v=${row.updatedAt.getTime()}`;
}

/** The cover with its headline in a translation's language, drawn by the OG route on first request. */
export function translatedOgImageUrlFor(row: Pick<SummaryRow, "slug" | "updatedAt">, translation: Pick<SummaryTranslationRow, "language" | "updatedAt">): string {
  const version = Math.max(row.updatedAt.getTime(), translation.updatedAt.getTime());
  return `${shareUrlFor(row.slug)}/og.png?v=${version}&lang=${encodeURIComponent(translation.language)}`;
}

export function artImageUrlFor(row: Pick<SummaryRow, "slug" | "updatedAt">): string {
  return `${shareUrlFor(row.slug)}/art.png?v=${row.updatedAt.getTime()}`;
}

/**
 * Where a *public* consumer (the web page's `og:image`, crawlers) should fetch the image: straight
 * from the R2 custom domain when configured and the public link is live, otherwise the gated route.
 */
export function publicOgImageUrl(row: Pick<SummaryRow, "slug" | "updatedAt" | "visibility" | "ogImageKey" | "expiresAt">, now = new Date()): string {
  const live = row.visibility === "public" && (row.expiresAt === null || row.expiresAt > now);
  const direct = live && row.ogImageKey ? publicObjectUrl(row.ogImageKey) : null;
  return direct ?? ogImageUrlFor(row);
}

/** Same as `publicOgImageUrl` for the text-free artwork; null when the summary has none. */
export function publicArtImageUrl(row: Pick<SummaryRow, "slug" | "updatedAt" | "visibility" | "artImageKey" | "expiresAt">, now = new Date()): string | null {
  if (!row.artImageKey) return null;
  const live = row.visibility === "public" && (row.expiresAt === null || row.expiresAt > now);
  return (live ? publicObjectUrl(row.artImageKey) : null) ?? artImageUrlFor(row);
}

/** The source as Markdown, for whoever may open the summary; a local file's text only for its owner. */
export function sourceMarkdownFor(row: Pick<SummaryRow, "contentMarkdown" | "sourceType" | "ownerId">, viewerId: string | null): string | null {
  if (!row.contentMarkdown) return null;
  if (row.sourceType === "local" && row.ownerId !== viewerId) return null;
  return row.contentMarkdown;
}

/** How long a document may stay pending; past it the agent's run is presumed lost. */
export const SOURCE_MARKDOWN_PENDING_MS = 6 * 60 * 1000;

/** An empty `contentMarkdown` marks a document the agent is still writing (set when the row is created). */
export function isSourceMarkdownPending(
  row: Pick<SummaryRow, "contentMarkdown" | "sourceType" | "ownerId" | "createdAt">,
  viewerId: string | null,
  now = new Date(),
): boolean {
  if (row.contentMarkdown !== "") return false;
  if (row.sourceType === "local" && row.ownerId !== viewerId) return false;
  return now.getTime() - row.createdAt.getTime() < SOURCE_MARKDOWN_PENDING_MS;
}

/** How long a source translation may stay pending; past it the run is presumed lost and may restart. */
export const SOURCE_TRANSLATION_PENDING_MS = 6 * 60 * 1000;

/** A translation being written ("") is pending until it lands or its run is presumed lost. */
export function isSourceTranslationPending(translation: Pick<SummaryTranslationRow, "contentMarkdown" | "updatedAt"> | null, now = new Date()): boolean {
  if (!translation || translation.contentMarkdown !== "") return false;
  return now.getTime() - translation.updatedAt.getTime() < SOURCE_TRANSLATION_PENDING_MS;
}

/** The text a reader sees: a translation into their language, or the summary as written. */
export interface SummaryReading {
  translation: SummaryTranslationRow | null;
  /** A translation was wanted but is still being written in the background. */
  pending: boolean;
}

export const ORIGINAL_READING: SummaryReading = { translation: null, pending: false };

export function toSummaryJson(row: SummaryRow, viewerId: string | null, viewedAt: Date | null = null, reading: SummaryReading = ORIGINAL_READING): SummaryJson {
  const shareUrl = shareUrlFor(row.slug);
  const { translation } = reading;
  const isOwner = viewerId !== null && viewerId === row.ownerId;
  const hasSourceMarkdown = sourceMarkdownFor(row, viewerId) !== null;
  return {
    id: row.id,
    slug: row.slug,
    shareUrl,
    ogImageUrl: translation && row.artImageKey ? translatedOgImageUrlFor(row, translation) : publicOgImageUrl(row),
    artImageUrl: publicArtImageUrl(row),
    sourceType: row.sourceType,
    source: row.source,
    sourceUrl: row.sourceUrl,
    sourceTitle: row.sourceTitle,
    siteName: siteNameFor(row.siteName, row.sourceUrl),
    sourceFileUrl: row.sourceType === "pdf" && row.sourceFileKey ? `${shareUrl}/source` : null,
    hasSourceMarkdown,
    sourceMarkdownPending: isSourceMarkdownPending(row, viewerId),
    title: translation?.title ?? row.title,
    summary: translation?.summary ?? row.summary,
    highlights: translation?.highlights ?? row.highlights,
    category: row.category,
    tags: row.tags,
    displayCategory: categoryLabel(row.category, translationLanguageFor(translation?.language ?? row.language) ?? "en"),
    displayTags: translation?.tags?.length === row.tags.length ? translation.tags : row.tags,
    keywords: row.keywords,
    language: translation?.language ?? row.language,
    originalLanguage: row.language,
    displayLanguage: isOwner ? row.displayLanguage : null,
    translationPending: reading.pending,
    sourceTranslationPending: hasSourceMarkdown && isSourceTranslationPending(translation),
    theme: { colors: row.theme.colors, mode: row.theme.mode, emoji: row.theme.emoji, accent: row.theme.accent },
    imageStyle: row.imageStyle,
    visibility: row.visibility,
    ttlDays: row.ttlDays,
    expiresAt: row.expiresAt ? row.expiresAt.toISOString() : null,
    viewCount: row.viewCount,
    isOwner,
    viewedAt: viewedAt ? viewedAt.toISOString() : null,
    createdAt: row.createdAt.toISOString(),
    updatedAt: row.updatedAt.toISOString(),
  };
}
