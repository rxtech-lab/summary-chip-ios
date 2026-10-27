import { randomUUID } from "node:crypto";
import type { LanguageModelUsage } from "ai";
import { getAiProvider } from "@/lib/ai/provider";
import { podcastSummarySchema, type DailyPodcast, type PodcastDay } from "@/lib/contracts/daily-podcast";
import type { Database } from "@/lib/db/client";
import { dailyPodcastEpisode, updatePodcastDocument } from "./daily-podcast";
import type { ServiceDeps } from "./summaries";
import { pointsForCost, reservePodcastPoints, usageCostUsd } from "@/lib/subscription/chat-billing";

const pending = new Map<string, Promise<DailyPodcast>>();
/** Backfills only summary metadata. Saved summaries are reused without a model call. */
export async function generatePodcastSummary(db: Database, user: string, day: PodcastDay, key: string, deps: ServiceDeps = {}) {
  const podcast = await dailyPodcastEpisode(db, user, day, key);
  if (podcast.summary?.trim()) return podcast;
  const lock = `${user}/${key}`;
  const existing = pending.get(lock);
  if (existing) return existing;
  const run = (async () => {
    const ai = deps.ai ?? await getAiProvider();
    const charge = await reservePodcastPoints(user, `${key}:summary:${randomUUID()}`, ai.podcastModelId(), deps.billingEnvironment);
    const usage: LanguageModelUsage[] = [];
    try {
      const summary = podcastSummarySchema.parse(await ai.writePodcastSummary(podcast, {
        abortSignal: AbortSignal.timeout(90_000), onUsage: step => usage.push(step),
      }));
      const saved = await updatePodcastDocument(db, user, key, latest => {
        if (!latest.summary?.trim()) latest.summary = summary;
      });
      const pricing = charge ? await ai.podcastPricing() : null;
      const cost = pricing ? usage.reduce((sum, step) => sum + usageCostUsd(step, pricing), 0) : 0;
      await charge?.settle(Math.max(1, pointsForCost(cost)), { summary: true, textCostUsd: cost });
      return saved;
    } catch (error) {
      await charge?.settle(0, { failed: true });
      throw error;
    }
  })().finally(() => pending.delete(lock));
  pending.set(lock, run);
  return run;
}
