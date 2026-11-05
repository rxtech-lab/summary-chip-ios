import { and, eq, sql } from "drizzle-orm";
import type { AudiobookMusicCue, AudiobookTake, AudiobookVideoTheme, DailyPodcast, PodcastChapter, PodcastDay, PodcastMusicMood, PodcastTranslation, PodcastVideoSummary } from "@/lib/contracts/daily-podcast";
import type { Database } from "@/lib/db/client";
import { audiobookJobs, audiobookPlans, podcastEpisodes, podcastShareLinks, summaries, type SummaryRow } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { getObjectStore, type ObjectStore } from "@/lib/storage/r2";
import { dayKey, episodeAudioPath, jsonObject, podcastSummaryText, translationPath } from "./daily-podcast";
import { joinPodcastAudio, slicePodcastAudio } from "./podcast-audio";
import { retirePodcastRenders } from "./podcast-render";
import { purgeSummaries, type ServiceDeps } from "./summaries";

/**
 * A plan makes one book, however many times its chapters are generated. Every generation saves each chapter as a take;
 * the book's chip has a single recording, rebuilt from one take per chapter in the source's order.
 */
export interface ChapterTurn {
  speaker: number; chipId: string; caption: string; music: string; scene: number;
  imagePath: string | null; icon: string;
  captionCues?: { text: string; startSeconds: number; endSeconds: number; paged?: boolean }[];
  voiced?: boolean;
}
export interface ChapterState {
  title: string;
  synopsis?: string;
  turns: ChapterTurn[];
  costUsd: number;
  mixed?: { cues: { startSeconds: number; endSeconds: number }[]; durationSeconds: number };
  /** Copied from an earlier translation, so not charged again. */
  reused?: boolean;
}

/** A revised plan can rename a chapter and keep it the same chapter; what identifies it is the source it narrates. */
export function bookChapterId(chapter: { firstPassage: number; lastPassage: number }) { return `${chapter.firstPassage}-${chapter.lastPassage}`; }

export function takeFile(user: string, day: PodcastDay, bookId: string, takeId: string, language: string) {
  return `${dayKey(user, day)}/${bookId}/chapter-takes/${takeId}/${language}`;
}
export async function saveTake(store: ObjectStore, user: string, day: PodcastDay, bookId: string, takeId: string, language: string, state: ChapterState, audio: Uint8Array) {
  const file = takeFile(user, day, bookId, takeId, language);
  await store.put(`${file}.mp3`, { bytes: audio, contentType: "audio/mpeg", cacheControl: "private, no-store" });
  await store.put(`${file}.json`, jsonObject(state));
}
async function readState(store: ObjectStore, file: string) {
  return JSON.parse(new TextDecoder().decode((await store.get(`${file}.json`)).bytes)) as ChapterState;
}

/**
 * The take each chapter plays, in source order: the chosen one, otherwise the newest. When a revised plan cut the source
 * differently, the more recently generated chapter wins, so no stretch of the book is narrated twice.
 */
export function chooseTakes(takes: AudiobookTake[], selected: Record<string, string> = {}): AudiobookTake[] {
  const newestFirst = [...takes].sort((a, b) => b.createdAt.localeCompare(a.createdAt));
  const chosen: AudiobookTake[] = [];
  for (const take of newestFirst) {
    if (chosen.some(item => item.chapterId === take.chapterId || (item.firstPassage <= take.lastPassage && take.firstPassage <= item.lastPassage))) continue;
    chosen.push(newestFirst.find(item => item.chapterId === take.chapterId && item.id === selected[take.chapterId]) ?? take);
  }
  return chosen.sort((a, b) => a.firstPassage - b.firstPassage);
}

/** Joins chapters into one recording and lays every turn and chapter out on its timeline. */
export async function assembleChapters(store: ObjectStore, parts: Uint8Array[], states: ChapterState[], objectKey: string) {
  const joined = joinPodcastAudio(parts);
  await store.put(objectKey, { bytes: joined.bytes, contentType: "audio/mpeg", cacheControl: "private, no-store" });
  const segments: DailyPodcast["segments"] = [];
  const chapters: PodcastChapter[] = [];
  states.forEach((state, chapter) => {
    const offset = joined.cues[chapter].startSeconds;
    const round = (seconds: number) => Math.round(seconds * 100) / 100;
    const startSegment = segments.length;
    state.turns.forEach((turn, index) => {
      const window = state.mixed!.cues[index];
      const start = window.startSeconds + offset;
      const end = window.endSeconds + offset;
      const captionCues = (turn.captionCues ?? []).map(cue => ({ ...cue, startSeconds: round(Math.min(end, start + cue.startSeconds)), endSeconds: round(Math.min(end, start + cue.endSeconds)) })).filter(cue => cue.endSeconds > cue.startSeconds);
      segments.push({ speaker: turn.speaker, chipId: turn.chipId, caption: turn.caption, imagePath: turn.imagePath, icon: turn.icon, chapter, music: turn.music,
        startSeconds: round(start), endSeconds: round(end), captionCues,
        voiceStartSeconds: captionCues[0]?.startSeconds ?? round(start), voiceEndSeconds: captionCues.at(-1)?.endSeconds ?? round(end) });
    });
    chapters.push({ title: state.title, ...(state.synopsis ? { synopsis: state.synopsis } : {}), startSegment, endSegment: segments.length,
      startSeconds: round(offset), endSeconds: round(joined.cues[chapter].endSeconds) });
  });
  return { segments, chapters, durationSeconds: joined.durationSeconds };
}

/** Builds the recording of one language from the chosen takes; null when a chapter was never spoken in it. */
async function composeLanguage(store: ObjectStore, user: string, day: PodcastDay, bookId: string, chosen: AudiobookTake[], allTakes: AudiobookTake[], speakers: DailyPodcast["speakers"], language: string, objectKey: string) {
  const files = chosen.map(take => takeFile(user, day, bookId, take.id, language));
  if ((await Promise.all(files.map(file => store.head(`${file}.json`)))).some(found => !found)) return null;
  const [read, parts] = await Promise.all([Promise.all(files.map(file => readState(store, file))), Promise.all(files.map(async file => (await store.get(`${file}.mp3`)).bytes))]);
  // Each take numbers its own speakers; the book has one list.
  const states = read.map((state, index) => ({ ...state, turns: state.turns.map((turn) => {
    const voice = chosen[index].speakers[turn.speaker]?.voice;
    return { ...turn, speaker: Math.max(0, speakers.findIndex(speaker => speaker.voice === voice)) };
  }) }));
  const assembled = await assembleChapters(store, parts, states, objectKey);
  assembled.chapters.forEach((chapter, index) => {
    const take = chosen[index];
    chapter.bookChapterId = take.chapterId;
    chapter.versionId = take.id;
    chapter.versions = allTakes.filter(item => item.chapterId === take.chapterId).sort((a, b) => b.createdAt.localeCompare(a.createdAt))
      .map(({ id, title, createdAt, durationSeconds }) => ({ id, title, createdAt, durationSeconds }));
  });
  return assembled;
}

interface BookMeta {
  title: string; summary: string; mood: PodcastMusicMood; language: DailyPodcast["language"]; musicCues: AudiobookMusicCue[];
  videoTheme: AudiobookVideoTheme; visualGuide: string; summaryId: string; createdAt: string; music: boolean;
}
interface BookChange {
  takes?: AudiobookTake[];
  select?: { chapterId: string; takeId: string };
  meta?: BookMeta;
  /** Designs the chip's cover when this creates the book's recording. */
  cover?: (draft: DailyPodcast) => Promise<Partial<SummaryRow> | null | undefined>;
}
const SAVE_ATTEMPTS = 5;

/**
 * Applies a change to a book and rebuilds its recordings. Two generations can finish together, so the save only lands on
 * the revision it was built from; the loser rebuilds with the winner's chapters included.
 */
export async function commitBook(db: Database, user: string, key: string, day: PodcastDay, change: BookChange, deps: ServiceDeps = {}) {
  const store = deps.store ?? getObjectStore();
  for (let attempt = 0; attempt < SAVE_ATTEMPTS; attempt++) {
    const [row] = await db.select().from(podcastEpisodes).where(and(eq(podcastEpisodes.key, key), eq(podcastEpisodes.ownerId, user)));
    const live = row && !row.deleted ? row.document : null;
    const meta = change.meta;
    if (!live && !meta) throw new ApiError(404, "NOT_FOUND", "Audiobook not found.");
    const bookId = live?.audiobook?.bookId ?? key;
    const known = live?.audiobook?.takes ?? [];
    const takes = [...known, ...(change.takes ?? []).filter(take => !known.some(item => item.id === take.id))];
    const selected = { ...live?.audiobook?.selected };
    // A new recording of a chapter is what's wanted next, until another is chosen.
    for (const take of change.takes ?? []) delete selected[take.chapterId];
    if (change.select) selected[change.select.chapterId] = change.select.takeId;
    const chosen = chooseTakes(takes, selected);
    const speakers = [...new Map(chosen.flatMap(take => take.speakers).map(speaker => [speaker.voice, speaker])).values()];
    const language = live?.language ?? meta!.language;
    const composed = await composeLanguage(store, user, day, bookId, chosen, takes, speakers, language, `${dayKey(user, day)}/${key}/audio.mp3`);
    if (!composed) throw new Error("A chapter's recording is missing");
    const previous = live?.audiobook?.revision ?? 0;
    const storedRevision = row?.document.audiobook?.revision ?? 0;
    const revision = Math.max(previous, storedRevision) + 1;
    const cues = [...new Map([...(live?.audiobook?.musicCues ?? []), ...(meta?.musicCues ?? [])].map(cue => [cue.id, cue])).values()];
    const { segments, chapters, durationSeconds } = composed;
    const document: DailyPodcast = { ...(live ?? {}), title: meta?.title ?? live!.title, summary: meta?.summary ?? live?.summary, mood: meta?.mood ?? live!.mood,
      speakers, segments, type: "regular", format: "audiobook", chapters,
      audiobook: { musicCues: cues, videoTheme: meta?.videoTheme ?? live!.audiobook!.videoTheme, visualGuide: meta?.visualGuide ?? live!.audiobook!.visualGuide,
        scenes: chosen.flatMap((take, index) => take.scenes.map(scene => ({ chapter: index, segment: chapters[index].startSegment + scene.turn, prompt: scene.prompt, motion: scene.motion }))),
        bookId, revision, takes, selected },
      key, summaryId: live?.summaryId ?? meta!.summaryId, language, day, chipIds: [...new Set(segments.map(segment => segment.chipId))].filter(id => !id.startsWith("upload:")),
      createdAt: live?.createdAt ?? meta!.createdAt, durationSeconds, music: (live?.music ?? false) || (meta?.music ?? false) };
    document.audioPath = episodeAudioPath(document);
    delete document.video;

    const translations: Record<string, PodcastTranslation> = {};
    for (const [code, translation] of Object.entries(live?.translations ?? {})) {
      const spoken = await composeLanguage(store, user, day, bookId, chosen, takes, speakers, code, `${translationPath(user, document, code)}/audio.mp3`);
      // A chapter new to the book isn't spoken in this language yet. Translating again reuses every chapter that is.
      if (!spoken) continue;
      translations[code] = { ...translation, video: undefined, speakers, segments: spoken.segments, chapters: spoken.chapters, durationSeconds: spoken.durationSeconds, audioPath: episodeAudioPath(document, code) };
    }
    document.translations = translations;
    if (!Object.keys(translations).length) delete document.translations;

    const summaryText = document.summary ?? podcastSummaryText(document);
    const highlights = chapters.slice(0, 5).map(chapter => chapter.title);
    const now = deps.now?.() ?? new Date();
    if (!row) {
      const cover = await change.cover?.(document) ?? undefined;
      const [chip] = await db.select({ id: summaries.id }).from(summaries).where(and(eq(summaries.id, document.summaryId!), eq(summaries.ownerId, user)));
      const inserted = db.insert(podcastEpisodes).values({ key, ownerId: user, dayStart: Date.parse(day.start), dayEnd: Date.parse(day.end), document, summaryId: document.summaryId, isDefault: true }).onConflictDoNothing().returning({ key: podcastEpisodes.key });
      const others = db.update(podcastEpisodes).set({ isDefault: false }).where(and(eq(podcastEpisodes.summaryId, document.summaryId!), eq(podcastEpisodes.ownerId, user)));
      if (chip) {
        const [, , saved] = await db.batch([others,
          db.update(summaries).set({ title: document.title, summary: summaryText, highlights, language, updatedAt: now, ...cover }).where(eq(summaries.id, chip.id)), inserted]);
        if (!saved.length) continue;
      } else {
        const [, saved] = await db.batch([db.insert(summaries).values({ id: document.summaryId!, slug: crypto.randomUUID(), ownerId: user, kind: "audiobook", sourceType: "text", source: "text", title: document.title,
          summary: summaryText, highlights, category: "Other", tags: [], keywords: [], language,
          theme: { colors: ["#2A2118", "#8A6A45"], mode: "dark", emoji: "📖", accent: "#8A6A45" }, visibility: "private", createdAt: now, updatedAt: now, ...cover }).onConflictDoNothing(), inserted]);
        if (!saved.length) continue;
      }
      return { podcast: document, created: true, hadVideo: false };
    }

    // Status writes from the video design don't move the revision, so take its latest state as late as possible.
    const [latest] = await db.select({ document: podcastEpisodes.document }).from(podcastEpisodes).where(eq(podcastEpisodes.key, key));
    if ((latest.document.audiobook?.revision ?? 0) !== storedRevision) continue;
    if (latest.document.videoDesign) document.videoDesign = latest.document.videoDesign; else delete document.videoDesign;
    const [saved] = await db.update(podcastEpisodes).set({ document, deleted: false, summaryId: document.summaryId }).where(and(eq(podcastEpisodes.key, key), eq(podcastEpisodes.ownerId, user),
      sql`COALESCE(json_extract(${podcastEpisodes.document}, '$.audiobook.revision'), 0) = ${storedRevision}`)).returning({ key: podcastEpisodes.key });
    if (!saved) continue;
    if (change.takes) {
      await db.batch([db.update(podcastEpisodes).set({ isDefault: false }).where(and(eq(podcastEpisodes.summaryId, document.summaryId!), eq(podcastEpisodes.ownerId, user))),
        db.update(podcastEpisodes).set({ isDefault: true }).where(eq(podcastEpisodes.key, key)),
        db.update(summaries).set({ title: document.title, summary: summaryText, highlights, language, updatedAt: now }).where(and(eq(summaries.id, document.summaryId!), eq(summaries.ownerId, user)))]);
    }
    // The video timed against the old recording is gone with it; the caller draws what's new and queues a fresh render.
    const retired: (PodcastVideoSummary | undefined)[] = [latest.document.video, ...Object.values(latest.document.translations ?? {}).map(item => item.video)];
    for (const video of retired) if (video) await retirePodcastRenders(store, user, day, key, video).catch(error => console.warn("[audiobook] old video not removed", error));
    return { podcast: document, created: false, hadVideo: retired.some(Boolean) || !!latest.document.videoDesign };
  }
  throw new ApiError(409, "AUDIOBOOK_BOOK_BUSY", "This audiobook is being updated. Please try again.");
}

/** Queues a video for the rebuilt recording. `onlyIfDrawn` keeps a rebuild the listener didn't pay for from drawing anything. */
export async function rebuildBookVideo(db: Database, user: string, podcast: DailyPodcast, deps: ServiceDeps & { onlyIfDrawn?: boolean }) {
  const store = deps.store ?? getObjectStore();
  try {
    const { startAudiobookVideo } = await import("./audiobook-video");
    const { sceneFile, sceneHash } = await import("./audiobooks");
    const details = podcast.audiobook;
    if (!details?.scenes.length) return;
    if (deps.onlyIfDrawn) {
      const present = await Promise.all(details.scenes.map(scene => store.head(`${dayKey(user, podcast.day)}/${podcast.key}/${sceneFile(sceneHash(scene.prompt, details))}`)));
      if (present.some(found => !found)) return;
    }
    await startAudiobookVideo(db, user, podcast, { ai: deps.ai, store, billingEnvironment: deps.billingEnvironment, now: deps.now }, {});
  } catch (error) {
    console.error("[audiobook] video could not start; the book is saved without one", error);
  }
}

/** A recording's chapter and language as a take: its slice of the audio, with times made relative to the chapter. */
function chapterStateFrom(segments: DailyPodcast["segments"], chapter: PodcastChapter): ChapterState {
  const start = chapter.startSeconds;
  const turns = segments.slice(chapter.startSegment, chapter.endSegment);
  return { title: chapter.title, ...(chapter.synopsis ? { synopsis: chapter.synopsis } : {}), costUsd: 0,
    turns: turns.map(turn => ({ speaker: turn.speaker, chipId: turn.chipId, caption: turn.caption, music: turn.music ?? "", scene: 0, imagePath: turn.imagePath, icon: turn.icon, voiced: true,
      captionCues: (turn.captionCues ?? []).map(cue => ({ ...cue, startSeconds: cue.startSeconds - (turn.startSeconds ?? 0), endSeconds: cue.endSeconds - (turn.startSeconds ?? 0) })) })),
    mixed: { durationSeconds: chapter.endSeconds - start, cues: turns.map(turn => ({ startSeconds: (turn.startSeconds ?? start) - start, endSeconds: (turn.endSeconds ?? start) - start })) } };
}

/** Splits a finished recording into takes, in each language it was spoken in. */
async function takesFromRecording(store: ObjectStore, user: string, podcast: DailyPodcast, bookId: string, plan: { chapters: { firstPassage: number; lastPassage: number }[] }) {
  const base = `${dayKey(user, podcast.day)}/${podcast.key}`;
  const chapters = podcast.chapters ?? [];
  const ids = chapters.map((_, index) => `${podcast.key}-${index}`);
  const parts = slicePodcastAudio((await store.get(`${base}/audio.mp3`)).bytes, chapters);
  await Promise.all(chapters.map((chapter, index) => saveTake(store, user, podcast.day, bookId, ids[index], podcast.language, chapterStateFrom(podcast.segments, chapter), parts[index])));
  for (const [language, translation] of Object.entries(podcast.translations ?? {})) {
    const spoken = translation.chapters ?? [];
    if (spoken.length !== chapters.length) continue;
    const audio = await store.get(`${translationPath(user, podcast, language)}/audio.mp3`).catch(() => null);
    if (!audio) continue;
    const pieces = slicePodcastAudio(audio.bytes, spoken);
    await Promise.all(spoken.map((chapter, index) => saveTake(store, user, podcast.day, bookId, ids[index], language, chapterStateFrom(translation.segments, chapter), pieces[index])));
  }
  return chapters.map((chapter, index): AudiobookTake => {
    const source = plan.chapters[index];
    return { id: ids[index], chapterId: bookChapterId(source), firstPassage: source.firstPassage, lastPassage: source.lastPassage, title: chapter.title,
      createdAt: podcast.createdAt, durationSeconds: chapter.endSeconds - chapter.startSeconds, speakers: podcast.speakers,
      scenes: (podcast.audiobook?.scenes ?? []).filter(scene => scene.chapter === index).map(scene => ({ turn: scene.segment - chapter.startSegment, prompt: scene.prompt, motion: scene.motion })) };
  });
}

const merging = new Set<string>();

/**
 * Folds recordings made before a plan had one book into it: chapters join, repeats become versions, and the chips left
 * empty go away. Runs when two or more recordings share a plan, or for `onlyBook` when it's about to gain chapters. Safe to
 * run again: nothing is removed until the book is saved, and takes keep their ids.
 */
export async function mergeLegacyAudiobooks(db: Database, user: string, deps: ServiceDeps = {}, onlyBook?: string) {
  if (!onlyBook && merging.has(user)) return;
  if (!onlyBook) merging.add(user);
  try {
    const episodes = await db.select().from(podcastEpisodes).where(and(eq(podcastEpisodes.ownerId, user), eq(podcastEpisodes.deleted, false),
      sql`json_extract(${podcastEpisodes.document}, '$.format') = 'audiobook'`, sql`json_extract(${podcastEpisodes.document}, '$.audiobook.bookId') IS NULL`));
    if (!episodes.length) return;
    const store = deps.store ?? getObjectStore();
    const plans = await db.select().from(audiobookPlans).where(eq(audiobookPlans.ownerId, user));
    const groups = new Map<number, typeof episodes>();
    for (const episode of episodes) {
      const plan = plans.find(item => item.id === episode.key);
      if (plan) groups.set(plan.createdAt, [...groups.get(plan.createdAt) ?? [], episode]);
    }
    const jobs = await db.select({ document: audiobookJobs.document }).from(audiobookJobs).where(eq(audiobookJobs.ownerId, user));
    for (const [createdAt, members] of groups) {
      // A selection copies its plan's creation time, which is how older recordings find each other. The plan may be gone.
      const siblings = plans.filter(plan => plan.createdAt === createdAt);
      const rootId = siblings.find(plan => plan.id.length !== 64 && !plan.input.bookId)?.id ?? [...members].sort((a, b) => a.document.createdAt.localeCompare(b.document.createdAt))[0].key;
      const [book] = await db.select({ key: podcastEpisodes.key }).from(podcastEpisodes).where(and(eq(podcastEpisodes.key, rootId), eq(podcastEpisodes.ownerId, user), eq(podcastEpisodes.deleted, false),
        sql`json_extract(${podcastEpisodes.document}, '$.audiobook.bookId') IS NOT NULL`));
      if (onlyBook ? rootId !== onlyBook : members.length < 2 && !book) continue;
      const busy = jobs.some(({ document: job }) => job.status === "running" && members.some(member => member.key === job.episodeKey || member.key === job.planId))
        || members.some(member => member.document.videoDesign && !member.document.videoDesign.error);
      if (busy) continue;
      try { await mergeGroup(db, store, user, rootId, members, siblings, deps); }
      catch (error) { console.error("[audiobook] recordings could not be merged yet", { book: rootId, error }); if (onlyBook) throw error; }
    }
  } finally {
    if (!onlyBook) merging.delete(user);
  }
}

async function mergeGroup(db: Database, store: ObjectStore, user: string, rootId: string, members: (typeof podcastEpisodes.$inferSelect)[], siblings: (typeof audiobookPlans.$inferSelect)[], deps: ServiceDeps) {
  const ordered = [...members].sort((a, b) => a.document.createdAt.localeCompare(b.document.createdAt));
  const oldest = ordered[0].document;
  const newest = ordered.at(-1)!.document;
  const day = oldest.day;
  const { sceneFile, sceneHash } = await import("./audiobooks");
  const takes: AudiobookTake[] = [];
  for (const member of ordered) {
    const plan = siblings.find(item => item.id === member.key)!;
    takes.push(...await takesFromRecording(store, user, member.document, rootId, plan.plan));
    // Scenes already drawn come along, so the book's video doesn't pay for them again.
    const details = member.document.audiobook;
    await Promise.all((details?.scenes ?? []).map(async (scene) => {
      const file = sceneFile(sceneHash(scene.prompt, details!));
      const drawn = member.key === rootId ? null : await store.get(`${dayKey(user, day)}/${member.key}/${file}`).catch(() => null);
      if (drawn) await store.put(`${dayKey(user, day)}/${rootId}/${file}`, drawn);
    }));
  }
  const details = newest.audiobook!;
  // The merged book keeps its oldest chip, so its link and likes survive.
  const { podcast } = await commitBook(db, user, rootId, day, { takes, meta: { title: newest.title, summary: newest.summary ?? podcastSummaryText(newest), mood: newest.mood, language: newest.language,
    musicCues: ordered.flatMap(member => member.document.audiobook?.musicCues ?? []), videoTheme: details.videoTheme, visualGuide: details.visualGuide, summaryId: oldest.summaryId!,
    createdAt: oldest.createdAt, music: ordered.some(member => member.document.music) } }, deps);
  const merged = members.filter(member => member.key !== rootId);
  const chips = new Set(merged.map(member => member.summaryId).filter((id): id is string => !!id && id !== podcast.summaryId));
  for (const member of merged) {
    await db.delete(podcastShareLinks).where(and(eq(podcastShareLinks.ownerId, user), eq(podcastShareLinks.episodeKey, member.key)));
    await db.delete(podcastEpisodes).where(and(eq(podcastEpisodes.key, member.key), eq(podcastEpisodes.ownerId, user)));
    for (const video of [member.document.video, ...Object.values(member.document.translations ?? {}).map(item => item.video)]) {
      if (video) await retirePodcastRenders(store, user, day, member.key, video).catch(() => undefined);
    }
    await Promise.all([`${dayKey(user, day)}/${member.key}/audio.mp3`, ...Object.keys(member.document.translations ?? {}).map(code => `${translationPath(user, member.document, code)}/audio.mp3`)]
      .map(key => store.delete(key).catch(() => undefined)));
  }
  for (const id of chips) {
    const remaining = await db.select({ key: podcastEpisodes.key }).from(podcastEpisodes).where(eq(podcastEpisodes.summaryId, id)).limit(1);
    if (remaining.length) continue;
    const [chip] = await db.select().from(summaries).where(and(eq(summaries.id, id), eq(summaries.ownerId, user)));
    if (chip) await purgeSummaries(db, store, [chip]);
  }
  if (members.some(member => member.document.video)) await rebuildBookVideo(db, user, podcast, { ...deps, onlyIfDrawn: true });
}
