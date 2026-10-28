import { and, eq, isNotNull, sql } from "drizzle-orm";
import type { Database } from "@/lib/db/client";
import { podcastEpisodes, summaries } from "@/lib/db/schema";
import type { SummaryJson } from "./serialize";

/**
 * A podcast chip whose saved versions all speak about one and the same chip. The app stacks it on
 * that chip (feed card, play button on the chip's cover), and it is never an editor's pick of its own.
 */
export const isSoloPodcast = sql`(${summaries.kind} = 'podcast' AND (
  SELECT COUNT(DISTINCT chip.value) FROM ${podcastEpisodes}, json_each(${podcastEpisodes.document}, '$.chipIds') AS chip
  WHERE ${podcastEpisodes.summaryId} = ${summaries.id} AND ${podcastEpisodes.deleted} = 0) = 1)`;
export const isNotSoloPodcast = sql`NOT ${isSoloPodcast}`;

/** The owner's solo podcast chips: each one's source chip, and the newest podcast stacked on each chip. */
export async function soloPodcastLinks(db: Database, ownerId: string) {
  const episodes = await db.select({
    podcastId: podcastEpisodes.summaryId,
    chipIds: sql<string | null>`json_extract(${podcastEpisodes.document}, '$.chipIds')`,
    createdAt: sql<string | null>`json_extract(${podcastEpisodes.document}, '$.createdAt')`,
  }).from(podcastEpisodes).where(and(eq(podcastEpisodes.ownerId, ownerId), eq(podcastEpisodes.deleted, false),
    isNotNull(podcastEpisodes.summaryId)));
  const chips = new Map<string, Set<string>>();
  const latest = new Map<string, string>();
  for (const episode of episodes) {
    if (!episode.podcastId) continue;
    const ids = chips.get(episode.podcastId) ?? new Set<string>();
    for (const id of JSON.parse(episode.chipIds ?? "[]") as string[]) ids.add(id);
    chips.set(episode.podcastId, ids);
    const createdAt = episode.createdAt ?? "";
    if (createdAt > (latest.get(episode.podcastId) ?? "")) latest.set(episode.podcastId, createdAt);
  }
  const sourceOf = new Map<string, string>();
  const podcastOf = new Map<string, string>();
  for (const [podcastId, ids] of chips) {
    if (ids.size !== 1) continue;
    const [chipId] = ids;
    sourceOf.set(podcastId, chipId);
    const current = podcastOf.get(chipId);
    if (!current || (latest.get(podcastId) ?? "") > (latest.get(current) ?? "")) podcastOf.set(chipId, podcastId);
  }
  return { sourceOf, podcastOf };
}

/** Fills `podcastSourceId`/`stackedPodcastId` on the viewer's own items; others' items stay unstacked. */
export async function withPodcastStacks<T extends SummaryJson>(db: Database, viewerId: string | null, items: T[]): Promise<T[]> {
  if (!viewerId || !items.some((item) => item.isOwner)) return items;
  const { sourceOf, podcastOf } = await soloPodcastLinks(db, viewerId);
  return items.map((item) => !item.isOwner ? item : {
    ...item,
    podcastSourceId: item.kind === "podcast" ? sourceOf.get(item.id) ?? null : null,
    stackedPodcastId: item.kind === "podcast" ? null : podcastOf.get(item.id) ?? null,
  });
}
