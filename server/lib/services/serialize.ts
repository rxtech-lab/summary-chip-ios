import { siteUrl } from "@/lib/config";
import { publicObjectUrl } from "@/lib/storage/r2";
import type { ImageStyle, SourceType, SummaryRow, SummarySource, SummaryTheme, Visibility } from "@/lib/db/schema";

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
  title: string;
  summary: string;
  highlights: string[];
  category: string;
  tags: string[];
  keywords: string[];
  language: string;
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

export function toSummaryJson(row: SummaryRow, viewerId: string | null, viewedAt: Date | null = null): SummaryJson {
  const shareUrl = shareUrlFor(row.slug);
  return {
    id: row.id,
    slug: row.slug,
    shareUrl,
    ogImageUrl: publicOgImageUrl(row),
    artImageUrl: publicArtImageUrl(row),
    sourceType: row.sourceType,
    source: row.source,
    sourceUrl: row.sourceUrl,
    sourceTitle: row.sourceTitle,
    siteName: row.siteName,
    sourceFileUrl: row.sourceType === "pdf" && row.sourceFileKey ? `${shareUrl}/source` : null,
    title: row.title,
    summary: row.summary,
    highlights: row.highlights,
    category: row.category,
    tags: row.tags,
    keywords: row.keywords,
    language: row.language,
    theme: { colors: row.theme.colors, mode: row.theme.mode, emoji: row.theme.emoji, accent: row.theme.accent },
    imageStyle: row.imageStyle,
    visibility: row.visibility,
    ttlDays: row.ttlDays,
    expiresAt: row.expiresAt ? row.expiresAt.toISOString() : null,
    viewCount: row.viewCount,
    isOwner: viewerId !== null && viewerId === row.ownerId,
    viewedAt: viewedAt ? viewedAt.toISOString() : null,
    createdAt: row.createdAt.toISOString(),
    updatedAt: row.updatedAt.toISOString(),
  };
}
