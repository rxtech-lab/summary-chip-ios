import { z } from "zod";
import { MAX_TEXT_LENGTH, TRANSLATION_LANGUAGES, type TranslationLanguage } from "./api";
import { AUDIOBOOK_SCENE_MOTIONS, audiobookVideoThemeSchema, PODCAST_MUSIC_MOODS, podcastDaySchema, podcastLanguageSchema, podcastSummarySchema, type AudiobookVideoTheme, type PodcastGenerationOptions } from "./daily-podcast";
import type { VoiceOption } from "@/lib/ai/voices";

export const MAX_AUDIOBOOK_SPEAKERS = 8;
export const MAX_AUDIOBOOK_SOURCES = 20;
/** The longest book one run produces; longer sources are condensed to fit. */
export const MAX_AUDIOBOOK_SECONDS = 4 * 3600;
export const MIN_AUDIOBOOK_TARGET_SECONDS = 300;
/** Chapters longer than this are split into parts, so each one mixes within a function's memory and time. */
export const MAX_AUDIOBOOK_CHAPTER_SECONDS = 900;
export const MAX_AUDIOBOOK_CHAPTERS = 60;
export const MAX_AUDIOBOOK_MUSIC_CUES = 40;
export const MAX_AUDIOBOOK_SCENES = 200;

const speakerSchema = z.object({
  name: z.string().trim().min(1).max(40),
  voice: z.string().min(1).max(80),
  /** Who this voice plays: the narrator, a character, an expert. */
  role: z.string().trim().max(200).default(""),
});
const musicCueSchema = z.object({
  id: z.string().regex(/^m[0-9]{1,3}$/),
  title: z.string().trim().min(1).max(80),
  /** Instruments, tempo and feeling. Never names, lyrics or plot. */
  prompt: z.string().trim().min(1).max(500),
  mood: z.enum(PODCAST_MUSIC_MOODS),
});
const sceneSchema = z.object({
  prompt: z.string().trim().min(1).max(800),
  motion: z.enum(AUDIOBOOK_SCENE_MOTIONS),
});
const chapterSchema = z.object({
  title: z.string().trim().min(1).max(120),
  synopsis: z.string().trim().min(1).max(1000),
  /** The source passages this chapter narrates, inclusive. */
  firstPassage: z.number().int().nonnegative(),
  lastPassage: z.number().int().nonnegative(),
  /** Soundtrack in playing order: one cue per stretch of content, reused across chapters when the feeling returns. */
  music: z.array(z.string().regex(/^m[0-9]{1,3}$/)).min(1).max(8),
  scenes: z.array(sceneSchema).max(12),
});
/** The reviewable plan: everything chat and the editors can change before any media is made. */
export const audiobookPlanSchema = z.object({
  title: z.string().trim().min(1).max(120),
  summary: podcastSummarySchema,
  speakers: z.array(speakerSchema).min(1).max(MAX_AUDIOBOOK_SPEAKERS),
  musicCues: z.array(musicCueSchema).min(2).max(MAX_AUDIOBOOK_MUSIC_CUES),
  /** Recurring characters, places and period, repeated in every image prompt so scenes stay consistent. */
  visualGuide: z.string().trim().max(2000),
  videoTheme: audiobookVideoThemeSchema,
  chapters: z.array(chapterSchema).min(1).max(MAX_AUDIOBOOK_CHAPTERS),
});
export type AudiobookPlanDocument = z.infer<typeof audiobookPlanSchema>;
export type AudiobookChapterPlan = AudiobookPlanDocument["chapters"][number];

export const createAudiobookSchema = z.object({
  day: podcastDaySchema,
  language: z.enum(TRANSLATION_LANGUAGES),
  /** Existing chips or direct PDF uploads; uploads never create summary chips. */
  chipIds: z.array(z.string().min(1)).max(MAX_AUDIOBOOK_SOURCES).default([]),
  pdfSources: z.array(z.object({ uploadKey: z.string().min(1).max(300), filename: z.string().min(1).max(300), ocrText: z.string().trim().min(1).max(MAX_TEXT_LENGTH).optional() })).max(MAX_AUDIOBOOK_SOURCES).optional(),
  /** Fixed speakers; omitted means the agent casts them from the source and voice catalog. */
  speakers: z.array(z.object({ name: z.string().trim().min(1).max(40), voice: z.string().min(1).max(80) })).min(1).max(MAX_AUDIOBOOK_SPEAKERS).optional(),
  includeVideo: z.boolean().default(true),
  videoTheme: audiobookVideoThemeSchema.optional(),
  /** Approximate length; omitted narrates the whole source, condensed only past the maximum. */
  targetSeconds: z.number().int().min(MIN_AUDIOBOOK_TARGET_SECONDS).max(MAX_AUDIOBOOK_SECONDS).optional(),
  /** Adds a version to this audiobook chip instead of creating another chip. */
  summaryId: z.string().min(1).optional(),
  /** False skips review: the drafted plan is confirmed at once. */
  planMode: z.boolean().default(false),
}).strict().refine(input => input.chipIds.length + (input.pdfSources?.length ?? 0) > 0 && input.chipIds.length + (input.pdfSources?.length ?? 0) <= MAX_AUDIOBOOK_SOURCES, "Choose between 1 and 20 sources.");
export type AudiobookCreationInput = z.infer<typeof createAudiobookSchema>;
/** What a plan row stores: the request, plus which book a generation of chosen chapters joins and what it chose. */
export type AudiobookPlanInput = AudiobookCreationInput & { bookId?: string; selection?: string };

export const reviseAudiobookPlanSchema = z.object({ revision: z.number().int().nonnegative(), plan: audiobookPlanSchema }).strict();
export const refineAudiobookPlanSchema = z.object({ revision: z.number().int().nonnegative(), message: z.string().trim().min(1).max(2000) }).strict();
export const confirmAudiobookPlanSchema = z.object({ revision: z.number().int().nonnegative(), chapters: z.array(z.number().int().nonnegative()).min(1).max(200).optional() }).strict();
export const createAudiobookTranslationSchema = z.object({ day: podcastDaySchema, language: podcastLanguageSchema, includeVideo: z.boolean().optional() }).strict();
/** Chooses which recording of a chapter the book plays. */
export const selectAudiobookChapterVersionSchema = z.object({ day: podcastDaySchema, chapter: z.string().min(1).max(40), version: z.string().min(1).max(64) }).strict();
export const audiobookVoiceSampleSchema = z.object({ voice: z.string().min(1).max(80), language: z.enum(TRANSLATION_LANGUAGES).default("en") });

export interface AudiobookOptions {
  voices: VoiceOption[];
  languages: TranslationLanguage[];
  themes: (Omit<PodcastGenerationOptions["videoStyles"][number], "id"> & { id: AudiobookVideoTheme })[];
  defaultTheme: AudiobookVideoTheme;
  speakers: { maxCount: number; maxNameLength: number };
  /** Length choices; null seconds narrates the whole source. */
  lengths: { seconds: number | null; title: string }[];
  /** Whether scenes can be illustrated; videos are off without an image model. */
  video: boolean;
}

export type AudiobookJobStage = "queued" | "music" | "writing" | "voicing" | "mixing" | "saving" | "complete";
/** A running or finished generation or translation, polled by the app. */
export interface AudiobookJob {
  id: string;
  kind: "generate" | "translate";
  status: "running" | "ready" | "failed";
  stage: AudiobookJobStage;
  percent: number;
  planId: string | null;
  episodeKey: string;
  language: string;
  day: z.infer<typeof podcastDaySchema>;
  title: string;
  completedChapters: number;
  totalChapters: number;
  summaryId: string | null;
  error: { code: string; message: string } | null;
  createdAt: string;
  updatedAt: string;
  /** Identifies a generation of chosen chapters, so a repeated tap joins it and a failed one resumes. Never sent to clients. */
  selection?: string;
}
