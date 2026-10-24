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
  })).min(1).max(24),
});
export type PodcastScript = z.infer<typeof podcastScriptSchema>;
export type PodcastDay = z.infer<typeof podcastDaySchema>;
export interface DailyPodcast extends PodcastScript {
  key: string;
  language: string;
  createdAt: string;
  day: PodcastDay;
  chipIds: string[];
  audioPath?: string;
  durationSeconds?: number;
  /** Whether intro, background and outro music were mixed into the recording. */
  music?: boolean;
  segments: (PodcastScript["segments"][number] & { audioPath?: string; startSeconds?: number; endSeconds?: number;
    /** When the voice is audible within the turn, and its pauses, all in episode seconds; captions are timed against these. */
    voiceStartSeconds?: number; voiceEndSeconds?: number; pauseSeconds?: number[];
    imagePath: string | null; icon: string })[];
}
