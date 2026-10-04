import { getDatabase } from "@/lib/db/client";
import { serveSummaryImage } from "@/lib/http/summary-image";
import { translatedCoverKey } from "@/lib/services/covers";
import { translationLanguageFor } from "@/lib/services/translations";
import { getObjectStore } from "@/lib/storage/r2";

export const runtime = "nodejs";

/**
 * The 1200×630 OG image (see `serveSummaryImage` for access and caching). `?lang=` asks for the
 * cover with its headline in a language the summary was translated into; without a translation
 * (or art to draw it on) it is the original.
 */
export async function GET(request: Request, { params }: { params: Promise<{ slug: string }> }) {
  const language = translationLanguageFor(new URL(request.url).searchParams.get("lang"));
  return serveSummaryImage(request, params, async (row) => {
    if (language && translationLanguageFor(row.language) !== language) {
      const key = await translatedCoverKey(getDatabase(), getObjectStore(), row, language).catch((error) => {
        console.warn("[og] translated cover failed; serving the original", error);
        return null;
      });
      if (key) return key;
    }
    return row.ogImageKey;
  });
}
