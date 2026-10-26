import { runAfter } from "@/lib/http/after";
import { rerankHeadlines } from "./headlines";
import { joinPodcastAudio } from "./podcast-audio";
import { mixPodcast } from "./podcast-mixer";
import { alignPodcastCaptions } from "./podcast-captions";
import { podcastMusic, type PodcastMusic } from "./podcast-music";
import { startPodcastVideoDesign } from "./podcast-video-design";
import { createHash, randomUUID } from "node:crypto";
import { and, eq, inArray, isNotNull, ne, or, sql, asc } from "drizzle-orm";
import type { LanguageModelUsage } from "ai";
import { getAiProvider } from "@/lib/ai/provider";
import { tourVoice } from "@/lib/ai/models";
import { LANGUAGE_NAMES, normalizeDraft } from "@/lib/ai/summary-schema";
import { createDailyPodcastSchema, podcastScriptSchema, type DailyPodcast, type PodcastDay, type PodcastProgress, type PodcastScript } from "@/lib/contracts/daily-podcast";
import type { AiProvider } from "@/lib/ai/provider";
import type { SummaryRow } from "@/lib/db/schema";
import type { z } from "zod";
import type { Database } from "@/lib/db/client";
import { summaries, summaryViews, podcastEpisodes, podcastShareLinks } from "@/lib/db/schema";
import type { Category } from "@/lib/contracts/api";
import { ApiError } from "@/lib/http/errors";
import { getObjectStore, type ObjectStore } from "@/lib/storage/r2";
import { pointsForCost, reservePodcastPoints, usageCostUsd } from "@/lib/subscription/chat-billing";
import { coverImages, deleteObjects, getSummaryForViewer, type ServiceDeps } from "./summaries";
import { selectCoverTheme } from "./cover-colors";
import { retireTranslatedCovers } from "./translations";
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
  const requestKey = `${base}/${JSON.stringify([input.library, input.chipIds && [...new Set(input.chipIds)].sort(), input.language, input.includeVideo !== false, input.summaryId ?? null, input.speakerNames ?? null])}`;
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
    // Regenerating a library podcast adds a version to its chip rather than creating another chip.
    const existingChip = input.summaryId ? await libraryPodcastChip(db, user, input.summaryId) : null;
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
    if (input.speakerNames && input.speakerNames.length > voices.length) {
      throw new ApiError(400, "PODCAST_SPEAKERS_UNAVAILABLE", `Up to ${voices.length} speakers are available. Choose fewer speakers.`);
    }
    const key = randomUUID();
    const charge = await reservePodcastPoints(user, key, ai.podcastModelId(), deps.billingEnvironment);
    const usage: LanguageModelUsage[] = [];
    const deadline = AbortSignal.timeout(270_000);
    let coverTask: Promise<PodcastCover | null> | null = null;
    try {
      report("script", 5);
      const script = podcastScriptSchema.parse(await ai.writePodcast({ language: LANGUAGE_NAMES[input.language], voices, speakerNames: input.speakerNames,
        chips: chips.map(({ chip }) => ({ id: chip.id, title: chip.title, summary: chip.summary, highlights: chip.highlights })) },
      { abortSignal: AbortSignal.any([deadline, AbortSignal.timeout(100_000)]), onUsage: (step) => usage.push(step) }));
      if ((input.speakerNames && (script.speakers.length !== input.speakerNames.length || script.speakers.some((speaker, index) => speaker.name !== input.speakerNames![index]))) || new Set(script.speakers.map((s) => s.voice)).size !== script.speakers.length || script.speakers.some((s) => !voices.includes(s.voice)) || script.segments.some((s) => s.speaker >= script.speakers.length || !chips.some(({ chip }) => chip.id === s.chipId)) || chips.some(({ chip }) => !script.segments.some((s) => s.chipId === chip.id))) {
        throw new Error("Invalid podcast references");
      }
      const summaryId = input.library ? input.summaryId ?? randomUUID() : undefined;
      // A library chip gets a designed theme and illustrated cover, drawn alongside the voices.
      coverTask = summaryId ? podcastCover(db, user, ai, store, summaryId, script, chips.map(({ chip }) => chip), input.language, deps.now?.() ?? new Date()) : null;
      // Theme music is shared by mood, so it's usually already stored; failures publish without music.
      const musicTask = podcastMusic(ai, store, script.mood, deadline);
      report("speech", 20, 0, script.segments.length);
      const voiced = await voiceSegments(ai, script.speakers, script.segments.map((segment) => {
        const chip = chips.find(({ chip }) => chip.id === segment.chipId)!.chip;
        return { ...segment, imagePath: chipArtPath(chip), icon: chip.theme.emoji || "🎙️" };
      }), deadline, (completed, total) => report("speech", 20 + Math.floor(50 * completed / total), completed, total));
      const segments = voiced.segments;
      const podcast: DailyPodcast = { ...script, segments, key, language: input.language, day: input.day,
        chipIds: chips.map(({ chip }) => chip.id), createdAt: (deps.now?.() ?? new Date()).toISOString() };
      report("music", 70);
      const music = await musicTask;
      report("mixing", 75);
      await storeContinuousAudio(store, `${base}/${key}/audio.mp3`, episodeAudioPath(podcast), podcast, voiced.audioParts, music);
      report("saving", 95);
      await authorize(db, user, podcast);
      const pricing = charge ? await ai.podcastPricing() : null;
      const textCost = pricing ? usage.reduce((sum, step) => sum + usageCostUsd(step, pricing), 0) : 0;
      const speechCost = segments.reduce((sum, s) => sum + s.caption.length, 0) * ai.speechUsdPerCharacter();
      const musicCost = (music?.generatedClips ?? 0) * ai.musicUsdPerClip();
      // Publish the playable recording before making a chip visible in the library.
      if (summaryId) podcast.summaryId = summaryId;
      const cover = await coverTask;
      const episodeInsert = db.insert(podcastEpisodes).values({ key, ownerId: user,
        dayStart: Date.parse(input.day.start), dayEnd: Date.parse(input.day.end), document: podcast,
        summaryId: podcast.summaryId ?? null });
      if (input.summaryId) {
        // The new version becomes the one the chip opens; earlier versions stay in its version picker.
        const now = deps.now?.() ?? new Date();
        await db.batch([episodeInsert,
          db.update(podcastEpisodes).set({ isDefault: false }).where(and(eq(podcastEpisodes.summaryId, input.summaryId), eq(podcastEpisodes.ownerId, user))),
          db.update(podcastEpisodes).set({ isDefault: true }).where(eq(podcastEpisodes.key, key)),
          db.update(summaries).set({ title: podcast.title, summary: podcastSummaryText(podcast), language: input.language, updatedAt: now, ...cover })
            .where(and(eq(summaries.id, input.summaryId), eq(summaries.ownerId, user)))]);
        if (cover && existingChip) {
          await deleteObjects(store, [existingChip.ogImageKey, existingChip.artImageKey]);
          await retireTranslatedCovers(db, store, [input.summaryId]);
        }
      } else if (podcast.summaryId) {
        const now = deps.now?.() ?? new Date();
        await db.batch([db.insert(summaries).values({ id: podcast.summaryId, slug: randomUUID(), ownerId: user,
          kind: "podcast", sourceType: "text", source: "text", title: podcast.title,
          summary: podcastSummaryText(podcast), highlights: [],
          category: "Other", tags: [], keywords: [], language: input.language,
          theme: { colors: ["#242354", "#7566b0"], mode: "dark", emoji: "🎙️", accent: "#7566b0" },
          visibility: "private", createdAt: now, updatedAt: now, ...cover }), episodeInsert,
          db.update(podcastEpisodes).set({ isDefault: true }).where(eq(podcastEpisodes.key, key))]);
      } else { await episodeInsert; }
      if (podcast.summaryId) runAfter(() => rerankHeadlines(db, user));
      if (!input.library) await selectDailyPodcast(db, user, input.day, key);
      await charge?.settle(Math.max(1, pointsForCost(textCost + speechCost + musicCost)), { segments: segments.length, textCostUsd: textCost, speechCostUsd: speechCost, musicCostUsd: musicCost });
      // The motion video is designed after transcription and mixing, so scenes are staged on the spoken
      // phrases at their real times. It runs in the background and is charged on its own; the recording
      // is already playable, so a design that can't start leaves the episode without video.
      if (input.includeVideo !== false && ai.podcastVideoModelId()) {
        report("video-design", 97);
        const designing = await startPodcastVideoDesign(db, user, podcast, chips.map(({ chip }) => ({ id: chip.id, title: chip.title })),
          { ai, store, billingEnvironment: deps.billingEnvironment, now: deps.now }, { checkPoints: false }).catch((error) => {
          console.error("[podcast] video design could not start, publishing without video", error);
          return null;
        });
        if (designing) Object.assign(podcast, designing);
      }
      report("complete", 100);
      return podcast;
    } catch (error) {
      await charge?.settle(0, { failed: true });
      const cover = await coverTask?.catch(() => null);
      if (cover) await deleteObjects(store, [cover.ogImageKey, cover.artImageKey]);
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

type PodcastCover = Pick<SummaryRow, "theme" | "ogHeadline" | "keywords" | "category" | "imageStyle" | "ogImageKey" | "artImageKey">;
/**
 * The chip's theme and illustrated cover, designed from the script and its source chips like papers
 * and trips are. Null when it failed; the chip then keeps the plain podcast theme.
 */
async function podcastCover(db: Database, user: string, ai: AiProvider, store: ObjectStore, id: string, script: PodcastScript,
  sources: SummaryRow[], language: string, createdAt: Date): Promise<PodcastCover | null> {
  try {
    const summary = podcastSummaryText(script);
    const keywords = [...new Set(sources.flatMap((chip) => chip.keywords))].slice(0, 10);
    // The sources' most common category; normalizeDraft maps anything unknown to "Other".
    const counts = new Map<string, number>();
    for (const chip of sources) counts.set(chip.category, (counts.get(chip.category) ?? 0) + 1);
    const category = ([...counts].sort((a, b) => b[1] - a[1])[0]?.[0] ?? "Other") as Category;
    const text = sources.map((chip) => `${chip.title}\n${chip.summary}`).join("\n\n");
    const design = await ai.designCover({ title: script.title, summary, category, keywords, text, language });
    const normalized = normalizeDraft({ title: script.title, summary, highlights: [], category, tags: [], keywords, language,
      design: design ?? { colors: [], mode: undefined as unknown as "light", emoji: "", accent: "", headline: "" } }, { requestedLanguage: "auto", seed: id });
    const theme = await selectCoverTheme(db, user, { ...normalized.theme, emoji: normalized.theme.emoji || "🎙️" });
    const draft = { ...normalized, title: script.title, summary, theme };
    const images = await coverImages(store, ai, id, draft, null, "illustration", createdAt, "podcast");
    return { theme, ogHeadline: draft.headline, keywords: draft.keywords, category: draft.category, imageStyle: "illustration", ...images };
  } catch (error) {
    console.error("[podcast] cover design failed", error);
    return null;
  }
}

function podcastSummaryText(podcast: Pick<PodcastScript, "segments">) {
  return podcast.segments.map((s) => s.caption).join(" ").slice(0, 1200);
}
function chipArtPath(chip: Pick<SummaryRow, "artImageKey" | "slug">) {
  return chip.artImageKey ? `/s/${chip.slug}/art.png` : null;
}
/** The episode's recording in `language`; the original when omitted. */
export function episodeAudioPath(podcast: Pick<DailyPodcast, "key" | "day">, language?: string) {
  const query = new URLSearchParams(podcast.day);
  if (language) query.set("language", language);
  return `/api/v1/daily-podcasts/${podcast.key}/audio?${query}`;
}
/** Object key of a translation's files under the episode. */
export function translationPath(user: string, podcast: Pick<DailyPodcast, "key" | "day">, language: string) {
  return `${dayKey(user, podcast.day)}/${podcast.key}/translations/${language}`;
}

type VoicedSegment = PodcastScript["segments"][number] & { imagePath: string | null; icon: string };
/** Speaks every turn (four at a time) and transcribes it for caption timing. Throws when any turn fails. */
export async function voiceSegments(ai: AiProvider, speakers: PodcastScript["speakers"], turns: VoicedSegment[], abortSignal: AbortSignal,
  onSegment: (completed: number, total: number) => void) {
  const segments: DailyPodcast["segments"] = [];
  const audioParts: Uint8Array[] = [];
  let completed = 0;
  // Bound speech concurrency and finish audio before publishing a playable episode.
  for (let start = 0; start < turns.length; start += 4) {
    const batch = await Promise.all(turns.slice(start, start + 4).map(async (segment, offset) => {
      const audio = await ai.speak(segment.caption, speakers[segment.speaker].voice, { abortSignal });
      audioParts[start + offset] = audio.bytes;
      const captionCues = alignPodcastCaptions(segment.caption, await ai.transcribePodcast(audio.bytes, { abortSignal }));
      completed += 1;
      onSegment(completed, turns.length);
      return { ...segment, captionCues };
    }));
    segments.push(...batch);
  }
  return { segments, audioParts };
}

/** Mixes the turns (with music when available) into one MP3 at `objectKey` and times `target`'s segments against it. */
export async function storeContinuousAudio(store: ObjectStore, objectKey: string, audioPath: string,
  podcast: Pick<DailyPodcast, "segments" | "audioPath" | "durationSeconds" | "music">, parts: Uint8Array[], music: PodcastMusic | null = null) {
  let joined: { bytes: Uint8Array; cues: { startSeconds: number; endSeconds: number }[]; durationSeconds: number } | null = null;
  if (music) {
    try { joined = await mixPodcast(parts.map((bytes, index) => ({ bytes, topic: podcast.segments[index].chipId })), music); }
    catch (error) { console.error("[podcast] music mix failed, publishing voices only", error); }
  }
  podcast.music = Boolean(joined);
  joined ??= joinPodcastAudio(parts);
  await store.put(objectKey, { bytes: joined.bytes, contentType: "audio/mpeg", cacheControl: "private, no-store" });
  podcast.audioPath = audioPath;
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
export async function dailyPodcastRecording(db: Database, user: string, day: PodcastDay, key: string, store = getObjectStore(), language?: string | null) {
  const podcast = await dailyPodcastEpisode(db, user, day, key);
  if (isTranslation(podcast, language)) {
    if (!podcast.translations?.[language!]) throw translationMissing();
    return store.get(`${translationPath(user, podcast, language!)}/audio.mp3`);
  }
  return store.get(`${dayKey(user, day)}/${key}/audio.mp3`);
}

/** Whether `language` asks for a translation rather than the original recording. */
export function isTranslation(podcast: DailyPodcast, language?: string | null) {
  return Boolean(language) && language !== podcast.language;
}
export function translationMissing() {
  return new ApiError(404, "PODCAST_TRANSLATION_MISSING", "This podcast hasn't been translated into that language.");
}
/**
 * The episode as clients see it: one language at a time. Translations keep the original's key, day,
 * chips, mood and version date, and replace its title, voices, captions, timings, recording and video.
 */
export function podcastInLanguage(podcast: DailyPodcast, language?: string | null): DailyPodcast {
  const { translations, ...original } = podcast;
  const languages = [podcast.language, ...Object.keys(translations ?? {}).filter((code) => code !== podcast.language).sort()];
  const shared = { originalLanguage: podcast.language, languages };
  if (!isTranslation(podcast, language)) return { ...original, ...shared };
  const translation = translations?.[language!];
  if (!translation) throw translationMissing();
  const { title, speakers, segments, audioPath, durationSeconds, music, video } = translation;
  return { ...original, language: translation.language, title, speakers, segments, audioPath, durationSeconds, music,
    video: video && { id: video.id, createdAt: video.createdAt, published: video.published }, ...shared };
}
/** Applies `change` to the latest stored document, so long-running writers don't drop each other's changes. */
export async function updatePodcastDocument(db: Database, user: string, key: string, change: (podcast: DailyPodcast) => void) {
  const [row] = await db.select().from(podcastEpisodes).where(and(eq(podcastEpisodes.key, key), eq(podcastEpisodes.ownerId, user), eq(podcastEpisodes.deleted, false))).limit(1);
  if (!row) throw new ApiError(404, "NOT_FOUND", "Podcast not found");
  const podcast = row.document;
  change(podcast);
  await savePodcastDocument(db, user, podcast);
  return podcast;
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
/** Makes a daily version the day's default, or a library version the one its chip opens. */
export async function selectDailyPodcast(db: Database, user: string, day: PodcastDay, key: string) {
  const podcast = await dailyPodcastEpisode(db, user, day, key);
  const scope = podcast.summaryId
    ? and(eq(podcastEpisodes.ownerId, user), eq(podcastEpisodes.summaryId, podcast.summaryId))
    : and(dayCondition(user, day), sql`${podcastEpisodes.summaryId} IS NULL`);
  await db.batch([
    db.update(podcastEpisodes).set({ isDefault: false }).where(scope),
    db.update(podcastEpisodes).set({ isDefault: true }).where(and(scope, eq(podcastEpisodes.key, key), eq(podcastEpisodes.deleted, false))),
  ]);
  return podcast;
}
export async function removeDailyPodcast(db: Database, user: string, day: PodcastDay, key: string) {
  await dailyPodcastEpisode(db, user, day, key);
  const [row] = await db.select().from(podcastEpisodes).where(and(dayCondition(user, day), eq(podcastEpisodes.key, key)));
  if (!row) throw new ApiError(404, "NOT_FOUND", "Podcast version not found");
  const versions = row.summaryId ? await listLibraryPodcasts(db, user, row.summaryId) : null;
  // A podcast chip always keeps one recording; deleting the chip removes them all.
  if (versions && versions.length <= 1) throw new ApiError(422, "PODCAST_LAST_VERSION", "Delete the podcast chip to remove its only version.");
  await db.update(podcastEpisodes).set({ deleted: true, isDefault: false }).where(eq(podcastEpisodes.key, key));
  await db.delete(podcastShareLinks).where(and(eq(podcastShareLinks.ownerId, user), eq(podcastShareLinks.episodeKey, key)));
  const wasDefault = versions ? versions.find((version) => version.podcast.key === key)?.isDefault : row.isDefault;
  if (wasDefault) {
    const next = versions ? versions.find((version) => version.podcast.key !== key) : (await listDailyPodcasts(db, user, day))[0];
    if (next) await selectDailyPodcast(db, user, next.podcast.day, next.podcast.key);
  }
}
async function libraryPodcastChip(db: Database, user: string, summaryId: string) {
  const chip = await getSummaryForViewer(db, summaryId, user);
  if (chip.ownerId !== user || chip.kind !== "podcast") throw new ApiError(404, "NOT_FOUND", "Podcast not found");
  return chip;
}
/** A podcast chip's readable versions, newest first. Its default is the flagged one, else the newest. */
export async function listLibraryPodcasts(db: Database, user: string, summaryId: string) {
  await libraryPodcastChip(db, user, summaryId);
  const rows = await db.select().from(podcastEpisodes).where(and(eq(podcastEpisodes.summaryId, summaryId), eq(podcastEpisodes.ownerId, user), eq(podcastEpisodes.deleted, false)));
  const readable = await readableSources(db, user, rows.map((row) => row.document));
  const items = rows.filter((row) => sourceIds(row.document).every((id) => readable.has(id)))
    .map((row) => ({ podcast: row.document, isDefault: row.isDefault }))
    .sort((a, b) => b.podcast.createdAt.localeCompare(a.podcast.createdAt));
  if (items.length && !items.some((item) => item.isDefault)) items[0].isDefault = true;
  return items;
}
export async function libraryPodcast(db: Database, user: string, summaryId: string) {
  const version = (await listLibraryPodcasts(db, user, summaryId)).find((item) => item.isDefault);
  if (!version) throw new ApiError(404, "NOT_FOUND", "Podcast not found");
  return version.podcast;
}

/** The database is the sole source of episode metadata. */
export async function savePodcastDocument(db: Database, user: string, podcast: DailyPodcast) {
  await db.update(podcastEpisodes).set({ document: podcast }).where(and(eq(podcastEpisodes.key, podcast.key), eq(podcastEpisodes.ownerId, user)));
}

/** Saved video episodes referencing a source chip, restricted to this viewer's library. */
export async function linkedVideoPodcasts(db: Database, user: string, chipId: string) {
  await getSummaryForViewer(db, chipId, user);
  const rows = await db.select().from(podcastEpisodes).where(and(
    eq(podcastEpisodes.ownerId, user), eq(podcastEpisodes.deleted, false),
    sql`EXISTS (SELECT 1 FROM json_each(${podcastEpisodes.document}, '$.chipIds') WHERE value = ${chipId})`,
  ));
  const readable = await readableSources(db, user, rows.map(row => row.document));
  return rows.filter(row => row.document.video && sourceIds(row.document).every(id => readable.has(id)))
    .sort((a, b) => b.document.createdAt.localeCompare(a.document.createdAt))
    .map(row => podcastInLanguage(row.document));
}
