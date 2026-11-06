import { isLinkLive } from "@/lib/services/share-access";
import { and, eq } from "drizzle-orm";
import { z } from "zod";
import { getDatabase } from "@/lib/db/client";
import { marketplacePublications, podcastEpisodes, summaries } from "@/lib/db/schema";
import { withApiAuth } from "@/lib/http/handler";
import { ApiError, errorResponse, noStoreJson, readJson } from "@/lib/http/errors";
import { listMarketplace, listOwnPublications, refreshAuthorName } from "@/lib/services/marketplace";
const input = z.object({ summaryId: z.string().min(1).max(200).optional(), podcastKey: z.string().min(1).max(1000).optional() }).refine(value => Boolean(value.summaryId) !== Boolean(value.podcastKey), "Choose one content item");
const offsetInput = z.coerce.number().int().min(0).max(100000);
export async function GET(request: Request) {
  const query = new URL(request.url).searchParams;
  if (query.get("scope") === "mine") {
    return withApiAuth(request, async ({ db, principal }) => {
      const offset = offsetInput.parse(query.get("offset") ?? 0);
      await refreshAuthorName(db, principal.sub, request.headers.get("authorization") ?? "");
      const items = await listOwnPublications(db, principal.sub, offset);
      return noStoreJson({ items, nextOffset: items.length === 50 ? offset + 50 : null });
    });
  }
  try {
    const offset = offsetInput.parse(query.get("offset") ?? 0);
    const items = await listMarketplace(getDatabase(), query.get("author") ?? undefined, offset);
    return noStoreJson({ items, nextOffset: items.length === 50 ? offset + 50 : null });
  } catch (error) { return errorResponse(error); }
}
export async function POST(request: Request) {
  return withApiAuth(request, async ({ db, principal }) => {
    const content = await readJson(request, body => input.parse(body));
    await db.transaction(async tx => {
      let summaryId = content.summaryId;
      if (content.podcastKey) {
        const [episode] = await tx.select().from(podcastEpisodes).where(and(eq(podcastEpisodes.key, content.podcastKey), eq(podcastEpisodes.ownerId, principal.sub), eq(podcastEpisodes.deleted, false)));
        if (!episode) throw new ApiError(404, "NOT_FOUND", "Podcast not found");
        summaryId = episode.summaryId ?? crypto.randomUUID();
        if (!episode.summaryId) {
          const podcast = episode.document;
          await tx.insert(summaries).values({ id: summaryId, slug: crypto.randomUUID(), ownerId: principal.sub, kind: "podcast", sourceType: "text", source: "text", title: podcast.title, summary: podcast.title, highlights: [], category: "Other", tags: [], keywords: [], language: podcast.language, theme: { colors: ["#242354"], mode: "dark", emoji: "🎙️", accent: "#7566b0" }, visibility: "public" });
          await tx.update(podcastEpisodes).set({ summaryId, isDefault: true, document: { ...podcast, summaryId } }).where(eq(podcastEpisodes.key, episode.key));
        }
      }
      if (!summaryId) throw new ApiError(400, "INVALID_CONTENT", "Choose content");
      const [owned] = await tx.select({ id: summaries.id }).from(summaries)
        .where(and(eq(summaries.id, summaryId), eq(summaries.ownerId, principal.sub)));
      if (!owned) throw new ApiError(404, "NOT_FOUND", "Content not found");
      const episodes = await tx.select().from(podcastEpisodes).where(and(eq(podcastEpisodes.summaryId, summaryId), eq(podcastEpisodes.isDefault, true), eq(podcastEpisodes.deleted, false)));
      for (const episode of episodes) {
        for (const id of episode.document.chipIds) {
          const [source] = await tx.select().from(summaries).where(eq(summaries.id, id));
          if (!source || (source.ownerId !== principal.sub && !isLinkLive(source))) throw new ApiError(403, "PODCAST_SOURCE_PRIVATE", "This episode includes unavailable or privately shared content");
        }
      }
      await tx.update(summaries).set({ visibility: "public", expiresAt: null, ttlDays: null, updatedAt: new Date() }).where(eq(summaries.id, summaryId));
      await tx.insert(marketplacePublications).values({ summaryId }).onConflictDoNothing();
    });
    await refreshAuthorName(db, principal.sub, request.headers.get("authorization") ?? "");
    return noStoreJson({ published: true });
  });
}
export async function DELETE(request: Request) {
  return withApiAuth(request, async ({ db, principal }) => {
    const content = await readJson(request, body => input.parse(body));
    let summaryId = content.summaryId;
    if (content.podcastKey) {
      const [episode] = await db.select().from(podcastEpisodes).where(and(eq(podcastEpisodes.key, content.podcastKey), eq(podcastEpisodes.ownerId, principal.sub)));
      summaryId = episode?.summaryId ?? undefined;
    }
    if (!summaryId) throw new ApiError(404, "NOT_FOUND", "Published content not found");
    await db.delete(marketplacePublications).where(and(eq(marketplacePublications.summaryId, summaryId),
      eq(marketplacePublications.summaryId, db.select({ id: summaries.id }).from(summaries).where(and(eq(summaries.id, summaryId), eq(summaries.ownerId, principal.sub))))));
    return noStoreJson({ published: false });
  });
}
