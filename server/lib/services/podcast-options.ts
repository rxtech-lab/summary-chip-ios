import { podcastVoices } from "@/lib/ai/models";
import type { AiProvider } from "@/lib/ai/provider";
import { TRANSLATION_LANGUAGES, type TranslationLanguage } from "@/lib/contracts/api";
import { MIN_PODCAST_DURATION_SECONDS, MAX_PODCAST_DURATION_SECONDS, MAX_PODCAST_SPEAKER_NAME, PODCAST_VIDEO_STYLES, type PodcastGenerationOptions, type PodcastVideoStyle } from "@/lib/contracts/daily-podcast";

type Localized = Record<TranslationLanguage, string>;

/** How each video style is presented in the generation form; its art direction is in `ai/podcast-video-style.ts`. */
const VIDEO_STYLES: Record<PodcastVideoStyle, { title: Localized; description: Localized; symbol: string; swatch: string[] }> = {
  news: {
    title: { en: "News", "zh-Hans": "新闻", "zh-Hant": "新聞", ja: "ニュース", ko: "뉴스", es: "Noticias", fr: "Actualités", de: "Nachrichten" },
    description: {
      en: "A calm editorial TV explainer with clean ivory-and-teal line art.",
      "zh-Hans": "沉稳的电视新闻解说风格，搭配简洁的象牙白与青绿线条插画。",
      "zh-Hant": "沉穩的電視新聞解說風格，搭配簡潔的象牙白與青綠線條插畫。",
      ja: "落ち着いたテレビ解説風。アイボリーとティールのすっきりした線画で描きます。",
      ko: "아이보리와 청록색의 깔끔한 선화로 그린 차분한 TV 해설 스타일.",
      es: "Un explicativo televisivo sereno con ilustraciones lineales en marfil y verde azulado.",
      fr: "Un décryptage télévisé posé, avec des illustrations au trait ivoire et sarcelle.",
      de: "Ein ruhiger TV-Erklärstil mit klaren Strichzeichnungen in Elfenbein und Petrol.",
    },
    symbol: "tv",
    swatch: ["#F7FAF7", "#009B85", "#203B35", "#DCEAE4"],
  },
  crayon: {
    title: { en: "Crayon", "zh-Hans": "蜡笔", "zh-Hant": "蠟筆", ja: "クレヨン", ko: "크레용", es: "Crayón", fr: "Crayons", de: "Wachsmalstift" },
    description: {
      en: "Hand-drawn crayon doodles on drawing paper, sketched in as the hosts speak.",
      "zh-Hans": "在画纸上手绘的蜡笔涂鸦，随主持人讲解逐笔画出。",
      "zh-Hant": "在畫紙上手繪的蠟筆塗鴉，隨主持人講解逐筆畫出。",
      ja: "画用紙に手描きのクレヨン落書き。ホストの話に合わせて描き足されます。",
      ko: "도화지 위의 손그림 크레용 낙서가 진행자의 말에 맞춰 그려집니다.",
      es: "Garabatos de crayón dibujados a mano sobre papel, que aparecen mientras hablan los presentadores.",
      fr: "Des gribouillis aux crayons sur papier à dessin, tracés au fil de la voix des animateurs.",
      de: "Handgezeichnete Wachsmalkritzeleien auf Zeichenpapier, die entstehen, während die Hosts sprechen.",
    },
    symbol: "pencil.and.scribble",
    swatch: ["#FBF5E6", "#E4572E", "#3A86C8", "#F2B635", "#4FA05A"],
  },
};

const DURATION_TITLES: Record<TranslationLanguage, string[]> = {
  en: ["Long", "Medium", "Short", "Clips"],
  "zh-Hans": ["长", "中", "短", "片段"], "zh-Hant": ["長", "中", "短", "片段"],
  ja: ["長め", "標準", "短め", "クリップ"], ko: ["길게", "보통", "짧게", "클립"],
  es: ["Largo", "Medio", "Corto", "Clips"], fr: ["Long", "Moyen", "Court", "Clips"],
  de: ["Lang", "Mittel", "Kurz", "Clips"],
};

/** The choices the podcast generation form offers, in the reader's language (English by default). */
export function podcastGenerationOptions(ai: Pick<AiProvider, "speechModelId">, language: TranslationLanguage | null): PodcastGenerationOptions {
  const speechModel = ai.speechModelId();
  const lang = language ?? "en";
  return {
    duration: {
      presets: [360, 180, 90, 30].map((seconds, index) => ({ seconds, title: DURATION_TITLES[lang][index] })),
      minSeconds: MIN_PODCAST_DURATION_SECONDS, maxSeconds: MAX_PODCAST_DURATION_SECONDS, defaultSeconds: 360,
    },
    languages: [...TRANSLATION_LANGUAGES],
    speakers: { maxCount: speechModel ? Math.min(4, podcastVoices(speechModel).length) : 0, maxNameLength: MAX_PODCAST_SPEAKER_NAME },
    videoStyles: PODCAST_VIDEO_STYLES.map((id) => {
      const { title, description, symbol, swatch } = VIDEO_STYLES[id];
      return { id, title: title[lang], description: description[lang], symbol, swatch };
    }),
    defaultVideoStyle: "news",
  };
}
