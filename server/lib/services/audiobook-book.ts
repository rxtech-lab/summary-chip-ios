import { createHash } from "node:crypto";
import { and, eq, inArray, sql } from "drizzle-orm";
import type { AudiobookMusicCue, AudiobookScene, AudiobookTake, AudiobookVideoTheme, DailyPodcast, PodcastChapter, PodcastDay, PodcastMusicMood, PodcastTranslation } from "@/lib/contracts/daily-podcast";
import type { Database } from "@/lib/db/client";
import { audiobookJobs, audiobookPlans, podcastEpisodes, podcastShareLinks, summaries } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { getObjectStore, type ObjectStore } from "@/lib/storage/r2";
import { dayKey, episodeAudioPath, podcastSummaryText, translationPath } from "./daily-podcast";
import { joinPodcastAudio, slicePodcastAudio } from "./podcast-audio";
import { retirePodcastRenders } from "./podcast-render";
import { purgeSummaries, type ServiceDeps } from "./summaries";

/**
 * A plan makes one book, however many times its chapters are generated. Every recording of a chapter is its own episode,
 * with its own audio, video and translations. The book's episode is only an index: which recording plays for each
 * chapter. Nothing is ever joined into one file, so adding a chapter or changing a version touches no other chapter.
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
}

/** A revised plan can rename a chapter and keep it the same chapter; what identifies it is the source it narrates. */
export function bookChapterId(chapter: { firstPassage: number; lastPassage: number }) { return `${chapter.firstPassage}-${chapter.lastPassage}`; }
/** Stable across retries, so publishing a chapter twice can't record it twice. */
export function chapterEpisodeKey(source: string, chapter: number) { return createHash("sha256").update(`${source}-${chapter}`).digest("hex"); }

/**
 * The recording each chapter plays, in source order: the chosen one, otherwise the newest. When a revised plan cut the
 * source differently, the more recently generated chapter wins, so no stretch of the book is narrated twice.
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

const round = (seconds: number) => Math.round(seconds * 100) / 100;

/** Finishes a recording and lays every turn and chapter out on its timeline. */
export async function assembleChapters(store: ObjectStore, parts: Uint8Array[], states: ChapterState[], objectKey: string) {
  const joined = joinPodcastAudio(parts);
  await store.put(objectKey, { bytes: joined.bytes, contentType: "audio/mpeg", cacheControl: "private, no-store" });
  const segments: DailyPodcast["segments"] = [];
  const chapters: PodcastChapter[] = [];
  states.forEach((state, chapter) => {
    const offset = joined.cues[chapter].startSeconds;
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

interface ChapterEpisodeInput {
  key: string; bookKey: string; user: string; day: PodcastDay; summaryId: string; language: string; createdAt: string; music: boolean; mood: PodcastMusicMood;
  speakers: DailyPodcast["speakers"]; musicCues: AudiobookMusicCue[]; videoTheme: AudiobookVideoTheme; visualGuide: string;
  scenes: AudiobookTake["scenes"]; translations?: Record<string, PodcastTranslation>;
}
/** Saves one recording of a chapter as an episode of its own. Hidden from version lists; the book's index leads to it. */
export async function saveChapterEpisode(db: Database, store: ObjectStore, input: ChapterEpisodeInput, state: ChapterState, audio: Uint8Array) {
  const { key, user, day } = input;
  const { segments, chapters, durationSeconds } = await assembleChapters(store, [audio], [state], `${dayKey(user, day)}/${key}/audio.mp3`);
  const scenes: AudiobookScene[] = input.scenes.map(scene => ({ chapter: 0, segment: scene.turn, prompt: scene.prompt, motion: scene.motion }));
  const document: DailyPodcast = { title: state.title, summary: state.synopsis, mood: input.mood, speakers: input.speakers, segments, type: "regular", format: "audiobook", chapters, bookKey: input.bookKey,
    audiobook: { musicCues: input.musicCues, videoTheme: input.videoTheme, visualGuide: input.visualGuide, scenes },
    key, summaryId: input.summaryId, language: input.language, day, chipIds: [...new Set(segments.map(segment => segment.chipId))].filter(id => !id.startsWith("upload:")),
    createdAt: input.createdAt, durationSeconds, music: input.music, ...(input.translations ? { translations: input.translations } : {}) };
  document.audioPath = episodeAudioPath(document);
  await db.insert(podcastEpisodes).values({ key, ownerId: user, dayStart: Date.parse(day.start), dayEnd: Date.parse(day.end), document }).onConflictDoNothing();
  return document;
}

interface BookMeta {
  title: string; summary: string; mood: PodcastMusicMood; language: DailyPodcast["language"]; musicCues: AudiobookMusicCue[];
  videoTheme: AudiobookVideoTheme; visualGuide: string; summaryId: string; createdAt: string; music: boolean;
}
interface BookChange {
  takes?: AudiobookTake[];
  select?: { chapterId: string; takeId: string };
  meta?: BookMeta;
}
const SAVE_ATTEMPTS = 8;

/**
 * Updates a book's index. Chapters of one run finish together, so the save only lands on the revision it was read from;
 * the loser reads again with the winner's chapter included.
 */
export async function commitBook(db: Database, user: string, key: string, day: PodcastDay, change: BookChange, deps: ServiceDeps = {}) {
  for (let attempt = 0; attempt < SAVE_ATTEMPTS; attempt++) {
    const [row] = await db.select().from(podcastEpisodes).where(and(eq(podcastEpisodes.key, key), eq(podcastEpisodes.ownerId, user)));
    if (row?.summaryId) {
      // A book whose chip was deleted is gone; generating from its plan again starts a new one rather than bringing it back.
      const [chip] = await db.select({ id: summaries.id }).from(summaries).where(eq(summaries.id, row.summaryId));
      if (!chip) {
        await db.delete(podcastEpisodes).where(and(eq(podcastEpisodes.key, key), eq(podcastEpisodes.ownerId, user)));
        continue;
      }
    }
    const live = row && !row.deleted ? row.document : null;
    const meta = change.meta;
    if (!live && !meta) throw new ApiError(404, "NOT_FOUND", "Audiobook not found.");
    const known = live?.audiobook?.takes ?? [];
    const takes = [...known, ...(change.takes ?? []).filter(take => !known.some(item => item.id === take.id))];
    const selected = { ...live?.audiobook?.selected };
    // A new recording of a chapter is what's wanted next, until another is chosen.
    for (const take of change.takes ?? []) delete selected[take.chapterId];
    if (change.select) selected[change.select.chapterId] = change.select.takeId;
    const chosen = chooseTakes(takes, selected);
    const episodes = await db.select({ key: podcastEpisodes.key, document: podcastEpisodes.document }).from(podcastEpisodes)
      .where(and(eq(podcastEpisodes.ownerId, user), inArray(podcastEpisodes.key, chosen.map(take => take.id))));
    const documents = chosen.map(take => episodes.find(item => item.key === take.id)?.document);
    if (documents.some(item => !item)) throw new Error("A chapter's recording is missing");

    // The index reads as one timeline (summaries and chapter lists use it), though no recording spans it.
    const speakers = [...new Map(documents.flatMap(item => item!.speakers).map(speaker => [speaker.voice, speaker])).values()];
    const segments: DailyPodcast["segments"] = [];
    const chapters: PodcastChapter[] = [];
    let offset = 0;
    chosen.forEach((take, index) => {
      const episode = documents[index]!;
      const startSegment = segments.length;
      for (const segment of episode.segments) {
        const voice = episode.speakers[segment.speaker]?.voice;
        const at = (seconds: number | undefined) => seconds === undefined ? undefined : round(seconds + offset);
        segments.push({ ...segment, chapter: index, speaker: Math.max(0, speakers.findIndex(speaker => speaker.voice === voice)), startSeconds: at(segment.startSeconds), endSeconds: at(segment.endSeconds),
          voiceStartSeconds: at(segment.voiceStartSeconds), voiceEndSeconds: at(segment.voiceEndSeconds),
          captionCues: segment.captionCues?.map(cue => ({ ...cue, startSeconds: at(cue.startSeconds)!, endSeconds: at(cue.endSeconds)! })) });
      }
      const length = episode.durationSeconds ?? 0;
      chapters.push({ title: take.title, ...(episode.chapters?.[0]?.synopsis ? { synopsis: episode.chapters[0].synopsis } : {}), startSegment, endSegment: segments.length,
        startSeconds: round(offset), endSeconds: round(offset + length), bookChapterId: take.chapterId, versionId: take.id,
        versions: takes.filter(item => item.chapterId === take.chapterId).sort((a, b) => b.createdAt.localeCompare(a.createdAt))
          .map(({ id, title, createdAt, durationSeconds }) => ({ id, title, createdAt, durationSeconds })) });
      offset += length;
    });

    const storedRevision = row?.document.audiobook?.revision ?? 0;
    const document: DailyPodcast = { ...(live ?? {}), title: meta?.title ?? live!.title, summary: meta?.summary ?? live?.summary, mood: meta?.mood ?? live!.mood,
      speakers, segments, type: "regular", format: "audiobook", chapters,
      audiobook: { musicCues: [...new Map([...(live?.audiobook?.musicCues ?? []), ...(meta?.musicCues ?? [])].map(cue => [cue.id, cue])).values()],
        videoTheme: meta?.videoTheme ?? live!.audiobook!.videoTheme, visualGuide: meta?.visualGuide ?? live!.audiobook!.visualGuide,
        scenes: [], bookId: key, revision: storedRevision + 1, takes, selected },
      key, summaryId: live?.summaryId ?? meta!.summaryId, language: live?.language ?? meta!.language, day, chipIds: [...new Set(segments.map(segment => segment.chipId))].filter(id => !id.startsWith("upload:")),
      createdAt: live?.createdAt ?? meta!.createdAt, durationSeconds: offset, music: (live?.music ?? false) || (meta?.music ?? false) };
    // Everything that plays lives on the chapters now; a recording this index was converted from has no further use.
    delete document.audioPath;
    delete document.video;
    delete document.videoDesign;
    delete document.translations;

    const summaryText = document.summary ?? podcastSummaryText(document);
    const highlights = chapters.slice(0, 5).map(chapter => chapter.title);
    const now = deps.now?.() ?? new Date();
    const summaryId = document.summaryId!;
    if (!row) {
      const [chip] = await db.select({ id: summaries.id }).from(summaries).where(and(eq(summaries.id, summaryId), eq(summaries.ownerId, user)));
      const inserted = db.insert(podcastEpisodes).values({ key, ownerId: user, dayStart: Date.parse(day.start), dayEnd: Date.parse(day.end), document, summaryId, isDefault: true }).onConflictDoNothing().returning({ key: podcastEpisodes.key });
      if (chip) {
        const [, , saved] = await db.batch([db.update(podcastEpisodes).set({ isDefault: false }).where(and(eq(podcastEpisodes.summaryId, summaryId), eq(podcastEpisodes.ownerId, user))),
          db.update(summaries).set({ title: document.title, summary: summaryText, highlights, language: document.language, updatedAt: now }).where(eq(summaries.id, chip.id)), inserted]);
        if (!saved.length) continue;
      } else {
        const [, saved] = await db.batch([db.insert(summaries).values({ id: summaryId, slug: crypto.randomUUID(), ownerId: user, kind: "audiobook", sourceType: "text", source: "text", title: document.title,
          summary: summaryText, highlights, category: "Other", tags: [], keywords: [], language: document.language,
          theme: { colors: ["#2A2118", "#8A6A45"], mode: "dark", emoji: "📖", accent: "#8A6A45" }, visibility: "private", createdAt: now, updatedAt: now }).onConflictDoNothing(), inserted]);
        if (!saved.length) continue;
      }
      await attachChapters(db, user, takes, summaryId);
      return { podcast: document, created: true, chipExisted: !!chip };
    }

    const [saved] = await db.update(podcastEpisodes).set({ document, deleted: false, summaryId }).where(and(eq(podcastEpisodes.key, key), eq(podcastEpisodes.ownerId, user),
      sql`COALESCE(json_extract(${podcastEpisodes.document}, '$.audiobook.revision'), 0) = ${storedRevision}`)).returning({ key: podcastEpisodes.key });
    if (!saved) continue;
    await attachChapters(db, user, change.takes ?? [], summaryId);
    if (change.takes) {
      await db.batch([db.update(podcastEpisodes).set({ isDefault: false }).where(and(eq(podcastEpisodes.summaryId, summaryId), eq(podcastEpisodes.ownerId, user))),
        db.update(podcastEpisodes).set({ isDefault: true }).where(eq(podcastEpisodes.key, key)),
        db.update(summaries).set({ title: document.title, summary: summaryText, highlights, language: document.language, updatedAt: now }).where(and(eq(summaries.id, summaryId), eq(summaries.ownerId, user)))]);
    }
    return { podcast: document, created: false, chipExisted: true };
  }
  throw new ApiError(409, "AUDIOBOOK_BOOK_BUSY", "This audiobook is being updated. Please try again.");
}
/** Chapter episodes go when their chip does. They're saved before a new book's chip exists, so they join it afterwards. */
async function attachChapters(db: Database, user: string, takes: AudiobookTake[], summaryId: string) {
  if (takes.length) await db.update(podcastEpisodes).set({ summaryId }).where(and(eq(podcastEpisodes.ownerId, user), inArray(podcastEpisodes.key, takes.map(take => take.id))));
}

/** Video for a chapter converted from an older recording. Only from scenes already drawn, because nobody asked to pay again. */
async function restoreChapterVideo(db: Database, store: ObjectStore, user: string, chapter: DailyPodcast, deps: ServiceDeps) {
  try {
    const { sceneFile, sceneHash } = await import("./audiobooks");
    const { startAudiobookVideo } = await import("./audiobook-video");
    const details = chapter.audiobook;
    if (!details?.scenes.length) return;
    const present = await Promise.all(details.scenes.map(scene => store.head(`${dayKey(user, chapter.day)}/${chapter.key}/${sceneFile(sceneHash(scene.prompt, details))}`)));
    if (present.every(Boolean)) await startAudiobookVideo(db, user, chapter, { ai: deps.ai, store, billingEnvironment: deps.billingEnvironment, now: deps.now }, {});
  } catch (error) {
    console.error("[audiobook] chapter video could not start", error);
  }
}

/** A chapter of a finished recording, with times made relative to the chapter. */
function chapterStateFrom(segments: DailyPodcast["segments"], chapter: PodcastChapter): ChapterState {
  const start = chapter.startSeconds;
  const turns = segments.slice(chapter.startSegment, chapter.endSegment);
  return { title: chapter.title, ...(chapter.synopsis ? { synopsis: chapter.synopsis } : {}), costUsd: 0,
    turns: turns.map(turn => ({ speaker: turn.speaker, chipId: turn.chipId, caption: turn.caption, music: turn.music ?? "", scene: 0, imagePath: turn.imagePath, icon: turn.icon, voiced: true,
      captionCues: (turn.captionCues ?? []).map(cue => ({ ...cue, startSeconds: cue.startSeconds - (turn.startSeconds ?? 0), endSeconds: cue.endSeconds - (turn.startSeconds ?? 0) })) })),
    mixed: { durationSeconds: chapter.endSeconds - start, cues: turns.map(turn => ({ startSeconds: (turn.startSeconds ?? start) - start, endSeconds: (turn.endSeconds ?? start) - start })) } };
}

/** Cuts an older whole recording into chapter episodes, in each language it was spoken in, keeping the scenes already drawn. */
async function chaptersFromRecording(db: Database, store: ObjectStore, user: string, podcast: DailyPodcast, bookKey: string, summaryId: string, plan: { chapters: { firstPassage: number; lastPassage: number }[] }) {
  const { sceneFile, sceneHash } = await import("./audiobooks");
  const base = `${dayKey(user, podcast.day)}/${podcast.key}`;
  const chapters = podcast.chapters ?? [];
  const details = podcast.audiobook!;
  const parts = slicePodcastAudio((await store.get(`${base}/audio.mp3`)).bytes, chapters);
  const spoken = await Promise.all(Object.entries(podcast.translations ?? {}).map(async ([language, translation]) => {
    const audio = translation.chapters?.length === chapters.length ? await store.get(`${translationPath(user, podcast, language)}/audio.mp3`).catch(() => null) : null;
    return audio ? { language, translation, pieces: slicePodcastAudio(audio.bytes, translation.chapters!) } : null;
  }));
  const takes: AudiobookTake[] = [];
  const episodes: DailyPodcast[] = [];
  for (const [index, chapter] of chapters.entries()) {
    const key = chapterEpisodeKey(podcast.key, index);
    const shell = { key, day: podcast.day };
    const translations: Record<string, PodcastTranslation> = {};
    for (const item of spoken) {
      if (!item) continue;
      const assembled = await assembleChapters(store, [item.pieces[index]], [chapterStateFrom(item.translation.segments, item.translation.chapters![index])], `${translationPath(user, shell, item.language)}/audio.mp3`);
      translations[item.language] = { language: item.language, title: assembled.chapters[0].title, createdAt: item.translation.createdAt, speakers: item.translation.speakers, music: item.translation.music,
        ...assembled, audioPath: episodeAudioPath(shell, item.language) };
    }
    const scenes = details.scenes.filter(scene => scene.chapter === index).map(scene => ({ turn: scene.segment - chapter.startSegment, prompt: scene.prompt, motion: scene.motion }));
    await Promise.all(scenes.map(async (scene) => {
      const file = sceneFile(sceneHash(scene.prompt, details));
      const drawn = await store.get(`${base}/${file}`).catch(() => null);
      if (drawn) await store.put(`${dayKey(user, podcast.day)}/${key}/${file}`, drawn);
    }));
    const episode = await saveChapterEpisode(db, store, { key, bookKey, user, day: podcast.day, summaryId, language: podcast.language, createdAt: podcast.createdAt, music: !!podcast.music, mood: podcast.mood,
      speakers: podcast.speakers, musicCues: details.musicCues, videoTheme: details.videoTheme, visualGuide: details.visualGuide, scenes, translations: Object.keys(translations).length ? translations : undefined },
    chapterStateFrom(podcast.segments, chapter), parts[index]);
    const source = plan.chapters[index];
    episodes.push(episode);
    takes.push({ id: key, chapterId: bookChapterId(source), firstPassage: source.firstPassage, lastPassage: source.lastPassage, title: chapter.title,
      createdAt: podcast.createdAt, durationSeconds: episode.durationSeconds ?? 0, speakers: podcast.speakers, scenes });
  }
  return { takes, episodes };
}

const merging = new Set<string>();

/**
 * Folds recordings made before chapters had their own episodes into their plan's book: chapters join, repeats become
 * versions, and the chips left empty go away. Runs when two or more recordings share a plan, or for `onlyBook` when it's
 * about to gain chapters. Safe to run again: nothing is removed until the book is saved, and chapter keys are stable.
 * Returns whether any chips changed.
 */
export async function mergeLegacyAudiobooks(db: Database, user: string, deps: ServiceDeps = {}, onlyBook?: string): Promise<boolean> {
  if (!onlyBook && merging.has(user)) return false;
  if (!onlyBook) merging.add(user);
  let merged = false;
  try {
    const store = deps.store ?? getObjectStore();
    if (await convertWholeBooks(db, store, user, deps)) merged = true;
    const episodes = await db.select().from(podcastEpisodes).where(and(eq(podcastEpisodes.ownerId, user), eq(podcastEpisodes.deleted, false),
      sql`json_extract(${podcastEpisodes.document}, '$.format') = 'audiobook'`, sql`json_extract(${podcastEpisodes.document}, '$.audiobook.bookId') IS NULL`, sql`json_extract(${podcastEpisodes.document}, '$.bookKey') IS NULL`));
    if (!episodes.length) return merged;
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
      try { await mergeGroup(db, store, user, rootId, members, siblings, deps); merged = true; }
      catch (error) { console.error("[audiobook] recordings could not be merged yet", { book: rootId, error }); if (onlyBook) throw error; }
    }
  } finally {
    if (!onlyBook) merging.delete(user);
  }
  return merged;
}

async function mergeGroup(db: Database, store: ObjectStore, user: string, rootId: string, members: (typeof podcastEpisodes.$inferSelect)[], siblings: (typeof audiobookPlans.$inferSelect)[], deps: ServiceDeps) {
  const ordered = [...members].sort((a, b) => a.document.createdAt.localeCompare(b.document.createdAt));
  const oldest = ordered[0].document;
  const newest = ordered.at(-1)!.document;
  const day = oldest.day;
  const [existing] = await db.select({ summaryId: podcastEpisodes.summaryId }).from(podcastEpisodes).where(and(eq(podcastEpisodes.key, rootId), eq(podcastEpisodes.ownerId, user), eq(podcastEpisodes.deleted, false)));
  // The merged book keeps its oldest chip, so its link and likes survive.
  const summaryId = existing?.summaryId ?? oldest.summaryId!;
  const takes: AudiobookTake[] = [];
  const episodes: DailyPodcast[] = [];
  for (const member of ordered) {
    const made = await chaptersFromRecording(db, store, user, member.document, rootId, summaryId, siblings.find(item => item.id === member.key)!.plan);
    takes.push(...made.takes);
    if (member.document.video) episodes.push(...made.episodes);
  }
  const details = newest.audiobook!;
  await commitBook(db, user, rootId, day, { takes, meta: { title: newest.title, summary: newest.summary ?? podcastSummaryText(newest), mood: newest.mood, language: newest.language,
    musicCues: ordered.flatMap(member => member.document.audiobook?.musicCues ?? []), videoTheme: details.videoTheme, visualGuide: details.visualGuide, summaryId,
    createdAt: oldest.createdAt, music: ordered.some(member => member.document.music) } }, deps);
  const chips = new Set(members.map(member => member.summaryId).filter((id): id is string => !!id && id !== summaryId));
  for (const member of members) {
    await db.delete(podcastShareLinks).where(and(eq(podcastShareLinks.ownerId, user), eq(podcastShareLinks.episodeKey, member.key)));
    if (member.key !== rootId) await db.delete(podcastEpisodes).where(and(eq(podcastEpisodes.key, member.key), eq(podcastEpisodes.ownerId, user)));
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
  for (const episode of episodes) await restoreChapterVideo(db, store, user, episode, deps);
}

/**
 * Books briefly kept one joined recording with their chapters saved beside it. Only a development database has any;
 * each chapter becomes an episode like every other. Safe to delete once none are left.
 */
async function convertWholeBooks(db: Database, store: ObjectStore, user: string, deps: ServiceDeps) {
  const books = await db.select().from(podcastEpisodes).where(and(eq(podcastEpisodes.ownerId, user), eq(podcastEpisodes.deleted, false),
    sql`json_extract(${podcastEpisodes.document}, '$.audiobook.bookId') IS NOT NULL`, sql`json_extract(${podcastEpisodes.document}, '$.audioPath') IS NOT NULL`));
  for (const book of books) {
    const document = book.document;
    const details = document.audiobook!;
    const renamed = new Map<string, string>();
    const takes: AudiobookTake[] = [];
    for (const take of details.takes ?? []) {
      const key = createHash("sha256").update(take.id).digest("hex");
      const file = `${dayKey(user, document.day)}/${details.bookId}/chapter-takes/${take.id}/${document.language}`;
      const state = JSON.parse(new TextDecoder().decode((await store.get(`${file}.json`)).bytes)) as ChapterState;
      const audio = (await store.get(`${file}.mp3`)).bytes;
      await saveChapterEpisode(db, store, { key, bookKey: book.key, user, day: document.day, summaryId: document.summaryId!, language: document.language, createdAt: take.createdAt, music: !!document.music, mood: document.mood,
        speakers: take.speakers, musicCues: details.musicCues, videoTheme: details.videoTheme, visualGuide: details.visualGuide, scenes: take.scenes }, state, audio);
      renamed.set(take.id, key);
      takes.push({ ...take, id: key });
    }
    const selected = Object.fromEntries(Object.entries(details.selected ?? {}).map(([chapter, take]) => [chapter, renamed.get(take) ?? take]));
    const converted = { ...document, audiobook: { ...details, takes, selected } };
    await db.update(podcastEpisodes).set({ document: converted }).where(eq(podcastEpisodes.key, book.key));
    await commitBook(db, user, book.key, document.day, { takes: [] }, deps);
    await attachChapters(db, user, takes, document.summaryId!);
  }
  return books.length > 0;
}
