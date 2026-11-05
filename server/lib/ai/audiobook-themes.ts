import type { TranslationLanguage } from "@/lib/contracts/api";
import type { AudiobookVideoTheme } from "@/lib/contracts/daily-podcast";

type Localized = Record<TranslationLanguage, string>;
interface Theme { art: string; title: Localized; description: Localized; symbol: string; swatch: string[] }

/** How each image-first theme is drawn and presented. Images carry the video, so every theme is an illustration style. */
export const AUDIOBOOK_THEMES: Record<AudiobookVideoTheme, Theme> = {
  cinematic: {
    art: "Cinematic concept art: a film still with dramatic natural light, rich atmosphere, shallow depth of field and a 2.39-style composition inside the 16:9 frame. Painterly realism.",
    title: { en: "Cinematic", "zh-Hans": "电影感", "zh-Hant": "電影感", ja: "シネマティック", ko: "시네마틱", es: "Cinematográfico", fr: "Cinématique", de: "Filmisch" },
    description: { en: "Painted film stills with dramatic light. Suits novels and epics.", "zh-Hans": "光影戏剧化的电影画面，适合小说与史诗。", "zh-Hant": "光影戲劇化的電影畫面，適合小說與史詩。", ja: "劇的な光の映画のような一枚絵。小説や叙事詩に。", ko: "극적인 빛의 영화 같은 장면. 소설과 서사에 어울립니다.", es: "Fotogramas pintados con luz dramática. Ideal para novelas.", fr: "Des plans peints à la lumière dramatique, pour les romans.", de: "Gemalte Filmbilder mit dramatischem Licht, ideal für Romane." },
    symbol: "film", swatch: ["#10151C", "#C9853F", "#3F5E7A", "#E9D8B8"],
  },
  watercolor: {
    art: "Delicate watercolor painting on textured paper: soft bleeding pigments, visible brushwork, luminous washes and quiet white space.",
    title: { en: "Watercolor", "zh-Hans": "水彩", "zh-Hant": "水彩", ja: "水彩", ko: "수채화", es: "Acuarela", fr: "Aquarelle", de: "Aquarell" },
    description: { en: "Soft washes on paper. Suits memoirs and gentle stories.", "zh-Hans": "纸上的柔和晕染，适合回忆录与温柔的故事。", "zh-Hant": "紙上的柔和暈染，適合回憶錄與溫柔的故事。", ja: "紙ににじむ柔らかな色彩。回想録や穏やかな物語に。", ko: "종이에 번지는 부드러운 색. 회고록과 잔잔한 이야기에 어울립니다.", es: "Aguadas suaves sobre papel. Ideal para memorias e historias tranquilas.", fr: "Des lavis doux sur papier, pour les mémoires et les récits tendres.", de: "Sanfte Lasuren auf Papier, ideal für Memoiren und leise Geschichten." },
    symbol: "paintbrush", swatch: ["#F6F1E7", "#7FA6B8", "#D99A8B", "#8BA888"],
  },
  anime: {
    art: "Hand-painted Japanese animation background and character art: expressive faces, luminous skies, clean line work and detailed painted scenery.",
    title: { en: "Anime", "zh-Hans": "动画", "zh-Hant": "動畫", ja: "アニメ", ko: "애니메이션", es: "Anime", fr: "Anime", de: "Anime" },
    description: { en: "Expressive characters and luminous skies. Suits adventures.", "zh-Hans": "生动的人物与明亮的天空，适合冒险故事。", "zh-Hant": "生動的人物與明亮的天空，適合冒險故事。", ja: "表情豊かな人物と輝く空。冒険ものに。", ko: "표정이 풍부한 인물과 빛나는 하늘. 모험담에 어울립니다.", es: "Personajes expresivos y cielos luminosos. Ideal para aventuras.", fr: "Des personnages expressifs et des ciels lumineux, pour l'aventure.", de: "Ausdrucksstarke Figuren und leuchtende Himmel, ideal für Abenteuer." },
    symbol: "sparkles", swatch: ["#7CC4F0", "#F7B7C5", "#FBE7A1", "#34507A"],
  },
  "graphic-novel": {
    art: "Modern graphic novel panel: bold inked outlines, flat limited colors with halftone shading and dynamic framing. No speech bubbles or captions.",
    title: { en: "Graphic Novel", "zh-Hans": "图像小说", "zh-Hant": "圖像小說", ja: "グラフィックノベル", ko: "그래픽 노블", es: "Novela gráfica", fr: "Roman graphique", de: "Graphic Novel" },
    description: { en: "Bold ink and flat color. Suits thrillers and sci-fi.", "zh-Hans": "粗犷墨线与平涂色彩，适合惊悚与科幻。", "zh-Hant": "粗獷墨線與平塗色彩，適合驚悚與科幻。", ja: "力強い墨線とフラットな色。スリラーやSFに。", ko: "굵은 잉크와 평면 색채. 스릴러와 SF에 어울립니다.", es: "Tinta intensa y color plano. Ideal para thrillers y ciencia ficción.", fr: "Encre franche et aplats, pour les thrillers et la SF.", de: "Kräftige Tusche und flache Farben, ideal für Thriller und Sci-Fi." },
    symbol: "book.pages", swatch: ["#111111", "#E23D28", "#F2C14E", "#F4EFE6"],
  },
  storybook: {
    art: "Warm children's picture-book illustration: gouache textures, friendly rounded shapes, cozy palette and gentle storybook charm.",
    title: { en: "Storybook", "zh-Hans": "绘本", "zh-Hant": "繪本", ja: "絵本", ko: "그림책", es: "Cuento ilustrado", fr: "Livre d'images", de: "Bilderbuch" },
    description: { en: "Warm picture-book gouache. Suits fairy tales and young readers.", "zh-Hans": "温暖的绘本水粉，适合童话与小读者。", "zh-Hant": "溫暖的繪本水粉，適合童話與小讀者。", ja: "温かな絵本のグワッシュ。童話や子ども向けに。", ko: "따뜻한 그림책 과슈. 동화와 어린 독자에게 어울립니다.", es: "Gouache cálido de cuento. Ideal para fábulas y público joven.", fr: "Une gouache chaleureuse, pour les contes et les jeunes lecteurs.", de: "Warme Bilderbuch-Gouache, ideal für Märchen und junge Leser." },
    symbol: "book", swatch: ["#FBF0D9", "#E98A5B", "#6FA88C", "#4B5E8C"],
  },
  noir: {
    art: "Black-and-white noir illustration: deep charcoal shadows, hard window light, rain-slick streets and heavy film grain, with at most one muted accent color.",
    title: { en: "Noir", "zh-Hans": "黑色电影", "zh-Hant": "黑色電影", ja: "ノワール", ko: "누아르", es: "Noir", fr: "Noir", de: "Noir" },
    description: { en: "Charcoal shadows and hard light. Suits mysteries and crime.", "zh-Hans": "炭黑阴影与硬朗光线，适合悬疑与犯罪。", "zh-Hant": "炭黑陰影與硬朗光線，適合懸疑與犯罪。", ja: "炭のような影と硬い光。ミステリーや犯罪ものに。", ko: "목탄 같은 그림자와 강한 빛. 미스터리와 범죄물에 어울립니다.", es: "Sombras de carbón y luz dura. Ideal para misterio y crimen.", fr: "Ombres au fusain et lumière dure, pour le polar et le mystère.", de: "Kohleschatten und hartes Licht, ideal für Krimis." },
    symbol: "moon.stars", swatch: ["#0C0C0E", "#3A3A40", "#A9A9B2", "#8E2F2F"],
  },
  documentary: {
    art: "Documentary illustration with the clarity of a museum plate: accurate subjects, natural color, careful detail and a calm editorial composition.",
    title: { en: "Documentary", "zh-Hans": "纪实", "zh-Hant": "紀實", ja: "ドキュメンタリー", ko: "다큐멘터리", es: "Documental", fr: "Documentaire", de: "Dokumentarisch" },
    description: { en: "Accurate, editorial plates. Suits history and non-fiction.", "zh-Hans": "准确、克制的图版，适合历史与非虚构。", "zh-Hant": "準確、克制的圖版，適合歷史與非虛構。", ja: "正確で落ち着いた図版。歴史やノンフィクションに。", ko: "정확하고 차분한 도판. 역사와 논픽션에 어울립니다.", es: "Láminas precisas y editoriales. Ideal para historia y no ficción.", fr: "Des planches précises, pour l'histoire et les essais.", de: "Präzise, redaktionelle Tafeln, ideal für Geschichte und Sachbücher." },
    symbol: "building.columns", swatch: ["#EDE7DA", "#4F6B5C", "#9C6B3F", "#2B3A42"],
  },
};

/** One scene's image prompt: the theme, the book's recurring characters and places, then the moment itself. */
export function audiobookSceneInstruction(scene: { prompt: string; theme: AudiobookVideoTheme; visualGuide: string }) {
  return `Illustrate one scene from a book as a single full-bleed 16:9 image.\n\nStyle: ${AUDIOBOOK_THEMES[scene.theme].art}\n\n`
    + (scene.visualGuide ? `Keep these recurring characters, places and period consistent:\n${scene.visualGuide}\n\n` : "")
    + `Scene: ${scene.prompt}\n\nNo text, letters, captions, logos, borders, watermarks or panels of any kind. Leave the bottom fifth of the frame calm, because subtitles sit there.`;
}
