import type { SummaryRow } from "@/lib/db/schema";
import type { OgImages } from "@/lib/og/generate";
import { artImageKey, OG_CACHE_CONTROL, ogImageKey, type ObjectStore } from "@/lib/storage/r2";

export type ImageKeys = Pick<SummaryRow, "ogImageKey" | "artImageKey">;

/** Uploads the card (and the text-free art when there is one) under fresh keys. */
export async function storeImages(store: ObjectStore, id: string, timestamp: number, images: OgImages): Promise<ImageKeys> {
  const ogKey = ogImageKey(id, timestamp);
  await store.put(ogKey, { bytes: images.card, contentType: "image/png", cacheControl: OG_CACHE_CONTROL });
  let artKey: string | null = null;
  if (images.art) {
    artKey = artImageKey(id, timestamp);
    try {
      await store.put(artKey, { bytes: images.art, contentType: "image/png", cacheControl: OG_CACHE_CONTROL });
    } catch (error) {
      console.warn("[summaries] art image upload failed", error);
      artKey = null;
    }
  }
  return { ogImageKey: ogKey, artImageKey: artKey };
}

/** Best-effort deletion of R2 objects that are no longer referenced. */
export async function deleteObjects(store: ObjectStore, keys: (string | null)[]): Promise<void> {
  await Promise.all(keys.filter((key): key is string => Boolean(key)).map((key) =>
    store.delete(key).catch((error) => console.warn("[summaries] retired image delete failed", error))));
}

async function copyToFreshKey(store: ObjectStore, from: string, to: string): Promise<string | null> {
  try {
    const object = await store.get(from);
    await store.put(to, { ...object, cacheControl: OG_CACHE_CONTROL });
    return to;
  } catch (error) {
    console.warn("[summaries] image key rotation failed; the old public image URL stays valid", error);
    return null;
  }
}

/**
 * Copies the summary's images to new random keys. `changes` holds the keys that moved; the caller
 * saves them and then deletes `retired`. A copy that failed keeps its old key (and URL).
 */
export async function rotateImageKeys(
  store: ObjectStore,
  row: Pick<SummaryRow, "id"> & ImageKeys,
  now: Date,
): Promise<{ changes: Partial<ImageKeys>; retired: string[] }> {
  const changes: Partial<ImageKeys> = {};
  const retired: string[] = [];
  const [og, art] = await Promise.all([
    row.ogImageKey ? copyToFreshKey(store, row.ogImageKey, ogImageKey(row.id, now.getTime())) : null,
    row.artImageKey ? copyToFreshKey(store, row.artImageKey, artImageKey(row.id, now.getTime())) : null,
  ]);
  if (og && row.ogImageKey) {
    changes.ogImageKey = og;
    retired.push(row.ogImageKey);
  }
  if (art && row.artImageKey) {
    changes.artImageKey = art;
    retired.push(row.artImageKey);
  }
  return { changes, retired };
}

