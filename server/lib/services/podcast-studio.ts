import { randomUUID } from "node:crypto";
import { and, eq } from "drizzle-orm";
import { z } from "zod";
import type { Database } from "@/lib/db/client";
import { podcastDrafts, podcastEpisodes } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { dailyPodcastEpisode, dayKey, jsonObject } from "./daily-podcast";
import type { PodcastDay, PodcastVideoSource } from "@/lib/contracts/daily-podcast";
import { podcastVideoInput, podcastVideoSource } from "./podcast-video";
import { getSummaryForViewer } from "./summaries";
import { getObjectStore } from "@/lib/storage/r2";
import { getAiProvider } from "@/lib/ai/provider";
import { pointsForCost, reservePodcastPoints } from "@/lib/subscription/chat-billing";
import type { BillingEnvironment } from "@/lib/subscription/config";
import { podcastCheckFrames, podcastVideoData } from "@/lib/ai/podcast-video-agent";
import { previewPodcastFrames } from "@/lib/podcast-video/frame-preview";
import { MAX_PODCAST_VIDEO_FILES, MAX_PODCAST_VIDEO_FILE_CHARS, PODCAST_VIDEO_ENTRY, PODCAST_VIDEO_FILE_PATTERN, PODCAST_VIDEO_FPS, PODCAST_VIDEO_HEIGHT, PODCAST_VIDEO_WIDTH, PODCAST_VIDEO_SCAFFOLD, PODCAST_VIDEO_PHRASES, podcastPhraseWindows, validatePodcastVideo } from "@/lib/podcast-video/scaffold";

export const studioPath = z.string().max(160).regex(PODCAST_VIDEO_FILE_PATTERN).refine(p => !Object.hasOwn(PODCAST_VIDEO_SCAFFOLD, p), "Scaffold files are read-only");
export const studioContent = z.string().max(MAX_PODCAST_VIDEO_FILE_CHARS);
export type EpisodeRef = { day: PodcastDay; key: string };
const conflict = () => new ApiError(409, "PODCAST_DRAFT_CHANGED", "The draft changed. Call get_podcast_project and retry with its revision.");

export async function getPodcastProject(db: Database, user: string, ref: EpisodeRef, initialize = true) {
  const episode = await dailyPodcastEpisode(db, user, ref.day, ref.key);
  let [draft] = await db.select().from(podcastDrafts).where(eq(podcastDrafts.key, ref.key));
  if (!draft) {
    if (!initialize) throw new ApiError(404, "PODCAST_DRAFT_MISSING", "Call get_podcast_project first.");
    const source = episode.video ? await podcastVideoSource(db, user, ref.day, ref.key) : undefined;
    const files = Object.fromEntries(Object.entries(source?.files ?? {}).filter(([p]) => studioPath.safeParse(p).success));
    await db.insert(podcastDrafts).values({ key: ref.key, revision: 0, files }).onConflictDoNothing();
    [draft] = await db.select().from(podcastDrafts).where(eq(podcastDrafts.key, ref.key));
  }
  const chips = await Promise.all(episode.chipIds.map(async id => ({ id, title: (await getSummaryForViewer(db, id, user)).title })));
  const input = podcastVideoInput(episode, chips);
  return { revision: draft.revision, files: draft.files, scaffold: PODCAST_VIDEO_SCAFFOLD, entry: PODCAST_VIDEO_ENTRY, speakers: episode.speakers, input };
}

export function editPodcastFiles(files: Record<string, string>, operation: { type: "create" | "edit" | "delete"; path: string; content?: string; oldText?: string; newText?: string }) {
  const path = studioPath.parse(operation.path);
  const next = { ...files };
  if (operation.type === "create") {
    if (Object.hasOwn(next, path)) throw new ApiError(409, "FILE_EXISTS", "Use edit_podcast_file for an existing file.");
    next[path] = studioContent.parse(operation.content);
  } else {
    if (!Object.hasOwn(next, path)) throw new ApiError(404, "FILE_MISSING", "The draft has no such file.");
    if (operation.type === "delete") delete next[path];
    else {
      const oldText = z.string().min(1).parse(operation.oldText);
      const index = next[path].indexOf(oldText);
      if (index < 0 || next[path].indexOf(oldText, index + 1) >= 0) throw new ApiError(409, "EDIT_AMBIGUOUS", "oldText must match exactly once.");
      next[path] = studioContent.parse(next[path].slice(0, index) + z.string().parse(operation.newText) + next[path].slice(index + oldText.length));
    }
  }
  if (Object.keys(next).length > MAX_PODCAST_VIDEO_FILES) throw new ApiError(422, "FILE_LIMIT", `Use at most ${MAX_PODCAST_VIDEO_FILES} generated files.`);
  return next;
}

export async function changePodcastFile(db: Database, user: string, ref: EpisodeRef, revision: number, operation: Parameters<typeof editPodcastFiles>[1]) {
  const project = await getPodcastProject(db, user, ref, false);
  if (project.revision !== revision) throw conflict();
  const files = editPodcastFiles(project.files, operation);
  const updated = await db.update(podcastDrafts).set({ files, revision: revision + 1 }).where(and(eq(podcastDrafts.key, ref.key), eq(podcastDrafts.revision, revision))).returning();
  if (!updated.length) throw conflict();
  return { revision: revision + 1, paths: Object.keys(files) };
}

export async function renderPodcastDraft(db: Database, user: string, ref: EpisodeRef, revision: number, seconds?: number) {
  const project = await getPodcastProject(db, user, ref, false);
  if (project.revision !== revision) throw conflict();
  const { input, files } = project;
  if (seconds !== undefined && seconds >= input.durationSeconds) throw new ApiError(422, "FRAME_OUT_OF_RANGE", "seconds must be less than the episode duration.");
  const issues = await validatePodcastVideo(files);
  if (issues.length) throw new ApiError(422, "PODCAST_SOURCE_INVALID", JSON.stringify(issues));
  const frames = seconds === undefined ? podcastCheckFrames(input) : [{ seconds, speaking: input.segments.some(s => s.voiceStartSeconds <= seconds && seconds < s.voiceEndSeconds) }];
  const preview = await previewPodcastFrames(files, podcastVideoData(input), podcastPhraseWindows(input.segments), frames,
    { fps: PODCAST_VIDEO_FPS, width: PODCAST_VIDEO_WIDTH, height: PODCAST_VIDEO_HEIGHT, durationSeconds: input.durationSeconds, language: input.language }, { png: seconds !== undefined });
  if ("error" in preview) throw new ApiError(422, "PODCAST_PREVIEW_FAILED", preview.error);
  return { project, frames: preview.frames };
}

export async function submitPodcastDraft(db: Database, user: string, ref: EpisodeRef, revision: number) {
  const { project, frames } = await renderPodcastDraft(db, user, ref, revision);
  const issues = frames.flatMap(frame => frame.issues.map(message => ({ seconds: frame.seconds, message })));
  if (issues.length) return { saved: false, revision, issues };
  const id = randomUUID();
  const source: PodcastVideoSource = { id, model: "mcp", createdAt: new Date().toISOString(), fps: PODCAST_VIDEO_FPS, width: PODCAST_VIDEO_WIDTH, height: PODCAST_VIDEO_HEIGHT,
    chips: project.input.chips, files: { ...project.files, ...PODCAST_VIDEO_SCAFFOLD, [PODCAST_VIDEO_PHRASES]: JSON.stringify(podcastPhraseWindows(project.input.segments)) } };
  const sourceFile = `video-${id}.json`;
  await getObjectStore().put(`${dayKey(user, ref.day)}/${ref.key}/${sourceFile}`, jsonObject(source));
  await db.transaction(async tx => {
    const [draft] = await tx.select().from(podcastDrafts).where(eq(podcastDrafts.key, ref.key));
    if (draft?.revision !== revision) throw conflict();
    const [row] = await tx.select().from(podcastEpisodes).where(and(eq(podcastEpisodes.key, ref.key), eq(podcastEpisodes.ownerId, user), eq(podcastEpisodes.deleted, false)));
    if (!row) throw new ApiError(404, "NOT_FOUND", "Podcast not found");
    const episode = row.document;
    episode.video = { id, createdAt: source.createdAt, sourceFile };
    for (const translation of Object.values(episode.translations ?? {})) delete translation.video;
    await tx.update(podcastEpisodes).set({ document: episode }).where(and(eq(podcastEpisodes.key, ref.key), eq(podcastEpisodes.ownerId, user)));
    await tx.update(podcastDrafts).set({ revision: revision + 1 }).where(eq(podcastDrafts.key, ref.key));
  });
  return { saved: true, revision: revision + 1, video: { id, createdAt: source.createdAt }, notes: frames.flatMap(f => f.notes) };
}

/** Standalone private assets; these never silently change a voiced episode's timing or soundtrack. */
export async function generatePodcastAsset(db: Database, user: string, ref: EpisodeRef, input: { type: "speech"; text: string; voice: string } | { type: "music"; prompt: string }, environment?: BillingEnvironment) {
  await dailyPodcastEpisode(db, user, ref.day, ref.key);
  const ai = await getAiProvider();
  const model = input.type === "speech" ? ai.speechModelId() : ai.musicModelId();
  if (!model) throw new ApiError(503, "PODCAST_ASSET_UNAVAILABLE", `${input.type} generation is not configured.`);
  const id = randomUUID();
  const charge = await reservePodcastPoints(user, `${ref.key}:asset:${id}`, model, environment);
  try {
    const options = { abortSignal: AbortSignal.timeout(200_000) };
    const audio = input.type === "speech" ? await ai.speak(input.text, input.voice, options) : { bytes: await ai.composeMusic(input.prompt, options), mediaType: "audio/mpeg" };
    const path = `${dayKey(user, ref.day)}/${ref.key}/assets/${id}.mp3`;
    const store = getObjectStore();
    await store.put(path, { bytes: audio.bytes, contentType: audio.mediaType, cacheControl: "private, no-store" });
    const signed = await store.signedGet(path, { filename: `${input.type}.mp3` });
    const cost = input.type === "speech" ? input.text.length * ai.speechUsdPerCharacter() : ai.musicUsdPerClip();
    await charge?.settle(Math.max(1, pointsForCost(cost)), { assetType: input.type, costUsd: cost });
    return { assetId: id, downloadUrl: signed.url, expiresAt: signed.expiresAt.toISOString(), mimeType: audio.mediaType, byteSize: audio.bytes.length };
  } catch (error) { await charge?.settle(0, { failed: true }); throw error; }
}
