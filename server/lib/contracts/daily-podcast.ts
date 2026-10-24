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
  /** Regenerates this library podcast chip as a new version instead of creating another chip. */
  summaryId: z.string().min(1).optional(),
}).refine((input) => !input.summaryId || input.library, { message: "summaryId requires library", path: ["summaryId"] });
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
/** One spoken language of an episode. Segments match the original's one to one (speaker, chip, order). */
export interface PodcastTranslation {
  language: string;
  title: string;
  createdAt: string;
  speakers: PodcastScript["speakers"];
  segments: DailyPodcast["segments"];
  audioPath?: string;
  durationSeconds?: number;
  music?: boolean;
  /** Translated source chip titles by chip id, used for the video's section headings. */
  chipTitles?: Record<string, string>;
  /** The original composition with translated labels; `sourceId` is the original video it was made from. */
  video?: PodcastVideoSummary & { sourceId?: string };
}
export interface DailyPodcast extends PodcastScript {
  key: string;
  summaryId?: string;
  /** The language this document is presented in; `originalLanguage` is the one it was generated in. */
  language: string;
  originalLanguage?: string;
  /** Every language the episode can play in, the original first. Only set on API responses. */
  languages?: string[];
  /** Stored translations by language. Never sent to clients: they request one language at a time. */
  translations?: Record<string, PodcastTranslation>;
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
/** A language query/body field: omitted or the original language selects the original recording. */
export const podcastLanguageSchema = z.enum(TRANSLATION_LANGUAGES);
/** The optional `?language=` of episode, audio and video reads. */
export function podcastLanguageQuery(query: URLSearchParams) {
  const language = query.get("language");
  return language ? podcastLanguageSchema.parse(language) : undefined;
}
/** `POST /api/v1/daily-podcasts/:key/translations`: speaks the episode in another language (spends points). */
export const createPodcastTranslationSchema = z.object({
  day: podcastDaySchema,
  language: podcastLanguageSchema,
  /** Translate the video's labels too when the episode has a video (default true). */
  includeVideo: z.boolean().optional(),
}).strict();
/** `POST /api/v1/daily-podcasts/:key/video`: writes a new composition, replacing the previous one.
 * With a translation `language`, that translation gets the current composition with translated labels. */
export const createPodcastVideoSchema = z.object({ day: podcastDaySchema, language: podcastLanguageSchema.optional() }).strict();
/** `POST /api/v1/daily-podcasts/:key/video/upload`: a presigned PUT for the rendered MP4. */
export const podcastVideoUploadSchema = z.object({
  day: podcastDaySchema,
  videoId: z.uuid(),
  byteSize: z.number().int().min(1).max(MAX_PODCAST_VIDEO_BYTES),
  language: podcastLanguageSchema.optional(),
}).strict();
/** `POST /api/v1/daily-podcasts/:key/video/publication`: confirms the upload finished. */
export const podcastVideoPublicationSchema = z.object({ day: podcastDaySchema, videoId: z.uuid(), language: podcastLanguageSchema.optional() }).strict();

/** SSE progress is work-weighted, not remaining time. Video design uses decision-model estimates
 * from streamed implementation and validation evidence, mapped into the stage budget. */
export interface PodcastProgress {
  stage: "preparing" | "script" | "translating" | "speech" | "music" | "mixing" | "video" | "saving" | "complete" | "video-design";
  percent: number;
  completedSteps?: number;
  completedSegments?: number;
  totalSegments?: number;
}
export type PodcastGenerationEvent =
  | { type: "progress"; progress: PodcastProgress }
  | { type: "complete"; podcast: DailyPodcast }
  | { type: "error"; status: number; error: { code: string; message: string; requestId: string } };
