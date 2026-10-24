import { z } from "zod";
import { shareLinkLabelSchema, TRANSLATION_LANGUAGES, ttlDaysSchema } from "./api";

export const podcastDaySchema = z.object({
  start: z.iso.datetime({ offset: true }),
  end: z.iso.datetime({ offset: true }),
}).refine(({ start, end }) => {
  const hours = (Date.parse(end) - Date.parse(start)) / 3_600_000;
  return hours >= 23 && hours <= 25;
}, "Supply one local calendar day (23–25 hours)");
/** `POST /api/v1/daily-podcasts/:key/links`. Omitted ttlDays uses the default lifetime; null never expires. */
export const createPodcastShareLinkSchema = z.object({
  day: podcastDaySchema,
  label: shareLinkLabelSchema.optional(),
  ttlDays: ttlDaysSchema.optional(),
}).strict();
export type CreatePodcastShareLinkInput = z.infer<typeof createPodcastShareLinkSchema>;
/** `PATCH /api/v1/daily-podcasts/:key/links/:linkId`. A new `ttlDays` restarts the lifetime. */
export const patchPodcastShareLinkSchema = z.object({
  label: shareLinkLabelSchema.optional(),
  ttlDays: ttlDaysSchema.optional(),
}).strict();
export type PatchPodcastShareLinkInput = z.infer<typeof patchPodcastShareLinkSchema>;
export const createDailyPodcastSchema = z.object({
  day: podcastDaySchema,
  language: z.enum(TRANSLATION_LANGUAGES),
  regenerate: z.boolean().default(false),
  /** Omitted means all eligible chips. An explicit empty selection is invalid. */
  chipIds: z.array(z.string().min(1)).min(1).optional(),
  /** Library episodes may use chips from any day and never replace a daily default. */
  library: z.boolean().default(false),
  /** Video design runs alongside speech unless the caller chooses audio only. */
  includeVideo: z.boolean().optional(),
});
/** Moods of the shared intro/background/outro music library; the agent picks one per episode. */
export const PODCAST_MUSIC_MOODS = ["bright", "calm", "focused", "warm", "reflective"] as const;
export type PodcastMusicMood = (typeof PODCAST_MUSIC_MOODS)[number];
export const podcastScriptSchema = z.object({
  title: z.string().trim().min(1).max(120),
  mood: z.enum(PODCAST_MUSIC_MOODS),
  speakers: z.array(z.object({ name: z.string().trim().min(1).max(40), voice: z.string().min(1).max(80) })).min(1).max(4),
  segments: z.array(z.object({
    speaker: z.number().int().min(0).max(3),
    chipId: z.string().min(1),
    caption: z.string().trim().min(1).max(500),
  })).min(1),
});
export type PodcastScript = z.infer<typeof podcastScriptSchema>;
export type PodcastDay = z.infer<typeof podcastDaySchema>;
export interface DailyPodcast extends PodcastScript {
  key: string;
  summaryId?: string;
  language: string;
  createdAt: string;
  day: PodcastDay;
  chipIds: string[];
  audioPath?: string;
  durationSeconds?: number;
  /** Whether intro, background and outro music were mixed into the recording. */
  music?: boolean;
  /** The agent-written motion video, rendered on device; `published` is the uploaded render shared links play. */
  video?: PodcastVideoSummary;
  segments: (PodcastScript["segments"][number] & { audioPath?: string; startSeconds?: number; endSeconds?: number;
    /** When the voice is audible within the turn, and its pauses, all in episode seconds; captions are timed against these. */
    captionCues?: { text: string; startSeconds: number; endSeconds: number }[];
    voiceStartSeconds?: number; voiceEndSeconds?: number; pauseSeconds?: number[];
    imagePath: string | null; icon: string })[];
}

/** Maximum size of a published podcast video render (MP4). */
export const MAX_PODCAST_VIDEO_BYTES = 1024 * 1024 * 1024;
export interface PodcastVideoSummary {
  /** Changes whenever the composition is rewritten, so renders and uploads are keyed by it. */
  id: string;
  createdAt: string;
  published?: { videoId: string; byteSize: number; publishedAt: string };
}
/** `GET /api/v1/daily-podcasts/:key/video`: everything the app needs to render on device. */
export interface PodcastVideoSource {
  id: string;
  model: string;
  createdAt: string;
  fps: number;
  width: number;
  height: number;
  /** Titles of the source chips, for scene headings. */
  chips: { id: string; title: string }[];
  /** Project files, scaffold included, keyed by path (src/index.ts is the entry point). */
  files: Record<string, string>;
}
/** `POST /api/v1/daily-podcasts/:key/video`: writes a new composition, replacing the previous one. */
export const createPodcastVideoSchema = z.object({ day: podcastDaySchema }).strict();
/** `POST /api/v1/daily-podcasts/:key/video/upload`: a presigned PUT for the rendered MP4. */
export const podcastVideoUploadSchema = z.object({
  day: podcastDaySchema,
  videoId: z.uuid(),
  byteSize: z.number().int().min(1).max(MAX_PODCAST_VIDEO_BYTES),
}).strict();
/** `POST /api/v1/daily-podcasts/:key/video/publication`: confirms the upload finished. */
export const podcastVideoPublicationSchema = z.object({ day: podcastDaySchema, videoId: z.uuid() }).strict();

/** SSE progress is work-weighted, not remaining time. Video design uses decision-model estimates
 * from streamed implementation and validation evidence, mapped into the stage budget. */
export interface PodcastProgress {
  stage: "preparing" | "script" | "speech" | "music" | "mixing" | "video" | "saving" | "complete" | "video-design";
  percent: number;
  completedSteps?: number;
  completedSegments?: number;
  totalSegments?: number;
}
export type PodcastGenerationEvent =
  | { type: "progress"; progress: PodcastProgress }
  | { type: "complete"; podcast: DailyPodcast }
  | { type: "error"; status: number; error: { code: string; message: string; requestId: string } };
