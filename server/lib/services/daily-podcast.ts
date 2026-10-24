import { joinPodcastAudio } from "./podcast-audio";
import { mixPodcast } from "./podcast-mixer";
import { alignPodcastCaptions } from "./podcast-captions";
import { podcastMusic, type PodcastMusic } from "./podcast-music";
import { composePodcastVideo, storePodcastVideo } from "./podcast-video";
import { createHash, randomUUID } from "node:crypto";
import { and, eq, inArray, isNotNull, ne, or, sql, asc } from "drizzle-orm";
import type { LanguageModelUsage } from "ai";
import { getAiProvider } from "@/lib/ai/provider";
import { tourVoice } from "@/lib/ai/models";
import { LANGUAGE_NAMES } from "@/lib/ai/summary-schema";
import { createDailyPodcastSchema, podcastScriptSchema, type DailyPodcast, type PodcastDay, type PodcastProgress } from "@/lib/contracts/daily-podcast";
import type { z } from "zod";
import type { Database } from "@/lib/db/client";
import { summaries, summaryViews, podcastEpisodes, podcastShareLinks } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { getObjectStore, type ObjectStore } from "@/lib/storage/r2";
import { pointsForCost, reservePodcastPoints, usageCostUsd } from "@/lib/subscription/chat-billing";
import { getSummaryForViewer, type ServiceDeps } from "./summaries";
import { readableByViewer } from "./share-access";

export function dayKey(user: string, day: PodcastDay) {
  return `daily-podcasts/${createHash("sha256").update(user).digest("hex")}/${createHash("sha256").update(JSON.stringify([Date.parse(day.start), Date.parse(day.end)])).digest("hex")}`;
}
function sourceIds(podcast: DailyPodcast) {
  return podcast.summaryId ? [...podcast.chipIds, podcast.summaryId] : podcast.chipIds;
}
async function readableSources(db: Database, user: string, podcasts: DailyPodcast[]) {
  const ids = [...new Set(podcasts.flatMap(sourceIds))];
  const readable = new Set<string>();
  // Keep bind counts bounded even for a large version history.
  for (let start = 0; start < ids.length; start += 100) {
    const rows = await db.select({ id: summaries.id }).from(summaries).where(and(
      inArray(summaries.id, ids.slice(start, start + 100)),
      or(eq(summaries.ownerId, user), readableByViewer(user)),
    ));
    for (const row of rows) readable.add(row.id);
  }
  return readable;
}
async function authorize(db: Database, user: string, podcast: DailyPodcast) {
  const readable = await readableSources(db, user, [podcast]);
  if (sourceIds(podcast).some((id) => !readable.has(id))) throw new ApiError(404, "NOT_FOUND", "Podcast source not found");
}
export async function savedDailyPodcast(db: Database, user: string, day: PodcastDay) {
  const [row] = await db.select().from(podcastEpisodes).where(and(dayCondition(user, day),
    eq(podcastEpisodes.isDefault, true), eq(podcastEpisodes.deleted, false), sql`${podcastEpisodes.summaryId} IS NULL`)).limit(1);
  if (!row) return null;
  await authorize(db, user, row.document);
  return row.document;
}

type ProgressListener = (progress: PodcastProgress) => void;
const writing = new Map<string, { promise: Promise<DailyPodcast>; listeners: Set<ProgressListener>; latest: PodcastProgress }>();

export async function createDailyPodcast(db: Database, user: string, input: z.infer<typeof createDailyPodcastSchema>, deps: ServiceDeps = {}, onProgress?: ProgressListener) {
  const store = deps.store ?? getObjectStore();
  const base = dayKey(user, input.day);
  const requestKey = `${base}/${JSON.stringify([input.library, input.chipIds && [...new Set(input.chipIds)].sort(), input.language, input.includeVideo !== false])}`;
  // Concurrent taps share a generation, even if the second requested regeneration.
  const pending = writing.get(requestKey);
  if (pending) {
    if (onProgress) { pending.listeners.add(onProgress); onProgress(pending.latest); }
    try { return await pending.promise; }
    finally { if (onProgress) pending.listeners.delete(onProgress); }
  }
  const state = { promise: undefined as unknown as Promise<DailyPodcast>, listeners: new Set<ProgressListener>(),
    latest: { stage: "preparing", percent: 0 } as PodcastProgress };
  if (onProgress) state.listeners.add(onProgress);
  const report = (stage: PodcastProgress["stage"], percent: number, completedSegments?: number, totalSegments?: number) => {
    state.latest = { stage, percent, completedSegments, totalSegments };
    // A disconnected observer must never fail generation or billing.
    for (const listener of state.listeners) { try { listener(state.latest); } catch { state.listeners.delete(listener); } }
  };
  report("preparing", 0);
  const run = (async () => {
    const saved = input.regenerate || input.library || input.chipIds ? null : await savedDailyPodcast(db, user, input.day);
    if (saved && !input.regenerate) { report("complete", 100); return saved; }
    let chips = input.library
      ? (await Promise.all([...new Set(input.chipIds ?? [])].map(async (id) => ({ chip: await getSummaryForViewer(db, id, user) }))))
      : await dailyPodcastChips(db, user, input.day);
    if (input.chipIds) {
      const wanted = new Set(input.chipIds);
      chips = chips.filter(({ chip }) => wanted.has(chip.id));
      if (chips.length !== wanted.size) throw new ApiError(422, "PODCAST_SELECTION", "Some selected chips are no longer available for this day.");
    }
    if (chips.some(({ chip }) => chip.kind !== "summary")) throw new ApiError(422, "PODCAST_SELECTION", "Select source summary chips only.");
    if (!chips.length) throw new ApiError(422, "PODCAST_EMPTY", "There are no readable chips for this day.");
    const ai = deps.ai ?? await getAiProvider();
    if (!ai.speechModelId()) throw new ApiError(503, "PODCAST_SPEECH_UNAVAILABLE", "Podcast audio is not available right now.");
    const voices = [...new Set((process.env.AI_PODCAST_VOICES || tourVoice()).split(",").map((v) => v.trim()).filter(Boolean))].slice(0, 4);
    const key = randomUUID();
    const charge = await reservePodcastPoints(user, key, ai.tourModelId(), deps.billingEnvironment);
    const usage: LanguageModelUsage[] = [];
    const deadline = AbortSignal.timeout(270_000);
    const failed = new AbortController();
    try {
      report("script", 5);
      const script = podcastScriptSchema.parse(await ai.writePodcast({ language: LANGUAGE_NAMES[input.language], voices,
        chips: chips.map(({ chip }) => ({ id: chip.id, title: chip.title, summary: chip.summary, highlights: chip.highlights })) },
      { abortSignal: AbortSignal.any([deadline, AbortSignal.timeout(100_000)]), onUsage: (step) => usage.push(step) }));
      if (new Set(script.speakers.map((s) => s.voice)).size !== script.speakers.length || script.speakers.some((s) => !voices.includes(s.voice)) || script.segments.some((s) => s.speaker >= script.speakers.length || !chips.some(({ chip }) => chip.id === s.chipId)) || chips.some(({ chip }) => !script.segments.some((s) => s.chipId === chip.id))) {
        throw new Error("Invalid podcast references");
      }
      // Theme music is shared by mood, so it's usually already stored; failures publish without music.
      const musicTask = podcastMusic(ai, store, script.mood, deadline);
      // The motion video only needs the script; real timings reach it on device. Failures publish without video.
      const videoUsage: LanguageModelUsage[] = [];
      let waitingForVideo = false;
      let videoProgress = 0;
      const videoTask = input.includeVideo === false ? Promise.resolve(null) : composePodcastVideo(ai, { ...script, language: input.language }, chips.map(({ chip }) => ({ id: chip.id, title: chip.title })),
        AbortSignal.any([deadline, failed.signal, AbortSignal.timeout(200_000)]), (step) => {
          videoUsage.push(step);
        }, (percent) => {
          videoProgress = percent;
          if (waitingForVideo) report("video-design", 85 + Math.floor(videoProgress * 0.1));
        });
      const segments: DailyPodcast["segments"] = [];
      const audioParts: Uint8Array[] = [];
      let completedSegments = 0;
      report("speech", 20, 0, script.segments.length);
      // Bound speech concurrency and finish audio before publishing a playable episode.
      for (let start = 0; start < script.segments.length; start += 4) {
        const batch = await Promise.all(script.segments.slice(start, start + 4).map(async (segment, offset) => {
          const audio = await ai.speak(segment.caption, script.speakers[segment.speaker].voice, { abortSignal: deadline });
          audioParts[start + offset] = audio.bytes;
          const captionCues = alignPodcastCaptions(segment.caption, await ai.transcribePodcast(audio.bytes, { abortSignal: deadline }));
          completedSegments += 1;
          report("speech", 20 + Math.floor(50 * completedSegments / script.segments.length), completedSegments, script.segments.length);
          const chip = chips.find(({ chip }) => chip.id === segment.chipId)!.chip;
          return { ...segment, captionCues,
            imagePath: chip.artImageKey ? `/s/${chip.slug}/art.png` : null, icon: chip.theme.emoji || "🎙️" };
        }));
        segments.push(...batch);
      }
      const podcast: DailyPodcast = { ...script, segments, key, language: input.language, day: input.day,
        chipIds: chips.map(({ chip }) => chip.id), createdAt: (deps.now?.() ?? new Date()).toISOString() };
      report("music", 70);
      const music = await musicTask;
      report("mixing", 75);
      await storeContinuousAudio(store, user, podcast, audioParts, music);
      waitingForVideo = true;
      if (input.includeVideo !== false) report("video-design", 85 + Math.floor(videoProgress * 0.1));
      const video = await videoTask;
      if (video) podcast.video = await storePodcastVideo(store, `${base}/${key}`, video);
      report("saving", 95);
      await authorize(db, user, podcast);
      const pricing = charge ? await ai.tourPricing() : null;
      const textCost = pricing ? usage.reduce((sum, step) => sum + usageCostUsd(step, pricing), 0) : 0;
      const speechCost = segments.reduce((sum, s) => sum + s.caption.length, 0) * ai.speechUsdPerCharacter();
      const musicCost = (music?.generatedClips ?? 0) * ai.musicUsdPerClip();
      const videoPricing = charge && videoUsage.length ? await ai.podcastVideoPricing() : null;
      const videoCost = videoPricing ? videoUsage.reduce((sum, step) => sum + usageCostUsd(step, videoPricing), 0) : 0;
      // Publish the playable recording before making a chip visible in the library.
      if (input.library) podcast.summaryId = randomUUID();
      const episodeInsert = db.insert(podcastEpisodes).values({ key, ownerId: user,
        dayStart: Date.parse(input.day.start), dayEnd: Date.parse(input.day.end), document: podcast,
        summaryId: podcast.summaryId ?? null });
      if (podcast.summaryId) {
        const now = deps.now?.() ?? new Date();
        await db.batch([db.insert(summaries).values({ id: podcast.summaryId, slug: randomUUID(), ownerId: user,
          kind: "podcast", sourceType: "text", source: "text", title: podcast.title,
          summary: podcast.segments.map((s) => s.caption).join(" ").slice(0, 1200), highlights: [],
          category: "Other", tags: [], keywords: [], language: input.language,
          theme: { colors: ["#242354", "#7566b0"], mode: "dark", emoji: "🎙️", accent: "#7566b0" },
          visibility: "private", createdAt: now, updatedAt: now }), episodeInsert]);
      } else { await episodeInsert; }
      if (!input.library) await selectDailyPodcast(db, user, input.day, key);
      await charge?.settle(Math.max(1, pointsForCost(textCost + speechCost + musicCost + videoCost)), { segments: segments.length, textCostUsd: textCost, speechCostUsd: speechCost, musicCostUsd: musicCost, videoCostUsd: videoCost });
      report("complete", 100);
      return podcast;
    } catch (error) {
      failed.abort();
      await charge?.settle(0, { failed: true });
      if (error instanceof ApiError) throw error;
      console.error("[podcast] generation failed", error);
      throw new ApiError(502, "PODCAST_FAILED", "The podcast could not be generated. Please try again.");
    }
  })().finally(() => writing.delete(requestKey));
  state.promise = run;
  writing.set(requestKey, state);
  return run;
}

export async function dailyPodcastAudio(db: Database, user: string, day: PodcastDay, key: string, index: number, store = getObjectStore()) {
  if (!/^[0-9a-f-]{36}$/.test(key) || !Number.isInteger(index) || index < 0) throw new ApiError(404, "NOT_FOUND", "Podcast segment not found");
  const base = dayKey(user, day);
  const podcast = await dailyPodcastEpisode(db, user, day, key);
  if (!podcast.segments[index]) throw new ApiError(404, "NOT_FOUND", "Podcast segment not found");
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
  podcast.segments = podcast.segments.map((segment, index) => {
    const cue = joined.cues[index];
    const at = (seconds: number) => Math.round(Math.min(cue.endSeconds, cue.startSeconds + seconds) * 100) / 100;
    const captionCues = segment.captionCues?.map((caption) => ({ ...caption,
      startSeconds: at(caption.startSeconds), endSeconds: at(caption.endSeconds) }));
    if (!captionCues?.length || captionCues.some((caption) => caption.endSeconds <= caption.startSeconds)) {
      throw new Error("Invalid podcast caption timestamps");
    }
    return { ...segment, ...cue, captionCues, voiceStartSeconds: captionCues[0].startSeconds,
      voiceEndSeconds: captionCues[captionCues.length - 1].endSeconds };
  });
}
export async function dailyPodcastEpisode(db: Database, user: string, day: PodcastDay, key: string) {
  if (!/^[0-9a-f-]{36}$/.test(key)) throw new ApiError(404, "NOT_FOUND", "Podcast not found");
  const [entry] = await db.select().from(podcastEpisodes).where(and(dayCondition(user, day),
    eq(podcastEpisodes.key, key), eq(podcastEpisodes.deleted, false))).limit(1);
  if (!entry) throw new ApiError(404, "NOT_FOUND", "Podcast not found");
  await authorize(db, user, entry.document);
  return entry.document;
}
export async function dailyPodcastRecording(db: Database, user: string, day: PodcastDay, key: string, store = getObjectStore()) {
  await dailyPodcastEpisode(db, user, day, key);
  return store.get(`${dayKey(user, day)}/${key}/audio.mp3`);
}

export function jsonObject(value: unknown) {
  return { bytes: new TextEncoder().encode(JSON.stringify(value)), contentType: "application/json", cacheControl: "private, no-store" };
}
function dayCondition(user: string, day: PodcastDay) {
  return and(eq(podcastEpisodes.ownerId, user), eq(podcastEpisodes.dayStart, Date.parse(day.start)), eq(podcastEpisodes.dayEnd, Date.parse(day.end)));
}
export async function dailyPodcastChips(db: Database, user: string, day: PodcastDay) {
  const activity = sql`CASE WHEN ${summaries.ownerId} = ${user} THEN ${summaries.createdAt} ELSE ${summaryViews.viewedAt} END`;
  return await db.select({ chip: summaries }).from(summaries)
      .leftJoin(summaryViews, and(eq(summaryViews.summaryId, summaries.id), eq(summaryViews.userId, user)))
      .where(and(eq(summaries.kind, "summary"),
        or(eq(summaries.ownerId, user), and(ne(summaries.ownerId, user), isNotNull(summaryViews.userId), readableByViewer(user))),
        sql`${activity} >= ${Date.parse(day.start)}`, sql`${activity} < ${Date.parse(day.end)}`))
      .orderBy(asc(activity), asc(summaries.id));

}
export async function listDailyPodcasts(db: Database, user: string, day: PodcastDay) {
  const rows = await db.select().from(podcastEpisodes).where(and(dayCondition(user, day), eq(podcastEpisodes.deleted, false), sql`${podcastEpisodes.summaryId} IS NULL`));
  const readable = await readableSources(db, user, rows.map((row) => row.document));
  return rows.filter((row) => sourceIds(row.document).every((id) => readable.has(id)))
    .map((row) => ({ podcast: row.document, isDefault: row.isDefault }))
    .sort((a, b) => b.podcast.createdAt.localeCompare(a.podcast.createdAt));
}
export async function selectDailyPodcast(db: Database, user: string, day: PodcastDay, key: string) {
  const podcast = await dailyPodcastEpisode(db, user, day, key);
  if (podcast.summaryId) throw new ApiError(422, "PODCAST_LIBRARY", "Library podcasts cannot be daily defaults.");
  await db.batch([
    db.update(podcastEpisodes).set({ isDefault: false }).where(dayCondition(user, day)),
    db.update(podcastEpisodes).set({ isDefault: true }).where(and(dayCondition(user, day), eq(podcastEpisodes.key, key), eq(podcastEpisodes.deleted, false))),
  ]);
  return podcast;
}
export async function removeDailyPodcast(db: Database, user: string, day: PodcastDay, key: string) {
  await dailyPodcastEpisode(db, user, day, key);
  const [row] = await db.select().from(podcastEpisodes).where(and(dayCondition(user, day), eq(podcastEpisodes.key, key)));
  if (!row || row.summaryId) throw new ApiError(404, "NOT_FOUND", "Daily version not found");
  await db.update(podcastEpisodes).set({ deleted: true, isDefault: false }).where(eq(podcastEpisodes.key, key));
  await db.delete(podcastShareLinks).where(and(eq(podcastShareLinks.ownerId, user), eq(podcastShareLinks.episodeKey, key)));
  if (row.isDefault) {
    const next = (await listDailyPodcasts(db, user, day))[0];
    if (next) await selectDailyPodcast(db, user, day, next.podcast.key);
  }
}
export async function libraryPodcast(db: Database, user: string, summaryId: string) {
  await getSummaryForViewer(db, summaryId, user);
  const [row] = await db.select().from(podcastEpisodes).where(and(eq(podcastEpisodes.summaryId, summaryId), eq(podcastEpisodes.ownerId, user), eq(podcastEpisodes.deleted, false)));
  if (!row) throw new ApiError(404, "NOT_FOUND", "Podcast not found");
  await authorize(db, user, row.document);
  return row.document;
}

/** The database is the sole source of episode metadata. */
export async function savePodcastDocument(db: Database, user: string, podcast: DailyPodcast) {
  await db.update(podcastEpisodes).set({ document: podcast }).where(and(eq(podcastEpisodes.key, podcast.key), eq(podcastEpisodes.ownerId, user)));
}
