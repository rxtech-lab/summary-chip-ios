import { getAiProvider } from "@/lib/ai/provider";
import { podcastSummarySchema, type DailyPodcast, type PodcastDay } from "@/lib/contracts/daily-podcast";
import type { Database } from "@/lib/db/client";
import { requireFlowcyAccess } from "@/lib/subscription/flowcy";
import { dailyPodcastEpisode, updatePodcastDocument } from "./daily-podcast";
import type { ServiceDeps } from "./summaries";

const pending = new Map<string, Promise<DailyPodcast>>();
/** Backfills only summary metadata. Saved summaries are reused without a model call. */
export async function generatePodcastSummary(db: Database, user: string, day: PodcastDay, key: string, deps: ServiceDeps = {}) {
  const podcast = await dailyPodcastEpisode(db, user, day, key);
  if (podcast.summary?.trim()) return podcast;
  await requireFlowcyAccess(user);
  const lock = `${user}/${key}`;
  const existing = pending.get(lock);
  if (existing) return existing;
  const run = (async () => {
    const ai = deps.ai ?? await getAiProvider();
    const summary = podcastSummarySchema.parse(await ai.writePodcastSummary(podcast, {
      abortSignal: AbortSignal.timeout(90_000),
    }));
    const saved = await updatePodcastDocument(db, user, key, latest => {
      if (!latest.summary?.trim()) latest.summary = summary;
    });
    return saved;
  })().finally(() => pending.delete(lock));
  pending.set(lock, run);
  return run;
}
