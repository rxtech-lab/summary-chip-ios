import type { Category, TranslationLanguage } from "@/lib/contracts/api";

type Labels = Record<Category, string>;

/** Category names as a translated cover prints them; English covers print the category itself. */
const LABELS: Record<Exclude<TranslationLanguage, "en">, Labels> = {
  "zh-Hans": {
    Technology: "科技", Science: "科学", Business: "商业", Finance: "财经", Politics: "政治", World: "国际",
    Health: "健康", Sports: "体育", Entertainment: "娱乐", Culture: "文化", Education: "教育", Lifestyle: "生活",
    Travel: "旅行", Food: "美食", Opinion: "观点", Research: "研究", Other: "其他",
  },
  "zh-Hant": {
    Technology: "科技", Science: "科學", Business: "商業", Finance: "財經", Politics: "政治", World: "國際",
    Health: "健康", Sports: "體育", Entertainment: "娛樂", Culture: "文化", Education: "教育", Lifestyle: "生活",
    Travel: "旅遊", Food: "美食", Opinion: "觀點", Research: "研究", Other: "其他",
  },
  ja: {
    Technology: "テクノロジー", Science: "科学", Business: "ビジネス", Finance: "金融", Politics: "政治", World: "国際",
    Health: "健康", Sports: "スポーツ", Entertainment: "エンタメ", Culture: "カルチャー", Education: "教育", Lifestyle: "ライフスタイル",
    Travel: "旅行", Food: "グルメ", Opinion: "オピニオン", Research: "研究", Other: "その他",
  },
  ko: {
    Technology: "기술", Science: "과학", Business: "비즈니스", Finance: "금융", Politics: "정치", World: "국제",
    Health: "건강", Sports: "스포츠", Entertainment: "엔터테인먼트", Culture: "문화", Education: "교육", Lifestyle: "라이프스타일",
    Travel: "여행", Food: "음식", Opinion: "오피니언", Research: "연구", Other: "기타",
  },
  es: {
    Technology: "Tecnología", Science: "Ciencia", Business: "Negocios", Finance: "Finanzas", Politics: "Política", World: "Mundo",
    Health: "Salud", Sports: "Deportes", Entertainment: "Entretenimiento", Culture: "Cultura", Education: "Educación", Lifestyle: "Estilo de vida",
    Travel: "Viajes", Food: "Comida", Opinion: "Opinión", Research: "Investigación", Other: "Otros",
  },
  fr: {
    Technology: "Technologie", Science: "Science", Business: "Économie", Finance: "Finance", Politics: "Politique", World: "Monde",
    Health: "Santé", Sports: "Sport", Entertainment: "Divertissement", Culture: "Culture", Education: "Éducation", Lifestyle: "Art de vivre",
    Travel: "Voyage", Food: "Gastronomie", Opinion: "Opinion", Research: "Recherche", Other: "Autre",
  },
  de: {
    Technology: "Technologie", Science: "Wissenschaft", Business: "Wirtschaft", Finance: "Finanzen", Politics: "Politik", World: "Welt",
    Health: "Gesundheit", Sports: "Sport", Entertainment: "Unterhaltung", Culture: "Kultur", Education: "Bildung", Lifestyle: "Lifestyle",
    Travel: "Reisen", Food: "Essen", Opinion: "Meinung", Research: "Forschung", Other: "Sonstiges",
  },
};

export function categoryLabel(category: string, language: TranslationLanguage): string {
  return language === "en" ? category : LABELS[language][category as Category] ?? category;
}
