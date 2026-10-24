import { joinPodcastAudio } from "./podcast-audio";
import { mixPodcast } from "./podcast-mixer";
import { analyzeSpeech } from "./podcast-timing";
import { podcastMusic, type PodcastMusic } from "./podcast-music";
import { createHash, randomUUID } from "node:crypto";
import { and, eq, isNotNull, ne, or, sql, asc } from "drizzle-orm";
import type { LanguageModelUsage } from "ai";
import { getAiProvider } from "@/lib/ai/provider";
import { tourVoice } from "@/lib/ai/models";
import { LANGUAGE_NAMES } from "@/lib/ai/summary-schema";
import { createDailyPodcastSchema, podcastScriptSchema, type DailyPodcast, type PodcastDay } from "@/lib/contracts/daily-podcast";
import type { z } from "zod";
import type { Database } from "@/lib/db/client";
import { summaries, summaryViews } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { getObjectStore, type ObjectStore } from "@/lib/storage/r2";
import { pointsForCost, reservePodcastPoints, usageCostUsd } from "@/lib/subscription/chat-billing";
import { getSummaryForViewer, type ServiceDeps } from "./summaries";
import { readableByViewer } from "./share-access";

function dayKey(user: string, day: PodcastDay) {
  return `daily-podcasts/${createHash("sha256").update(user).digest("hex")}/${createHash("sha256").update(JSON.stringify([Date.parse(day.start), Date.parse(day.end)])).digest("hex")}`;
}
async function read(store: ObjectStore, path: string): Promise<DailyPodcast | null> {
  try { return JSON.parse(new TextDecoder().decode((await store.get(path)).bytes)); }
  catch (error) {
    if (error instanceof ApiError && error.code === "OBJECT_MISSING") return null;
    throw error;
  }
}
async function authorize(db: Database, user: string, podcast: DailyPodcast) {
  for (const id of podcast.chipIds) await getSummaryForViewer(db, id, user);
}
export async function savedDailyPodcast(db: Database, user: string, day: PodcastDay, store = getObjectStore()) {
  const podcast = await read(store, `${dayKey(user, day)}/latest.json`);
  if (podcast) {
    await authorize(db, user, podcast);
    if (!podcast.audioPath) await upgradePodcastAudio(store, user, podcast);
  }
  return podcast;
}

const writing = new Map<string, Promise<DailyPodcast>>();

export async function createDailyPodcast(db: Database, user: string, input: z.infer<typeof createDailyPodcastSchema>, deps: ServiceDeps = {}) {
  const store = deps.store ?? getObjectStore();
  const base = dayKey(user, input.day);
  // Concurrent taps share a generation, even if the second requested regeneration.
  const pending = writing.get(base);
  if (pending) return pending;
  const run = (async () => {
    const saved = input.regenerate ? null : await savedDailyPodcast(db, user, input.day, store);
    if (saved && !input.regenerate) return saved;
    const activity = sql`CASE WHEN ${summaries.ownerId} = ${user} THEN ${summaries.createdAt} ELSE ${summaryViews.viewedAt} END`;
    const chips = await db.select({ chip: summaries }).from(summaries)
      .leftJoin(summaryViews, and(eq(summaryViews.summaryId, summaries.id), eq(summaryViews.userId, user)))
      .where(and(eq(summaries.kind, "summary"),
        or(eq(summaries.ownerId, user), and(ne(summaries.ownerId, user), isNotNull(summaryViews.userId), readableByViewer(user))),
        sql`${activity} >= ${Date.parse(input.day.start)}`, sql`${activity} < ${Date.parse(input.day.end)}`))
      .orderBy(asc(activity), asc(summaries.id)).limit(25);
    if (!chips.length) throw new ApiError(422, "PODCAST_EMPTY", "There are no readable chips for this day.");
    if (chips.length > 24) throw new ApiError(422, "PODCAST_TOO_LARGE", "This day has more than 24 chips. Daily podcasts currently support up to 24.");
    const ai = deps.ai ?? await getAiProvider();
    if (!ai.speechModelId()) throw new ApiError(503, "PODCAST_SPEECH_UNAVAILABLE", "Podcast audio is not available right now.");
    const voices = [...new Set((process.env.AI_PODCAST_VOICES || tourVoice()).split(",").map((v) => v.trim()).filter(Boolean))].slice(0, 4);
    const key = randomUUID();
    const charge = await reservePodcastPoints(user, key, ai.tourModelId(), deps.billingEnvironment);
    const usage: LanguageModelUsage[] = [];
    const deadline = AbortSignal.timeout(270_000);
    try {
      const script = podcastScriptSchema.parse(await ai.writePodcast({ language: LANGUAGE_NAMES[input.language], voices,
        chips: chips.map(({ chip }) => ({ id: chip.id, title: chip.title, summary: chip.summary, highlights: chip.highlights })) },
      { abortSignal: AbortSignal.any([deadline, AbortSignal.timeout(100_000)]), onUsage: (step) => usage.push(step) }));
      if (new Set(script.speakers.map((s) => s.voice)).size !== script.speakers.length || script.speakers.some((s) => !voices.includes(s.voice)) || script.segments.some((s) => s.speaker >= script.speakers.length || !chips.some(({ chip }) => chip.id === s.chipId)) || chips.some(({ chip }) => !script.segments.some((s) => s.chipId === chip.id))) {
        throw new Error("Invalid podcast references");
      }
      // Theme music is shared by mood, so it's usually already stored; failures publish without music.
      const musicTask = podcastMusic(ai, store, script.mood, deadline);
      const segments: DailyPodcast["segments"] = [];
      const audioParts: Uint8Array[] = [];
      // Bound speech concurrency and finish audio before publishing a playable episode.
      for (let start = 0; start < script.segments.length; start += 4) {
        const batch = await Promise.all(script.segments.slice(start, start + 4).map(async (segment, offset) => {
          const audio = await ai.speak(segment.caption, script.speakers[segment.speaker].voice, { abortSignal: deadline });
          audioParts[start + offset] = audio.bytes;
          const chip = chips.find(({ chip }) => chip.id === segment.chipId)!.chip;
          return { ...segment,
            imagePath: chip.artImageKey ? `/s/${chip.slug}/art.png` : null, icon: chip.theme.emoji || "🎙️" };
        }));
        segments.push(...batch);
      }
      const podcast: DailyPodcast = { ...script, segments, key, language: input.language, day: input.day,
        chipIds: chips.map(({ chip }) => chip.id), createdAt: (deps.now?.() ?? new Date()).toISOString() };
      const music = await musicTask;
      await storeContinuousAudio(store, user, podcast, audioParts, music);
      await authorize(db, user, podcast);
      const pricing = charge ? await ai.tourPricing() : null;
      const textCost = pricing ? usage.reduce((sum, step) => sum + usageCostUsd(step, pricing), 0) : 0;
      const speechCost = segments.reduce((sum, s) => sum + s.caption.length, 0) * ai.speechUsdPerCharacter();
      const musicCost = (music?.generatedClips ?? 0) * ai.musicUsdPerClip();
      const object = { bytes: new TextEncoder().encode(JSON.stringify(podcast)), contentType: "application/json", cacheControl: "private, no-store" };
      await store.put(`${base}/${key}.json`, object);
      await store.put(`${base}/latest.json`, object);
      await charge?.settle(Math.max(1, pointsForCost(textCost + speechCost + musicCost)), { segments: segments.length, textCostUsd: textCost, speechCostUsd: speechCost, musicCostUsd: musicCost });
      return podcast;
    } catch (error) {
      await charge?.settle(0, { failed: true });
      if (error instanceof ApiError) throw error;
      console.error("[podcast] generation failed", error);
      throw new ApiError(502, "PODCAST_FAILED", "The podcast could not be generated. Please try again.");
    }
  })().finally(() => writing.delete(base));
  writing.set(base, run);
  return run;
}

export async function dailyPodcastAudio(db: Database, user: string, day: PodcastDay, key: string, index: number, store = getObjectStore()) {
  if (!/^[0-9a-f-]{36}$/.test(key) || !Number.isInteger(index) || index < 0) throw new ApiError(404, "NOT_FOUND", "Podcast segment not found");
  const base = dayKey(user, day);
  const podcast = await read(store, `${base}/${key}.json`);
  if (!podcast?.segments[index]) throw new ApiError(404, "NOT_FOUND", "Podcast segment not found");
  await authorize(db, user, podcast);
  return store.get(`${base}/${key}/${index}.mp3`);
}

function episodeAudioPath(podcast: DailyPodcast) {
  return `/api/v1/daily-podcasts/${podcast.key}/audio?${new URLSearchParams(podcast.day)}`;
}
async function storeContinuousAudio(store: ObjectStore, user: string, podcast: DailyPodcast, parts: Uint8Array[], music: PodcastMusic | null = null) {
  let joined: { bytes: Uint8Array; cues: { startSeconds: number; endSeconds: number }[]; durationSeconds: number } | null = null;
  if (music) {
    try { joined = await mixPodcast(parts.map((bytes, index) => ({ bytes, topic: podcast.segments[index].chipId })), music); }
    catch (error) { console.error("[podcast] music mix failed, publishing voices only", error); }
  }
  podcast.music = Boolean(joined);
  joined ??= joinPodcastAudio(parts);
  await store.put(`${dayKey(user, podcast.day)}/${podcast.key}/audio.mp3`, { bytes: joined.bytes, contentType: "audio/mpeg", cacheControl: "private, no-store" });
  podcast.audioPath = episodeAudioPath(podcast);
  podcast.durationSeconds = joined.durationSeconds;
  const timings = await analyzeSpeech(parts);
  podcast.segments = podcast.segments.map((segment, index) => {
    const cue = joined.cues[index];
    const timing = timings[index];
    const at = (seconds: number) => Math.round(Math.min(cue.endSeconds, cue.startSeconds + seconds) * 100) / 100;
    return { ...segment, ...cue, ...(timing && { voiceStartSeconds: at(timing.voiceStart), voiceEndSeconds: at(timing.voiceEnd),
      pauseSeconds: timing.pauses.map(at) }) };
  });
}
async function upgradePodcastAudio(store: ObjectStore, user: string, podcast: DailyPodcast) {
  const base = dayKey(user, podcast.day);
  const parts = await Promise.all(podcast.segments.map((_, index) => store.get(`${base}/${podcast.key}/${index}.mp3`).then((object) => object.bytes)));
  await storeContinuousAudio(store, user, podcast, parts);
  const object = { bytes: new TextEncoder().encode(JSON.stringify(podcast)), contentType: "application/json", cacheControl: "private, no-store" };
  await store.put(`${base}/${podcast.key}.json`, object);
  // Only update latest when it still names this episode.
  if ((await read(store, `${base}/latest.json`))?.key === podcast.key) await store.put(`${base}/latest.json`, object);
}
export async function dailyPodcastEpisode(db: Database, user: string, day: PodcastDay, key: string, store = getObjectStore()) {
  if (!/^[0-9a-f-]{36}$/.test(key)) throw new ApiError(404, "NOT_FOUND", "Podcast not found");
  const base = dayKey(user, day);
  const podcast = await read(store, `${base}/${key}.json`);
  if (!podcast) throw new ApiError(404, "NOT_FOUND", "Podcast not found");
  await authorize(db, user, podcast);
  if (!podcast.audioPath) await upgradePodcastAudio(store, user, podcast);
  return podcast;
}
export async function dailyPodcastRecording(db: Database, user: string, day: PodcastDay, key: string, store = getObjectStore()) {
  await dailyPodcastEpisode(db, user, day, key, store);
  return store.get(`${dayKey(user, day)}/${key}/audio.mp3`);
}
