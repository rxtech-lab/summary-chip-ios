import { createHash } from "node:crypto";
import { and, eq } from "drizzle-orm";
import type { TranslationLanguage } from "@/lib/contracts/api";
import type { Database } from "@/lib/db/client";
import { summaryTranslations, type SummaryRow } from "@/lib/db/schema";
import { categoryLabel } from "@/lib/og/category-labels";
import { renderOgPng, type OgCardInput } from "@/lib/og/render";
import { OG_CACHE_CONTROL, type ObjectStore } from "@/lib/storage/r2";
import { siteLabelFor } from "./summaries";
import { findTranslation } from "./translations";

/** Bump to redraw every translated cover (e.g. after changing the card template). */
const COVER_VERSION = 1;

/**
 * The key of the summary's cover with its headline in `language`: the stored text-free art with
 * the translation's headline laid over it, drawn on first request and kept until anything on it
 * changes. Null when there is no art or no translation yet (serve the original cover then).
 *
 * The key hashes the art's key, which is random and rotates with it, so it stays unguessable on
 * the public bucket domain and a rotated, redrawn or edited cover gets a fresh key.
 */
export async function translatedCoverKey(db: Database, store: ObjectStore, row: SummaryRow, language: TranslationLanguage): Promise<string | null> {
  if (!row.artImageKey) return null;
  const translation = await findTranslation(db, row.id, language);
  if (!translation) return null;
  const card: Omit<OgCardInput, "image" | "svg"> = {
    headline: translation.headline || translation.title,
    category: categoryLabel(row.category, language),
    siteLabel: siteLabelFor(row),
    colors: row.theme.colors,
    mode: row.theme.mode,
    accent: row.theme.accent,
    language,
  };
  const digest = createHash("sha256").update(JSON.stringify([COVER_VERSION, row.artImageKey, card])).digest("hex").slice(0, 24);
  const key = `og/${row.id}-${language}-${digest}.png`;
  if (translation.ogImageKey === key) return key;

  let art: Uint8Array;
  try {
    art = (await store.get(row.artImageKey)).bytes;
  } catch (error) {
    console.warn("[covers] art image unavailable; serving the original cover", error);
    return null;
  }
  await store.put(key, { bytes: await renderOgPng({ ...card, image: art }), contentType: "image/png", cacheControl: OG_CACHE_CONTROL });
  await db.update(summaryTranslations).set({ ogImageKey: key })
    .where(and(eq(summaryTranslations.summaryId, row.id), eq(summaryTranslations.language, language)));
  if (translation.ogImageKey) {
    await store.delete(translation.ogImageKey).catch((error) => console.warn("[covers] stale cover delete failed", error));
  }
  return key;
}
