import { createHash, randomUUID } from "node:crypto";
import { and, desc, eq } from "drizzle-orm";
import type { LanguageModelUsage } from "ai";
import { getAiProvider, type AiProvider } from "@/lib/ai/provider";
import { LANGUAGE_NAMES } from "@/lib/ai/summary-schema";
import { audiobookVoices, voiceUsdPerCharacter } from "@/lib/ai/voices";
import type { TranslationLanguage } from "@/lib/contracts/api";
import { audiobookPlanSchema, MAX_AUDIOBOOK_SCENES, type AudiobookCreationInput, type AudiobookJob, type AudiobookJobStage, type AudiobookPlanDocument } from "@/lib/contracts/audiobook";
import type { AudiobookScene, DailyPodcast, PodcastChapter, PodcastDay, PodcastPlanFrame, PodcastPlanMessage, PodcastTranslation } from "@/lib/contracts/daily-podcast";
import type { Database } from "@/lib/db/client";
import { audiobookJobs, audiobookPlans, podcastEpisodes, summaries, uploads, type SummaryRow } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { runAfter } from "@/lib/http/after";
import { getObjectStore, ownerKeyPrefix, type ObjectStore } from "@/lib/storage/r2";
import type { BillingEnvironment } from "@/lib/subscription/config";
import { pointsForCost, reservePodcastPoints, usageCostUsd } from "@/lib/subscription/chat-billing";
import { audiobookPassages, splitPassages, narrationRatio, narrationSeconds, normalizeAudiobookPlan, passagesForPlanning, type StoredPassage } from "./audiobook-source";
import { getAudiobookStarter } from "./audiobook-starter";
import { alignPodcastCaptions } from "./podcast-captions";
import { chipArtPath, dailyPodcastEpisode, dayKey, episodeAudioPath, jsonObject, podcastCover, podcastSummaryText, translationPath, updatePodcastDocument } from "./daily-podcast";
import { joinPodcastAudio } from "./podcast-audio";
import { mixAudiobookChapter } from "./podcast-mixer";
import { musicBedPrompt } from "./podcast-music";
import { rerankHeadlines } from "./headlines";
import { deliver } from "./notifications";
import { deleteObjects, extractPdfUpload, getSummaryForViewer, type ServiceDeps } from "./summaries";
import { retireTranslatedCovers } from "./translations";

type Plan = typeof audiobookPlans.$inferSelect;
/** Scene images drawn while reviewing a plan; later ones are drawn when the video is. */
export const MAX_PLAN_FRAMES = 24;
const FRAME_CONCURRENCY = 4;
const MAX_PLAN_MESSAGES = 60;
/** A run whose job hasn't moved for this long has stopped and may be retried. */
const STALE_MS = 20 * 60_000;
/** Turns voiced at once, and how long one workflow step keeps voicing before it saves and yields to the next. */
const VOICE_CONCURRENCY = 4;
const VOICE_STEP_MS = 200_000;
const MUSIC_BATCH = 4;
/** Text models run about this many USD per spoken character, for the estimate shown before confirming. */
const WRITING_USD_PER_CHARACTER = 0.000002;

const changed = () => new ApiError(409, "AUDIOBOOK_PLAN_CHANGED", "The plan changed. Reload it before continuing.");

function plansPath(user: string, id: string) { return `${ownerKeyPrefix(user)}/audiobook-plans/${id}`; }
function passagesKey(user: string, id: string) { return `${plansPath(user, id)}/passages.json`; }
function frameKey(user: string, id: string, hash: string) { return `${plansPath(user, id)}/${hash}.png`; }

/** A scene's image is identified by what it pictures, so unchanged scenes keep it across revisions. */
export function sceneHash(prompt: string, plan: Pick<AudiobookPlanDocument, "videoTheme" | "visualGuide">) {
  return createHash("sha256").update(JSON.stringify([plan.videoTheme, plan.visualGuide.trim(), prompt.trim()])).digest("hex").slice(0, 16);
}

async function readJson<T>(store: ObjectStore, key: string): Promise<T> {
  return JSON.parse(new TextDecoder().decode((await store.get(key)).bytes)) as T;
}
const readPassages = (store: ObjectStore, user: string, planId: string) => readJson<StoredPassage[]>(store, passagesKey(user, planId));

function voiceIds() { return audiobookVoices().map(voice => voice.id); }

/** Rejects what no repair can fix. */
function validatePlan(plan: AudiobookPlanDocument, passageCount: number, input: AudiobookCreationInput) {
  const voices = voiceIds();
  const cues = new Set(plan.musicCues.map(cue => cue.id));
  const invalid = plan.speakers.some(speaker => !voices.includes(speaker.voice))
    || new Set(plan.speakers.map(speaker => speaker.voice)).size !== plan.speakers.length
    || cues.size !== plan.musicCues.length
    || plan.chapters.some(chapter => chapter.firstPassage > chapter.lastPassage || chapter.lastPassage >= passageCount || chapter.music.some(id => !cues.has(id)))
    || plan.chapters.reduce((sum, chapter) => sum + chapter.scenes.length, 0) > MAX_AUDIOBOOK_SCENES
    || (input.speakers && (plan.speakers.length !== input.speakers.length || plan.speakers.some((speaker, index) => speaker.voice !== input.speakers![index].voice)));
  if (invalid) throw new ApiError(422, "AUDIOBOOK_PLAN_INVALID", "The plan needs distinct available voices, its own music cues and chapters within the source.");
}

/** About what the book will cost and how long it will run, shown before anything is spent. */
export function audiobookEstimate(plan: AudiobookPlanDocument, row: Pick<Plan, "sourceCharacters" | "sourceSeconds" | "input">, ai: Pick<AiProvider, "imageUsdPerImage" | "musicUsdPerClip" | "speechUsdPerCharacter">) {
  const { sourceSeconds } = row;
  const ratio = narrationRatio(sourceSeconds, row.input.targetSeconds);
  const characters = Math.round(row.sourceCharacters * ratio);
  const perCharacter = plan.speakers.reduce((sum, speaker) => sum + (voiceUsdPerCharacter(speaker.voice) ?? ai.speechUsdPerCharacter()), 0) / plan.speakers.length;
  const scenes = row.input.includeVideo ? plan.chapters.reduce((sum, chapter) => sum + chapter.scenes.length, 0) : 0;
  const usd = characters * (perCharacter + WRITING_USD_PER_CHARACTER) + plan.musicCues.length * ai.musicUsdPerClip() + scenes * ai.imageUsdPerImage();
  return { seconds: Math.round(sourceSeconds * ratio), characters, points: Math.max(1, pointsForCost(usd)) };
}

function planFrames(plan: Plan) {
  let scene = 0;
  return plan.plan.chapters.map(chapter => chapter.scenes.map((item) => {
    const frame = scene++ < MAX_PLAN_FRAMES ? plan.frames[sceneHash(item.prompt, plan.plan)] : undefined;
    return frame ?? null;
  }));
}
/** The plan as the app reads it. `frames` follows chapters and their scenes, with short-lived private links. */
export async function publicAudiobookPlan(plan: Plan, deps: ServiceDeps & { db?: Database } = {}) {
  const store = deps.store ?? getObjectStore();
  const ai = deps.ai ?? await getAiProvider();
  const frames = await Promise.all(planFrames(plan).map(chapter => Promise.all(chapter.map(async frame =>
    frame ? (await store.signedGet(frame.key, { inline: true, expiresInSeconds: 3600 }).catch(() => null))?.url ?? null : null))));
  return { id: plan.id, revision: plan.revision, confirmed: plan.confirmed, plan: plan.plan, messages: plan.messages, frames,
    language: plan.input.language, includeVideo: plan.input.includeVideo, library: true, day: plan.input.day, passageCount: plan.passageCount,
    canDrawFrames: plan.input.includeVideo && !!ai.imageModelId(), estimate: audiobookEstimate(plan.plan, plan, ai) };
}

export async function getAudiobookPlan(db: Database, user: string, id: string) {
  const [plan] = await db.select().from(audiobookPlans).where(and(eq(audiobookPlans.id, id), eq(audiobookPlans.ownerId, user)));
  if (!plan) throw new ApiError(404, "NOT_FOUND", "Audiobook plan not found.");
  return plan;
}
export async function readAudiobookPlan(db: Database, user: string, id: string, deps: ServiceDeps = {}) {
  return publicAudiobookPlan(await getAudiobookPlan(db, user, id), deps);
}

async function loadSources(db: Database, user: string, input: Pick<AudiobookCreationInput, "chipIds" | "summaryId">) {
  if (input.summaryId) {
    const chip = await getSummaryForViewer(db, input.summaryId, user);
    if (chip.kind !== "audiobook" || chip.ownerId !== user) throw new ApiError(404, "NOT_FOUND", "Audiobook not found.");
  }
  const chips = await Promise.all([...new Set(input.chipIds)].map(id => getSummaryForViewer(db, id, user)));
  if (chips.some(chip => chip.kind !== "summary")) throw new ApiError(422, "AUDIOBOOK_SELECTION", "Select source summary chips only.");
  return chips;
}

/**
 * Reads the sources and drafts the plan. Nothing is voiced, scored or drawn. With `planMode` off the plan is confirmed
 * straight away, so generating without review and with review are one path.
 */
export async function createAudiobookPlan(db: Database, user: string, input: AudiobookCreationInput, deps: ServiceDeps = {}) {
  const store = deps.store ?? getObjectStore();
  const ai = deps.ai ?? await getAiProvider();
  const voices = audiobookVoices();
  if (input.speakers?.some(speaker => !voices.some(voice => voice.id === speaker.voice))) throw new ApiError(422, "AUDIOBOOK_PLAN_INVALID", "Choose an available voice for each speaker.");
  if (input.speakers && new Set(input.speakers.map(speaker => speaker.voice)).size !== input.speakers.length) throw new ApiError(422, "AUDIOBOOK_PLAN_INVALID", "Give each speaker a different voice.");
  const chips = await loadSources(db, user, input);
  const passages = await audiobookPassages(chips, user, store);
  for (const source of input.pdfSources ?? []) {
    const pdf = await extractPdfUpload(db, user, { type: "pdf", ...source }, store);
    for (const text of splitPassages(pdf.content.text)) {
      passages.push({ chipId: "upload:" + source.uploadKey, chipTitle: source.filename, text });
    }
  }
  if (passages.reduce((sum, passage) => sum + passage.text.length, 0) > 3_000_000) {
    throw new ApiError(422, "AUDIOBOOK_SOURCE_TOO_LONG", "These sources are too long for one audiobook.");
  }
  const sourceSeconds = passages.reduce((sum, passage) => sum + narrationSeconds(passage.text), 0);
  const ratio = narrationRatio(sourceSeconds, input.targetSeconds);
  const id = randomUUID();
  const videoTheme = input.videoTheme ?? "cinematic";
  const includeVideo = input.includeVideo && !!ai.imageModelId();
  // Scenes are planned even for audio-only books: they cost no images until drawn, and let a video be made later.
  const charge = await reservePodcastPoints(user, `audiobook-plan:${id}`, ai.podcastModelId(), deps.billingEnvironment);
  let cost = 0;
  try {
    const pricing = charge ? await ai.podcastPricing() : null;
    const drafted = await ai.writeAudiobookPlan({
      language: LANGUAGE_NAMES[input.language], title: chips[0]?.title ?? input.pdfSources?.[0]?.filename ?? "Audiobook", includeVideo: true, videoTheme,
      voices: voices.map(({ id, name, gender, description }) => ({ id, name, gender, description })),
      speakers: input.speakers, targetSeconds: sourceSeconds * ratio, sourceSeconds,
      passages: passagesForPlanning(passages), totalPassages: passages.length,
    }, { abortSignal: AbortSignal.timeout(200_000), onUsage: usage => { if (pricing) cost += usageCostUsd(usage, pricing); } });
    const speakers = input.speakers ? input.speakers.map((speaker, index) => ({ ...speaker, role: drafted.speakers[index]?.role ?? "" })) : drafted.speakers;
    const plan = normalizeAudiobookPlan(audiobookPlanSchema.parse({ ...drafted, speakers, videoTheme }), passages, ratio);
    validatePlan(plan, passages.length, input);
    await store.put(passagesKey(user, id), jsonObject(passages));
    const now = (deps.now?.() ?? new Date()).getTime();
    const [row] = await db.insert(audiobookPlans).values({ id, ownerId: user, input: { ...input, includeVideo }, plan, passageCount: passages.length,
      sourceCharacters: passages.reduce((sum, passage) => sum + passage.text.length, 0), sourceSeconds: Math.round(sourceSeconds), createdAt: now, updatedAt: now }).returning();
    for (const source of input.pdfSources ?? []) {
      await db.update(uploads).set({ attachedAt: new Date(now) }).where(eq(uploads.key, source.uploadKey));
    }
    await charge?.settle(Math.max(1, pointsForCost(cost)), { plan: true, textCostUsd: cost });
    if (input.planMode) return { plan: await publicAudiobookPlan(row, { ...deps, ai, store }), job: null };
    const job = await confirmAudiobookPlan(db, user, id, 0, { ...deps, ai, store });
    return { plan: await readAudiobookPlan(db, user, id, { ...deps, ai, store }), job };
  } catch (error) {
    await charge?.settle(0, { failed: true });
    if (error instanceof ApiError) throw error;
    console.error("[audiobook] planning failed", error);
    throw new ApiError(502, "AUDIOBOOK_PLAN_FAILED", "The audiobook couldn't be planned. Please try again.");
  }
}

async function pruneFrames(store: ObjectStore, plan: AudiobookPlanDocument, frames: Plan["frames"]) {
  const used = new Set(plan.chapters.flatMap(chapter => chapter.scenes.map(scene => sceneHash(scene.prompt, plan))));
  const kept: Plan["frames"] = {};
  for (const [hash, frame] of Object.entries(frames)) {
    if (used.has(hash)) kept[hash] = frame;
    else await store.delete(frame.key).catch(() => undefined);
  }
  return kept;
}

/** Saves an edited plan: speakers, voices, chapters, music, scenes or the video theme. */
export async function reviseAudiobookPlan(db: Database, user: string, id: string, revision: number, edited: AudiobookPlanDocument, deps: ServiceDeps = {}) {
  const plan = await getAudiobookPlan(db, user, id);
  if (plan.confirmed || plan.revision !== revision) throw changed();
  const store = deps.store ?? getObjectStore();
  const passages = await readPassages(store, user, id);
  const ratio = narrationRatio(passages.reduce((sum, passage) => sum + narrationSeconds(passage.text), 0), plan.input.targetSeconds);
  const next = normalizeAudiobookPlan(audiobookPlanSchema.parse(edited), passages, ratio);
  validatePlan(next, passages.length, { ...plan.input, speakers: undefined });
  const frames = await pruneFrames(store, next, plan.frames);
  const [updated] = await db.update(audiobookPlans).set({ plan: next, frames, revision: revision + 1, updatedAt: (deps.now?.() ?? new Date()).getTime() }).where(and(
    eq(audiobookPlans.id, id), eq(audiobookPlans.ownerId, user), eq(audiobookPlans.revision, revision), eq(audiobookPlans.confirmed, false))).returning();
  if (!updated) throw changed();
  return publicAudiobookPlan(updated, deps);
}

/** Revises the plan from a chat request; the request and the reply join its chat. */
export async function refineAudiobookPlanChat(db: Database, user: string, id: string, revision: number, message: string, deps: ServiceDeps = {}) {
  const plan = await getAudiobookPlan(db, user, id);
  if (plan.confirmed || plan.revision !== revision) throw changed();
  const ai = deps.ai ?? await getAiProvider();
  const store = deps.store ?? getObjectStore();
  const passages = await readPassages(store, user, id);
  const charge = await reservePodcastPoints(user, `audiobook-plan:${id}:chat:${randomUUID()}`, ai.podcastModelId(), deps.billingEnvironment);
  let cost = 0;
  try {
    const pricing = charge ? await ai.podcastPricing() : null;
    const refined = await ai.refineAudiobookPlan({ language: LANGUAGE_NAMES[plan.input.language], voices: audiobookVoices().map(({ id, name, gender, description }) => ({ id, name, gender, description })),
      plan: plan.plan, passages: passagesForPlanning(passages).map(passage => ({ ...passage, text: passage.text.slice(0, 300) })), totalPassages: passages.length,
      history: plan.messages.map(({ role, text }) => ({ role, text })), request: message,
    }, { abortSignal: AbortSignal.timeout(200_000), onUsage: usage => { if (pricing) cost += usageCostUsd(usage, pricing); } });
    const ratio = narrationRatio(passages.reduce((sum, passage) => sum + narrationSeconds(passage.text), 0), plan.input.targetSeconds);
    const next = normalizeAudiobookPlan(audiobookPlanSchema.parse(refined.plan), passages, ratio);
    validatePlan(next, passages.length, { ...plan.input, speakers: undefined });
    const now = (deps.now?.() ?? new Date()).toISOString();
    const messages: PodcastPlanMessage[] = [...plan.messages,
      { id: randomUUID(), role: "user" as const, text: message, revision, createdAt: now },
      { id: randomUUID(), role: "assistant" as const, text: refined.reply, revision: revision + 1, createdAt: now }].slice(-MAX_PLAN_MESSAGES);
    const frames = await pruneFrames(store, next, plan.frames);
    const [updated] = await db.update(audiobookPlans).set({ plan: next, frames, messages, revision: revision + 1, updatedAt: Date.parse(now) }).where(and(
      eq(audiobookPlans.id, id), eq(audiobookPlans.ownerId, user), eq(audiobookPlans.revision, revision), eq(audiobookPlans.confirmed, false))).returning();
    if (!updated) throw changed();
    await charge?.settle(Math.max(1, pointsForCost(cost)), { plan: true, chat: true, textCostUsd: cost });
    return publicAudiobookPlan(updated, { ...deps, ai, store });
  } catch (error) {
    await charge?.settle(0, { failed: true });
    if (error instanceof ApiError) throw error;
    console.error("[audiobook] refinement failed", error);
    throw new ApiError(502, "AUDIOBOOK_PLAN_REFINE_FAILED", "The plan couldn't be revised. Please try again.");
  }
}

/** Draws the first scenes the plan is missing, so the theme and look can be judged before confirming. */
export async function drawAudiobookPlanFrames(db: Database, user: string, id: string, revision: number, deps: ServiceDeps = {}) {
  const plan = await getAudiobookPlan(db, user, id);
  if (plan.confirmed || plan.revision !== revision) throw changed();
  const ai = deps.ai ?? await getAiProvider();
  const model = ai.imageModelId();
  if (!model || !plan.input.includeVideo) throw new ApiError(503, "AUDIOBOOK_SCENES_UNAVAILABLE", "Scene images are not available right now.");
  const store = deps.store ?? getObjectStore();
  const missing = new Map<string, string>();
  for (const scene of plan.plan.chapters.flatMap(chapter => chapter.scenes).slice(0, MAX_PLAN_FRAMES)) {
    const hash = sceneHash(scene.prompt, plan.plan);
    if (!plan.frames[hash]) missing.set(hash, scene.prompt);
  }
  if (!missing.size) return publicAudiobookPlan(plan, { ...deps, ai, store });
  const charge = await reservePodcastPoints(user, `audiobook-plan:${id}:frames:${randomUUID()}`, model, deps.billingEnvironment);
  const drawn: Record<string, PodcastPlanFrame> = {};
  let attempts = 0;
  try {
    const deadline = AbortSignal.timeout(240_000);
    const queue = [...missing];
    await Promise.all(Array.from({ length: Math.min(FRAME_CONCURRENCY, queue.length) }, async () => {
      for (let next = queue.shift(); next && !deadline.aborted; next = queue.shift()) {
        const [hash, prompt] = next;
        attempts += 1;
        try {
          const image = await ai.drawAudiobookScene({ prompt, theme: plan.plan.videoTheme, visualGuide: plan.plan.visualGuide }, { abortSignal: deadline });
          const key = frameKey(user, id, hash);
          await store.put(key, { bytes: image.png, contentType: "image/png", cacheControl: "private, max-age=31536000, immutable" });
          drawn[hash] = { key, width: image.width, height: image.height };
        } catch (error) {
          console.warn("[audiobook] scene failed", { plan: id, message: (error instanceof Error ? error.message : String(error)).slice(0, 300) });
        }
      }
    }));
    const latest = await getAudiobookPlan(db, user, id);
    const frames = await pruneFrames(store, latest.plan, { ...latest.frames, ...drawn });
    const [updated] = await db.update(audiobookPlans).set({ frames, updatedAt: (deps.now?.() ?? new Date()).getTime() }).where(and(eq(audiobookPlans.id, id), eq(audiobookPlans.ownerId, user))).returning();
    const cost = attempts * ai.imageUsdPerImage();
    await charge?.settle(Object.keys(drawn).length ? Math.max(1, pointsForCost(cost)) : 0, { plan: true, frames: Object.keys(drawn).length, imageCostUsd: cost });
    if (!Object.keys(drawn).length) throw new ApiError(502, "AUDIOBOOK_SCENES_FAILED", "The scene images couldn't be drawn. Please try again.");
    return publicAudiobookPlan(updated, { ...deps, ai, store });
  } catch (error) {
    if (!(error instanceof ApiError && error.code === "AUDIOBOOK_SCENES_FAILED")) await charge?.settle(0, { failed: true });
    throw error;
  }
}

/** The owner's unconfirmed plans, most recently changed first, and audiobooks being made. */
export async function listAudiobookPlans(db: Database, user: string, deps: ServiceDeps = {}) {
  const store = deps.store ?? getObjectStore();
  const rows = await db.select().from(audiobookPlans).where(and(eq(audiobookPlans.ownerId, user), eq(audiobookPlans.confirmed, false)))
    .orderBy(desc(audiobookPlans.updatedAt)).limit(50);
  return Promise.all(rows.map(async (plan) => {
    const cover = planFrames(plan).flat().find(frame => frame);
    return { id: plan.id, revision: plan.revision, title: plan.plan.title, summary: plan.plan.summary, chapterCount: plan.plan.chapters.length, language: plan.input.language, day: plan.input.day,
      createdAt: new Date(plan.createdAt).toISOString(), updatedAt: new Date(plan.updatedAt).toISOString(),
      thumbnailUrl: cover ? (await store.signedGet(cover.key, { inline: true, expiresInSeconds: 3600 }).catch(() => null))?.url ?? null : null };
  }));
}

export async function deleteAudiobookPlan(db: Database, user: string, id: string, deps: ServiceDeps = {}) {
  const plan = await getAudiobookPlan(db, user, id);
  if (plan.confirmed) throw new ApiError(409, "AUDIOBOOK_PLAN_CONFIRMED", "This plan was confirmed and is being made into an audiobook.");
  await db.delete(audiobookPlans).where(and(eq(audiobookPlans.id, id), eq(audiobookPlans.ownerId, user), eq(audiobookPlans.confirmed, false)));
  await removePlanObjects(deps.store ?? getObjectStore(), plan);
}
async function removePlanObjects(store: ObjectStore, plan: Pick<Plan, "ownerId" | "id" | "frames">) {
  await Promise.all([...Object.values(plan.frames).map(frame => store.delete(frame.key).catch(() => undefined)),
    store.delete(passagesKey(plan.ownerId, plan.id)).catch(() => undefined)]);
}

// MARK: Jobs

/** Plain data: the input of `workflows/generate-audiobook.ts`. */
export interface AudiobookJobInput {
  id: string;
  userId: string;
  kind: "generate" | "translate";
  key: string;
  day: PodcastDay;
  /** The language being made, and the plan that generates the original. */
  language: TranslationLanguage;
  planId: string | null;
  includeVideo: boolean;
  billingEnvironment?: BillingEnvironment;
}
type JobDocument = typeof audiobookJobs.$inferSelect["document"];

function visibleJob(document: JobDocument): AudiobookJob {
  const job: AudiobookJob & { chapterProgress?: unknown } = { ...document };
  delete job.chapterProgress;
  if (job.status === "running" && Date.now() - Date.parse(job.updatedAt) > STALE_MS) {
    return { ...job, status: "failed", error: { code: "AUDIOBOOK_STALLED", message: "This audiobook stopped making progress. Retry to continue from where it left off." } };
  }
  return job;
}
export async function audiobookJob(db: Database, user: string, id: string) {
  const [row] = await db.select().from(audiobookJobs).where(and(eq(audiobookJobs.id, id), eq(audiobookJobs.ownerId, user)));
  if (!row) throw new ApiError(404, "NOT_FOUND", "Audiobook job not found.");
  return visibleJob(row.document);
}
/** Jobs still running or needing attention, newest first; finished ones are the library's business. */
export async function listAudiobookJobs(db: Database, user: string) {
  const rows = await db.select().from(audiobookJobs).where(eq(audiobookJobs.ownerId, user)).orderBy(desc(audiobookJobs.createdAt)).limit(50);
  return rows.map(row => visibleJob(row.document)).filter(job => job.status !== "ready");
}
export async function dismissAudiobookJob(db: Database, user: string, id: string) {
  const job = await audiobookJob(db, user, id);
  if (job.status === "running") throw new ApiError(409, "AUDIOBOOK_JOB_RUNNING", "This audiobook is still being made.");
  await db.delete(audiobookJobs).where(and(eq(audiobookJobs.id, id), eq(audiobookJobs.ownerId, user)));
}

/** Applies a change to a job, never moving it backwards once it ended. */
async function patchJob(db: Database, job: Pick<AudiobookJobInput, "id" | "userId">, change: (document: JobDocument) => void) {
  const [row] = await db.select().from(audiobookJobs).where(and(eq(audiobookJobs.id, job.id), eq(audiobookJobs.ownerId, job.userId)));
  if (!row) return;
  const document = row.document;
  change(document);
  document.updatedAt = new Date().toISOString();
  await db.update(audiobookJobs).set({ document }).where(eq(audiobookJobs.id, job.id));
}
/** Work-weighted, not time: music 0–8%, chapters 8–92%, saving the rest. */
async function reportChapter(db: Database, job: AudiobookJobInput, chapter: number, fraction: number, stage: AudiobookJobStage) {
  await patchJob(db, job, (document) => {
    const progress: Record<string, number> = { ...document.chapterProgress, [chapter]: Math.max(document.chapterProgress?.[chapter] ?? 0, fraction) };
    document.chapterProgress = progress;
    document.stage = stage;
    const done = Object.values(progress).reduce((sum, value) => sum + value, 0);
    document.percent = Math.max(document.percent, 8 + Math.floor(84 * done / Math.max(1, document.totalChapters)));
    document.completedChapters = Object.values(progress).filter(value => value >= 1).length;
  });
}

async function startJob(db: Database, input: Omit<AudiobookJobInput, "id">, title: string, chapters: number, summaryId: string | null, deps: ServiceDeps) {
  const job: AudiobookJobInput = { ...input, id: randomUUID() };
  const now = (deps.now?.() ?? new Date()).toISOString();
  const document: JobDocument = { id: job.id, kind: job.kind, status: "running", stage: "queued", percent: 0, planId: job.planId, episodeKey: job.key, language: job.language, day: job.day,
    title, completedChapters: 0, totalChapters: chapters, summaryId, error: null, createdAt: now, updatedAt: now };
  await db.insert(audiobookJobs).values({ id: job.id, ownerId: job.userId, document, createdAt: Date.parse(now) });
  try {
    await getAudiobookStarter().start(job);
  } catch (error) {
    console.error("[audiobook] workflow could not start", error);
    await db.delete(audiobookJobs).where(eq(audiobookJobs.id, job.id));
    throw new ApiError(503, "AUDIOBOOK_UNAVAILABLE", "The audiobook couldn't be started right now. Please try again.");
  }
  return visibleJob(document);
}
/** The job already making this episode's language, which a repeat request joins rather than paying twice. */
async function activeJob(db: Database, user: string, key: string, language: string) {
  const rows = await db.select().from(audiobookJobs).where(eq(audiobookJobs.ownerId, user)).orderBy(desc(audiobookJobs.createdAt)).limit(100);
  return rows.map(row => visibleJob(row.document)).find(job => job.episodeKey === key && job.language === language && job.status !== "failed") ?? null;
}

/**
 * Freezes the reviewed plan and starts the workflow. The balance must cover the estimate; the actual cost is charged when
 * the book is saved, and a failed run is free. Retrying a failed job resumes it, reusing every chapter already voiced.
 */
export async function confirmAudiobookPlan(db: Database, user: string, id: string, revision: number, deps: ServiceDeps = {}, chapters?: number[]) {
  const plan = await getAudiobookPlan(db, user, id);
  if (plan.revision !== revision) throw changed();
  if (chapters) {
    const indices = [...new Set(chapters)].sort((a, b) => a - b);
    if (!indices.length || indices.some(index => !Number.isInteger(index) || index < 0 || index >= plan.plan.chapters.length))
      throw new ApiError(422, "AUDIOBOOK_SELECTION", "Select valid chapters.");
    const batchId = createHash("sha256").update(JSON.stringify([user, id, revision, indices])).digest("hex");
    const store = deps.store ?? getObjectStore();
    const passages = await readPassages(store, user, id);
    await store.put(passagesKey(user, batchId), jsonObject(passages));
    await db.insert(audiobookPlans).values({ ...plan, id: batchId, revision: 0, confirmed: true, frames: {},
      plan: { ...plan.plan, chapters: indices.map(index => plan.plan.chapters[index]) },
    }).onConflictDoNothing();
    return confirmAudiobookPlan(db, user, batchId, 0, deps);
  }
  const existing = await activeJob(db, user, id, plan.input.language);
  if (existing) return existing;
  const ai = deps.ai ?? await getAiProvider();
  await loadSources(db, user, plan.input);
  const estimate = audiobookEstimate(plan.plan, plan, ai);
  const check = await reservePodcastPoints(user, `audiobook:${id}:check:${randomUUID()}`, ai.podcastModelId(), deps.billingEnvironment, estimate.points);
  await check?.settle(0, { check: true });
  if (!plan.confirmed) {
    const [confirmed] = await db.update(audiobookPlans).set({ confirmed: true }).where(and(eq(audiobookPlans.id, id), eq(audiobookPlans.ownerId, user), eq(audiobookPlans.revision, revision))).returning();
    if (!confirmed) throw changed();
  }
  return startJob(db, { userId: user, kind: "generate", key: id, day: plan.input.day, language: plan.input.language, planId: id,
    includeVideo: plan.input.includeVideo, billingEnvironment: deps.billingEnvironment }, plan.plan.title, plan.plan.chapters.length, plan.input.summaryId ?? null, deps);
}

/** Starts speaking a saved audiobook in another language, chapter by chapter, with the same speakers and music. */
export async function startAudiobookTranslation(db: Database, user: string, day: PodcastDay, key: string, input: { language: TranslationLanguage; includeVideo?: boolean }, deps: ServiceDeps = {}) {
  const podcast = await dailyPodcastEpisode(db, user, day, key);
  if (podcast.format !== "audiobook") throw new ApiError(404, "NOT_FOUND", "Audiobook not found.");
  if (input.language === podcast.language) throw new ApiError(422, "PODCAST_TRANSLATION_SAME", "The audiobook is already in this language.");
  if (podcast.translations?.[input.language]) throw new ApiError(409, "PODCAST_TRANSLATION_EXISTS", "This language already exists.");
  const existing = await activeJob(db, user, key, input.language);
  if (existing) return existing;
  const ai = deps.ai ?? await getAiProvider();
  const characters = podcast.segments.reduce((sum, segment) => sum + segment.caption.length, 0);
  const usd = podcast.segments.reduce((sum, segment) => sum + segment.caption.length * (voiceUsdPerCharacter(podcast.speakers[segment.speaker]?.voice ?? "") ?? ai.speechUsdPerCharacter()), 0) + characters * WRITING_USD_PER_CHARACTER;
  const check = await reservePodcastPoints(user, `audiobook:${key}:translate:${input.language}:check:${randomUUID()}`, ai.podcastModelId(), deps.billingEnvironment, Math.max(1, pointsForCost(usd)));
  await check?.settle(0, { check: true });
  return startJob(db, { userId: user, kind: "translate", key, day, language: input.language, planId: null, includeVideo: input.includeVideo !== false && !!podcast.video,
    billingEnvironment: deps.billingEnvironment }, podcast.title, podcast.chapters?.length ?? 1, podcast.summaryId ?? null, deps);
}

// MARK: Workflow steps. Each is resumable: state lives in storage and finished work is skipped.

interface ChapterTurn {
  speaker: number; chipId: string; caption: string; music: string; scene: number;
  imagePath: string | null; icon: string;
  captionCues?: { text: string; startSeconds: number; endSeconds: number; paged?: boolean }[];
  voiced?: boolean;
}
interface ChapterState {
  title: string;
  synopsis?: string;
  turns: ChapterTurn[];
  costUsd: number;
  mixed?: { cues: { startSeconds: number; endSeconds: number }[]; durationSeconds: number };
}
interface MusicState { generated: number; ready: string[] }
type StepDeps = ServiceDeps;

/** Named after what's being made, not the run, so Retry picks up every chapter a failed run finished. */
function jobBase(job: AudiobookJobInput) { return `${dayKey(job.userId, job.day)}/${job.key}/audiobook-work/${job.language}`; }
function chapterKey(job: AudiobookJobInput, chapter: number) { return `${jobBase(job)}/chapter-${chapter}.json`; }
function partKey(job: AudiobookJobInput, chapter: number, turn: number) { return `${jobBase(job)}/chapter-${chapter}/turn-${turn}.mp3`; }
function mixedKey(job: AudiobookJobInput, chapter: number) { return `${jobBase(job)}/chapter-${chapter}/mixed.mp3`; }
function musicKey(user: string, model: string, cue: { prompt: string }) {
  return `${ownerKeyPrefix(user)}/audiobook-music/${model.replace(/[^a-z0-9.-]/gi, "_")}/${createHash("sha256").update(musicBedPrompt(cue.prompt)).digest("hex").slice(0, 32)}.mp3`;
}
async function readOptional<T>(store: ObjectStore, key: string): Promise<T | null> {
  if (!await store.head(key)) return null;
  return readJson<T>(store, key);
}

/** The cues a job needs and how its chapters read: the plan for an original, the saved book for a translation. */
async function jobSource(db: Database, job: AudiobookJobInput) {
  if (job.kind === "generate") {
    const plan = await getAudiobookPlan(db, job.userId, job.planId!);
    return { plan, musicCues: plan.plan.musicCues, chapterCount: plan.plan.chapters.length, podcast: null };
  }
  const podcast = await dailyPodcastEpisode(db, job.userId, job.day, job.key);
  return { plan: null, musicCues: podcast.audiobook?.musicCues ?? [], chapterCount: podcast.chapters?.length ?? 1, podcast };
}

/** Composes the next few missing cues. Returns the chapter count once the soundtrack is ready. */
export async function runAudiobookMusic(db: Database, job: AudiobookJobInput, deps: StepDeps = {}): Promise<{ done: boolean; chapters: number }> {
  const store = deps.store ?? getObjectStore();
  const ai = deps.ai ?? await getAiProvider();
  const { musicCues, chapterCount } = await jobSource(db, job);
  const model = ai.musicModelId();
  const stateKey = `${jobBase(job)}/music.json`;
  const state = await readOptional<MusicState>(store, stateKey) ?? { generated: 0, ready: [] };
  await patchJob(db, job, (document) => { document.stage = "music"; });
  const finish = async () => {
    await patchJob(db, job, (document) => { document.percent = Math.max(document.percent, 8); });
    return { done: true, chapters: chapterCount };
  };
  if (!model) return finish();
  const pending = musicCues.filter(cue => !state.ready.includes(cue.id)).slice(0, MUSIC_BATCH);
  await Promise.all(pending.map(async (cue) => {
    const key = musicKey(job.userId, model, cue);
    try {
      if (!await store.head(key)) {
        const bytes = await ai.composeMusic(musicBedPrompt(cue.prompt), { abortSignal: AbortSignal.timeout(200_000) });
        await store.put(key, { bytes, contentType: "audio/mpeg", cacheControl: "private, max-age=31536000, immutable" });
        state.generated += 1;
      }
    } catch (error) {
      // A cue that can't be composed leaves its stretch to the neighbouring cues; the book still gets made.
      console.warn("[audiobook] music cue failed", { job: job.id, cue: cue.id, message: (error instanceof Error ? error.message : String(error)).slice(0, 300) });
    }
    state.ready.push(cue.id);
  }));
  await store.put(stateKey, jsonObject(state));
  const remaining = musicCues.length - state.ready.length;
  if (remaining > 0) {
    await patchJob(db, job, (document) => { document.percent = Math.max(document.percent, Math.floor(8 * state.ready.length / musicCues.length)); });
    return { done: false, chapters: chapterCount };
  }
  return finish();
}

/** Writes one chapter's turns (or translates them) unless they are already saved. */
export async function runAudiobookChapterScript(db: Database, job: AudiobookJobInput, chapter: number, deps: StepDeps = {}) {
  const store = deps.store ?? getObjectStore();
  if (await store.head(chapterKey(job, chapter))) return;
  const ai = deps.ai ?? await getAiProvider();
  await patchJob(db, job, (document) => { document.stage = "writing"; });
  const pricing = await ai.podcastPricing().catch(() => null);
  let costUsd = 0;
  const onUsage = (usage: LanguageModelUsage) => { if (pricing) costUsd += usageCostUsd(usage, pricing); };
  const abortSignal = AbortSignal.timeout(270_000);
  let state: ChapterState;
  if (job.kind === "generate") {
    const plan = await getAudiobookPlan(db, job.userId, job.planId!);
    const passages = await readPassages(store, job.userId, plan.id);
    const ratio = narrationRatio(passages.reduce((sum, passage) => sum + narrationSeconds(passage.text), 0), plan.input.targetSeconds);
    const item = plan.plan.chapters[chapter];
    const source = passages.slice(item.firstPassage, item.lastPassage + 1);
    const sourceCharacters = source.reduce((sum, passage) => sum + passage.text.length, 0);
    const turns = await ai.writeAudiobookChapter({ language: LANGUAGE_NAMES[plan.input.language], bookTitle: plan.plan.title, chapterIndex: chapter, chapterCount: plan.plan.chapters.length,
      chapter: item, previousSynopsis: plan.plan.chapters[chapter - 1]?.synopsis, nextTitle: plan.plan.chapters[chapter + 1]?.title,
      speakers: plan.plan.speakers.map((speaker, index) => ({ index, name: speaker.name, role: speaker.role })), music: plan.plan.musicCues.map(({ id, title }) => ({ id, title })),
      passages: source.map(passage => passage.text), targetCharacters: Math.max(300, Math.round(sourceCharacters * ratio)), sourceCharacters }, { abortSignal, onUsage });
    const chipId = majorityChip(source);
    const chip = chipId.startsWith("upload:") ? null : await getSummaryForViewer(db, chipId, job.userId);
    state = { title: item.title, synopsis: item.synopsis, costUsd, turns: assignStretches(turns, item.music, item.scenes.length).map(turn => ({ ...turn, chipId, imagePath: chip ? chipArtPath(chip as SummaryRow) : "", icon: "📖" })) };
  } else {
    const podcast = await dailyPodcastEpisode(db, job.userId, job.day, job.key);
    const bounds = podcast.chapters?.[chapter] ?? { title: podcast.title, startSegment: 0, endSegment: podcast.segments.length, synopsis: undefined };
    const segments = podcast.segments.slice(bounds.startSegment, bounds.endSegment);
    const translated = await ai.translatePodcast({ language: LANGUAGE_NAMES[job.language], title: bounds.title, chips: [],
      segments: segments.map(segment => ({ speaker: podcast.speakers[segment.speaker]?.name ?? "", caption: segment.caption })) }, { abortSignal, onUsage });
    if (translated.captions.length !== segments.length) throw new Error("Translated chapter doesn't match the original turns");
    state = { title: translated.title, costUsd, turns: segments.map((segment, index) => ({ speaker: segment.speaker, chipId: segment.chipId, caption: translated.captions[index],
      music: segment.music ?? "", scene: 0, imagePath: segment.imagePath, icon: segment.icon })) };
  }
  await store.put(chapterKey(job, chapter), jsonObject(state));
  await reportChapter(db, job, chapter, 0.15, "voicing");
}

function majorityChip(passages: StoredPassage[]) {
  const counts = new Map<string, number>();
  for (const passage of passages) counts.set(passage.chipId, (counts.get(passage.chipId) ?? 0) + passage.text.length);
  return [...counts].sort((a, b) => b[1] - a[1])[0][0];
}

/**
 * Makes a chapter's music and scenes move forward only and cover the chapter. If the writer left the music on fewer cues
 * than planned, the stretches are spread evenly by length, so a planned change still happens.
 */
export function assignStretches<T extends { caption: string; music: string; scene: number }>(turns: T[], cues: string[], scenes: number): T[] {
  const used = new Set(turns.map(turn => turn.music));
  const total = turns.reduce((sum, turn) => sum + turn.caption.length, 0);
  let elapsed = 0;
  let lastCue = 0;
  let lastScene = 0;
  return turns.map((turn) => {
    const position = total ? elapsed / total : 0;
    elapsed += turn.caption.length;
    const planned = cues.indexOf(turn.music);
    const cue = used.size >= cues.length && planned >= 0 ? Math.max(lastCue, planned) : Math.max(lastCue, Math.min(cues.length - 1, Math.floor(position * cues.length)));
    lastCue = cue;
    const scene = Math.min(Math.max(0, scenes - 1), Math.max(lastScene, turn.scene));
    lastScene = scene;
    return { ...turn, music: cues[cue], scene };
  });
}

/**
 * Voices a chapter's next turns and transcribes them for captions, saving as it goes. Returns whether the chapter is done;
 * the workflow calls it again otherwise, so a long chapter never outlives a function invocation.
 */
export async function runAudiobookChapterVoices(db: Database, job: AudiobookJobInput, chapter: number, deps: StepDeps = {}): Promise<boolean> {
  const store = deps.store ?? getObjectStore();
  const ai = deps.ai ?? await getAiProvider();
  const state = await readJson<ChapterState>(store, chapterKey(job, chapter));
  const speakers = job.kind === "generate"
    ? (await getAudiobookPlan(db, job.userId, job.planId!)).plan.speakers
    : (await dailyPodcastEpisode(db, job.userId, job.day, job.key)).speakers;
  const deadline = Date.now() + VOICE_STEP_MS;
  const abortSignal = AbortSignal.timeout(VOICE_STEP_MS + 60_000);
  for (;;) {
    const pending = state.turns.map((turn, index) => ({ turn, index })).filter(({ turn }) => !turn.voiced).slice(0, VOICE_CONCURRENCY);
    if (!pending.length) return true;
    if (Date.now() > deadline) return false;
    await Promise.all(pending.map(async ({ turn, index }) => {
      const audio = await ai.speak(turn.caption, speakers[turn.speaker]?.voice ?? speakers[0].voice, { abortSignal });
      await store.put(partKey(job, chapter, index), { bytes: audio.bytes, contentType: "audio/mpeg", cacheControl: "private, no-store" });
      turn.captionCues = await captionsFor(ai, turn.caption, audio.bytes, abortSignal);
      turn.voiced = true;
    }));
    await store.put(chapterKey(job, chapter), jsonObject(state));
    await reportChapter(db, job, chapter, 0.15 + 0.7 * state.turns.filter(turn => turn.voiced).length / state.turns.length, "voicing");
  }
}

/** Timed captions from a transcription. A book must not be lost over one turn, so a failed alignment shows the turn whole. */
async function captionsFor(ai: AiProvider, caption: string, audio: Uint8Array, abortSignal: AbortSignal) {
  try {
    return await ai.splitPodcastCaptions(alignPodcastCaptions(caption, await ai.transcribePodcast(audio, { abortSignal })), { abortSignal });
  } catch (error) {
    if (abortSignal.aborted) throw error;
    console.warn("[audiobook] caption alignment failed; using the whole turn", { message: (error instanceof Error ? error.message : String(error)).slice(0, 200) });
    return [{ text: caption, startSeconds: 0, endSeconds: Math.max(0.5, joinPodcastAudio([audio]).durationSeconds) }];
  }
}

/** Mixes a voiced chapter with its stretches of music and frees its separate turns. */
export async function runAudiobookChapterMix(db: Database, job: AudiobookJobInput, chapter: number, deps: StepDeps = {}) {
  const store = deps.store ?? getObjectStore();
  const ai = deps.ai ?? await getAiProvider();
  const state = await readJson<ChapterState>(store, chapterKey(job, chapter));
  if (state.mixed) return;
  await patchJob(db, job, (document) => { document.stage = "mixing"; });
  const { musicCues } = await jobSource(db, job);
  const model = ai.musicModelId();
  const clips = new Map<string, Uint8Array>();
  if (model) {
    for (const id of new Set(state.turns.map(turn => turn.music))) {
      const cue = musicCues.find(item => item.id === id);
      const object = cue ? await store.get(musicKey(job.userId, model, cue)).catch(() => null) : null;
      if (object) clips.set(id, object.bytes);
    }
  }
  const turns = await Promise.all(state.turns.map(async (turn, index) => ({ bytes: (await store.get(partKey(job, chapter, index))).bytes, cue: turn.music })));
  const mixed = await mixAudiobookChapter(turns, clips);
  await store.put(mixedKey(job, chapter), { bytes: mixed.bytes, contentType: "audio/mpeg", cacheControl: "private, no-store" });
  state.mixed = { cues: mixed.cues, durationSeconds: mixed.durationSeconds };
  await store.put(chapterKey(job, chapter), jsonObject(state));
  await Promise.all(state.turns.map((_, index) => store.delete(partKey(job, chapter, index)).catch(() => undefined)));
  await reportChapter(db, job, chapter, 1, "mixing");
}

/** Joins the chapters into one recording and lays every turn and chapter out on its timeline. */
async function assemble(store: ObjectStore, job: AudiobookJobInput, states: ChapterState[], objectKey: string) {
  const parts = await Promise.all(states.map(async (_, chapter) => (await store.get(mixedKey(job, chapter))).bytes));
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

async function speechCost(ai: AiProvider, speakers: DailyPodcast["speakers"], segments: DailyPodcast["segments"]) {
  return segments.reduce((sum, segment) => sum + segment.caption.length * (voiceUsdPerCharacter(speakers[segment.speaker]?.voice ?? "") ?? ai.speechUsdPerCharacter()), 0);
}

async function loadChapterStates(store: ObjectStore, job: AudiobookJobInput, chapters: number) {
  return Promise.all(Array.from({ length: chapters }, (_, chapter) => readJson<ChapterState>(store, chapterKey(job, chapter))));
}

async function cleanJob(store: ObjectStore, job: AudiobookJobInput, states: ChapterState[]) {
  await Promise.all([store.delete(`${jobBase(job)}/music.json`).catch(() => undefined),
    ...states.flatMap((_, chapter) => [store.delete(mixedKey(job, chapter)).catch(() => undefined), store.delete(chapterKey(job, chapter)).catch(() => undefined)])]);
}

/** Saves the finished book or translation, charges for it and queues its video. Safe to run again after a crash. */
export async function finishAudiobook(db: Database, job: AudiobookJobInput, deps: StepDeps = {}) {
  await patchJob(db, job, (document) => { document.stage = "saving"; document.percent = Math.max(document.percent, 92); });
  if (job.kind === "translate") await finishTranslation(db, job, deps);
  else await finishOriginal(db, job, deps);
  await patchJob(db, job, (document) => { document.status = "ready"; document.stage = "complete"; document.percent = 100; document.error = null; delete document.chapterProgress; });
}

async function finishOriginal(db: Database, job: AudiobookJobInput, deps: StepDeps) {
  const store = deps.store ?? getObjectStore();
  const ai = deps.ai ?? await getAiProvider();
  const plan = await getAudiobookPlan(db, job.userId, job.planId!);
  const [existing] = await db.select().from(podcastEpisodes).where(and(eq(podcastEpisodes.key, job.key), eq(podcastEpisodes.ownerId, job.userId)));
  if (existing) return;
  const states = await loadChapterStates(store, job, plan.plan.chapters.length);
  const { segments, chapters, durationSeconds } = await assemble(store, job, states, `${dayKey(job.userId, job.day)}/${job.key}/audio.mp3`);
  const music = !!ai.musicModelId();
  const scenes = planScenes(plan.plan, chapters, states);
  const summaryId = plan.input.summaryId ?? randomUUID();
  const createdAt = deps.now?.() ?? new Date();
  const podcast: DailyPodcast = { title: plan.plan.title, summary: plan.plan.summary, mood: plan.plan.musicCues[0]?.mood ?? "calm",
    speakers: plan.plan.speakers.map(({ name, voice }) => ({ name, voice })), segments, type: "regular", format: "audiobook", chapters,
    audiobook: { musicCues: plan.plan.musicCues, videoTheme: plan.plan.videoTheme, visualGuide: plan.plan.visualGuide, scenes },
    key: job.key, summaryId, language: plan.input.language, day: job.day, chipIds: [...new Set(segments.map(segment => segment.chipId))].filter(id => !id.startsWith("upload:")), createdAt: createdAt.toISOString(), durationSeconds, music };
  podcast.audioPath = episodeAudioPath(podcast);
  // Approved scene images move next to the recording, so the video reuses them instead of drawing them again.
  await copyApprovedScenes(store, job, plan);
  const chips = await Promise.all(podcast.chipIds.map(id => getSummaryForViewer(db, id, job.userId)));
  const existingChip = plan.input.summaryId ? await getSummaryForViewer(db, plan.input.summaryId, job.userId) : null;
  const designed = await podcastCover(db, job.userId, ai, store, summaryId, podcast, chips as SummaryRow[], plan.input.language, createdAt);
  const cover = designed && { ...designed, theme: { ...designed.theme, emoji: "📖" } };
  const episode = db.insert(podcastEpisodes).values({ key: job.key, ownerId: job.userId, dayStart: Date.parse(job.day.start), dayEnd: Date.parse(job.day.end), document: podcast, summaryId });
  if (plan.input.summaryId) {
    await db.batch([episode,
      db.update(podcastEpisodes).set({ isDefault: false }).where(and(eq(podcastEpisodes.summaryId, summaryId), eq(podcastEpisodes.ownerId, job.userId))),
      db.update(podcastEpisodes).set({ isDefault: true }).where(eq(podcastEpisodes.key, job.key)),
      db.update(summaries).set({ title: podcast.title, summary: podcast.summary ?? podcastSummaryText(podcast), language: plan.input.language, updatedAt: createdAt, ...cover })
        .where(and(eq(summaries.id, summaryId), eq(summaries.ownerId, job.userId)))]);
    if (cover && existingChip) {
      await deleteObjects(store, [existingChip.ogImageKey, existingChip.artImageKey]);
      await retireTranslatedCovers(db, store, [summaryId]);
    }
  } else {
    await db.batch([db.insert(summaries).values({ id: summaryId, slug: randomUUID(), ownerId: job.userId, kind: "audiobook", sourceType: "text", source: "text", title: podcast.title,
      summary: podcast.summary ?? podcastSummaryText(podcast), highlights: chapters.slice(0, 5).map(chapter => chapter.title), category: "Other", tags: [], keywords: [], language: plan.input.language,
      theme: { colors: ["#2A2118", "#8A6A45"], mode: "dark", emoji: "📖", accent: "#8A6A45" }, visibility: "private", createdAt, updatedAt: createdAt, ...cover }), episode,
    db.update(podcastEpisodes).set({ isDefault: true }).where(eq(podcastEpisodes.key, job.key))]);
  }
  runAfter(() => rerankHeadlines(db, job.userId));
  await charge(db, job, ai, states, await speechCost(ai, podcast.speakers, segments), deps);
  await cleanJob(store, job, states);
  await removePlanObjects(store, plan);
  await db.update(audiobookPlans).set({ frames: {} }).where(eq(audiobookPlans.id, plan.id));
  if (job.includeVideo && ai.imageModelId()) {
    const { startAudiobookVideo } = await import("./audiobook-video");
    await startAudiobookVideo(db, job.userId, podcast, { ai, store, billingEnvironment: job.billingEnvironment, now: deps.now }, {}).catch((error) => {
      console.error("[audiobook] video could not start; the book is saved without one", error);
    });
  }
}

/** Where each planned scene falls, from the turns the writer tagged. A chapter's first scene starts with the chapter. */
function planScenes(plan: AudiobookPlanDocument, chapters: PodcastChapter[], states: ChapterState[]): AudiobookScene[] {
  return plan.chapters.flatMap((chapter, index) => chapter.scenes.flatMap((scene, sceneIndex) => {
    const turn = sceneIndex === 0 ? 0 : states[index].turns.findIndex(item => item.scene === sceneIndex);
    return turn < 0 ? [] : [{ chapter: index, segment: chapters[index].startSegment + turn, prompt: scene.prompt, motion: scene.motion }];
  }));
}

export function sceneFile(hash: string) { return `video-assets/audiobook/scene-${hash}.png`; }

async function copyApprovedScenes(store: ObjectStore, job: AudiobookJobInput, plan: Plan) {
  await Promise.all(Object.entries(plan.frames).map(async ([hash, frame]) => {
    try {
      await store.put(`${dayKey(job.userId, job.day)}/${job.key}/${sceneFile(hash)}`, { ...await store.get(frame.key), contentType: "image/png", cacheControl: "private, max-age=31536000, immutable" });
    } catch (error) { console.warn("[audiobook] approved scene could not be copied", { hash, error }); }
  }));
}

async function charge(db: Database, job: AudiobookJobInput, ai: AiProvider, states: ChapterState[], speechUsd: number, deps: StepDeps) {
  const store = deps.store ?? getObjectStore();
  const music = await readOptional<MusicState>(store, `${jobBase(job)}/music.json`);
  const textUsd = states.reduce((sum, state) => sum + state.costUsd, 0);
  const musicUsd = (music?.generated ?? 0) * ai.musicUsdPerClip();
  // Settling is idempotent, so a retried step never charges twice.
  const hold = await reservePodcastPoints(job.userId, `audiobook:${job.id}:charge`, ai.podcastModelId(), job.billingEnvironment);
  await hold?.settle(Math.max(1, pointsForCost(textUsd + speechUsd + musicUsd)), { audiobook: job.kind, chapters: states.length, textCostUsd: textUsd, speechCostUsd: speechUsd, musicCostUsd: musicUsd });
}

async function finishTranslation(db: Database, job: AudiobookJobInput, deps: StepDeps) {
  const store = deps.store ?? getObjectStore();
  const ai = deps.ai ?? await getAiProvider();
  const podcast = await dailyPodcastEpisode(db, job.userId, job.day, job.key);
  if (podcast.translations?.[job.language]) return;
  const states = await loadChapterStates(store, job, podcast.chapters?.length ?? 1);
  const base = translationPath(job.userId, podcast, job.language);
  const { segments, chapters, durationSeconds } = await assemble(store, job, states, `${base}/audio.mp3`);
  const heading = await ai.translatePodcast({ language: LANGUAGE_NAMES[job.language], title: podcast.title, chips: [], segments: [] }, { abortSignal: AbortSignal.timeout(60_000) }).catch(() => null);
  const translation: PodcastTranslation = { language: job.language, title: heading?.title ?? podcast.title, createdAt: (deps.now?.() ?? new Date()).toISOString(), speakers: podcast.speakers,
    segments, chapters, durationSeconds, music: podcast.music, audioPath: episodeAudioPath(podcast, job.language) };
  await updatePodcastDocument(db, job.userId, job.key, (latest) => { latest.translations = { ...latest.translations, [job.language]: translation }; });
  await charge(db, job, ai, states, await speechCost(ai, podcast.speakers, segments), deps);
  await cleanJob(store, job, states);
  if (job.includeVideo && podcast.video) {
    const { cloneAudiobookVideo } = await import("./audiobook-video");
    await cloneAudiobookVideo(db, job.userId, podcast, job.language, store).catch((error) => {
      console.error("[audiobook] translated video could not start", error);
    });
  }
}

export async function failAudiobook(db: Database, job: AudiobookJobInput) {
  await patchJob(db, job, (document) => {
    document.status = "failed";
    document.error = { code: "AUDIOBOOK_FAILED", message: "The audiobook couldn't be finished. Retry to continue from where it left off." };
  });
}

/** Tells the owner a long job ended. Claimed first, so it's delivered at most once. */
export async function notifyAudiobook(db: Database, job: AudiobookJobInput) {
  const [row] = await db.select().from(audiobookJobs).where(and(eq(audiobookJobs.id, job.id), eq(audiobookJobs.ownerId, job.userId)));
  if (!row || row.notifiedAt || row.document.status === "running") return;
  await db.update(audiobookJobs).set({ notifiedAt: Date.now() }).where(eq(audiobookJobs.id, job.id));
  const ready = row.document.status === "ready";
  await deliver(db, job.userId, { aps: { alert: {
    title: ready ? "Audiobook ready" : "Audiobook needs attention",
    body: ready ? `“${row.document.title}” is ready to listen to.` : `“${row.document.title}” couldn't be finished. Open Chippy to retry.`,
  }, sound: "default" }, userId: job.userId }, { collapseId: `audiobook-job:${job.id}` });
}

/** Runs a job's steps in this process, as the workflow does. For tests and local tools. */
export async function runAudiobookJob(db: Database, job: AudiobookJobInput, deps: StepDeps = {}) {
  try {
    let music = await runAudiobookMusic(db, job, deps);
    while (!music.done) music = await runAudiobookMusic(db, job, deps);
    for (let chapter = 0; chapter < music.chapters; chapter++) {
      await runAudiobookChapterScript(db, job, chapter, deps);
      while (!await runAudiobookChapterVoices(db, job, chapter, deps)) { /* the next step continues */ }
      await runAudiobookChapterMix(db, job, chapter, deps);
    }
    await finishAudiobook(db, job, deps);
  } catch (error) {
    await failAudiobook(db, job);
    throw error;
  }
  await notifyAudiobook(db, job);
}
