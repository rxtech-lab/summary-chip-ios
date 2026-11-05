import type { AiProvider } from "@/lib/ai/provider";
import { AUDIOBOOK_THEMES } from "@/lib/ai/audiobook-themes";
import { audiobookVoices } from "@/lib/ai/voices";
import { TRANSLATION_LANGUAGES, type TranslationLanguage } from "@/lib/contracts/api";
import { MAX_AUDIOBOOK_SPEAKERS, type AudiobookOptions } from "@/lib/contracts/audiobook";
import { AUDIOBOOK_VIDEO_THEMES, MAX_PODCAST_SPEAKER_NAME } from "@/lib/contracts/daily-podcast";

const LENGTHS: Record<TranslationLanguage, string[]> = {
  en: ["Full book", "2 hours", "1 hour", "30 minutes", "15 minutes"],
  "zh-Hans": ["完整全书", "2 小时", "1 小时", "30 分钟", "15 分钟"], "zh-Hant": ["完整全書", "2 小時", "1 小時", "30 分鐘", "15 分鐘"],
  ja: ["全編", "2時間", "1時間", "30分", "15分"], ko: ["전체", "2시간", "1시간", "30분", "15분"],
  es: ["Libro completo", "2 horas", "1 hora", "30 minutos", "15 minutos"], fr: ["Livre entier", "2 heures", "1 heure", "30 minutes", "15 minutes"],
  de: ["Ganzes Buch", "2 Stunden", "1 Stunde", "30 Minuten", "15 Minuten"],
};

/** What the audiobook form offers, in the reader's language. */
export function audiobookOptions(ai: Pick<AiProvider, "imageModelId">, language: TranslationLanguage | null): AudiobookOptions {
  const lang = language ?? "en";
  return {
    voices: audiobookVoices(),
    languages: [...TRANSLATION_LANGUAGES],
    themes: AUDIOBOOK_VIDEO_THEMES.map((id) => {
      const { title, description, symbol, swatch } = AUDIOBOOK_THEMES[id];
      return { id, title: title[lang], description: description[lang], symbol, swatch };
    }),
    defaultTheme: "cinematic",
    speakers: { maxCount: MAX_AUDIOBOOK_SPEAKERS, maxNameLength: MAX_PODCAST_SPEAKER_NAME },
    lengths: [null, 7200, 3600, 1800, 900].map((seconds, index) => ({ seconds, title: LENGTHS[lang][index] })),
    video: !!ai.imageModelId(),
  };
}
