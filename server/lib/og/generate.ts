import type { AiProvider } from "@/lib/ai/provider";
import type { ImageStyle, SummaryKind, SummaryTheme } from "@/lib/db/schema";
import { fallbackSvg } from "./fallback-svg";
import { renderArtPng, renderOgPng } from "./render";
import { sanitizeSvg } from "./sanitize-svg";

export interface OgSubject {
  id: string;
  headline: string;
  summary: string;
  category: string;
  keywords: string[];
  theme: SummaryTheme;
  siteLabel: string | null;
  language: string;
  kind?: SummaryKind;
}

export interface OgImages {
  /** The finished 1200×630 social card, headline and all. */
  card: Uint8Array;
  /** The same artwork without any text; null when it could not be produced. */
  art: Uint8Array | null;
}

/**
 * Produces the PNGs for a summary. Artwork never carries text (image models garble it, CJK
 * especially); the headline is always laid out by the card template on top. "illustration" has the
 * image model draw the artwork and falls back to "graphic" when it is unavailable; "graphic" asks
 * the text model for decorative SVG, sanitises it, and falls back to generated art. The art version
 * is the same background without the text.
 */
export async function generateOgImages(subject: OgSubject, imageStyle: ImageStyle, ai: AiProvider): Promise<OgImages> {
  const design = {
    title: subject.headline,
    headline: subject.headline,
    summary: subject.summary,
    category: subject.category,
    keywords: subject.keywords,
    colors: subject.theme.colors,
    mode: subject.theme.mode,
    siteLabel: subject.siteLabel,
    language: subject.language,
    kind: subject.kind,
  };
  const card = {
    headline: subject.headline,
    category: subject.category,
    siteLabel: subject.siteLabel,
    colors: subject.theme.colors,
    mode: subject.theme.mode,
    accent: subject.theme.accent,
    language: subject.language,
  };
  if (imageStyle === "illustration") {
    const art = await ai.illustrate(design);
    if (art) return { card: await renderOgPng({ ...card, image: art }), art };
  }
  const svg = sanitizeSvg(await ai.designSvg(design)) ?? fallbackSvg(subject.id, subject.theme.colors, subject.theme.mode);
  const [cardPng, art] = await Promise.all([
    renderOgPng({ ...card, svg }),
    renderArtPng({ colors: subject.theme.colors, svg }).catch((error) => {
      console.warn("[og] art render failed", error);
      return null;
    }),
  ]);
  return { card: cardPng, art };
}
