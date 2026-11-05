import type { TranslationLanguage } from "@/lib/contracts/api";

/**
 * The voices audiobooks can use. Ids carry their provider (`elevenlabs:<voice id>`, `azure:<short name>`), so a
 * speaker's stored voice is enough to route speech. Unprefixed ids keep going to `AI_SPEECH_MODEL`. Every voice here
 * is multilingual, because a translation is read by the same speakers as the original.
 */
export type VoiceProvider = "elevenlabs" | "azure";
export interface VoiceOption {
  id: string;
  provider: VoiceProvider;
  name: string;
  gender: "female" | "male";
  /** Accent and character, in English, for the agent and the voice list. */
  description: string;
}

/** AI Gateway model that speaks ElevenLabs voices (`AI_ELEVENLABS_MODEL`). */
export function elevenLabsModelId() {
  return process.env.AI_ELEVENLABS_MODEL?.trim() || "elevenlabs/eleven-multilingual-v2";
}

/** ElevenLabs' premade voices. The Gateway takes voice ids, not the display names its playground shows. */
const ELEVENLABS_VOICES: VoiceOption[] = [
  { id: "elevenlabs:hpp4J3VqNfWAUOO0d1Us", provider: "elevenlabs", name: "Bella", gender: "female", description: "American. Professional, bright and warm." },
  { id: "elevenlabs:CwhRBWXzGAHq8TQ4Fs17", provider: "elevenlabs", name: "Roger", gender: "male", description: "American. Laid-back, casual and resonant." },
  { id: "elevenlabs:EXAVITQu4vr4xnSDxMaL", provider: "elevenlabs", name: "Sarah", gender: "female", description: "American. Mature, reassuring and confident." },
  { id: "elevenlabs:FGY2WhTYpPnrIDTdsKH5", provider: "elevenlabs", name: "Laura", gender: "female", description: "American. Enthusiastic with a quirky attitude." },
  { id: "elevenlabs:IKne3meq5aSn9XLyUdCD", provider: "elevenlabs", name: "Charlie", gender: "male", description: "Australian. Deep, confident and energetic." },
];

const azure = (voice: string, name: string, gender: VoiceOption["gender"], description: string): VoiceOption =>
  ({ id: `azure:${voice}MultilingualNeural`, provider: "azure", name, gender, description });
/** Azure's multilingual neural voices, one or two per language the app speaks. */
const AZURE_VOICES: VoiceOption[] = [
  azure("en-US-Ava", "Ava", "female", "American English. Warm and expressive."),
  azure("en-US-Andrew", "Andrew", "male", "American English. Warm and confident."),
  azure("en-US-Emma", "Emma", "female", "American English. Friendly and clear."),
  azure("en-US-Brian", "Brian", "male", "American English. Easygoing and sincere."),
  azure("en-GB-Ada", "Ada", "female", "British English. Poised and articulate."),
  azure("en-GB-Ollie", "Ollie", "male", "British English. Friendly and bright."),
  azure("zh-CN-Xiaoxiao", "晓晓 Xiaoxiao", "female", "Mandarin Chinese. Warm and lively."),
  azure("zh-CN-Yunyi", "云逸 Yunyi", "male", "Mandarin Chinese. Calm and mature."),
  azure("ja-JP-Masaru", "勝 Masaru", "male", "Japanese. Clear and composed."),
  azure("ko-KR-Hyunsu", "현수 Hyunsu", "male", "Korean. Clear and composed."),
  azure("es-ES-Arabella", "Arabella", "female", "Castilian Spanish. Warm and clear."),
  azure("es-ES-Tristan", "Tristan", "male", "Castilian Spanish. Steady and deep."),
  azure("fr-FR-Vivienne", "Vivienne", "female", "French. Elegant and warm."),
  azure("fr-FR-Remy", "Rémy", "male", "French. Warm and natural."),
  azure("de-DE-Seraphina", "Seraphina", "female", "German. Warm and clear."),
  azure("de-DE-Florian", "Florian", "male", "German. Steady and friendly."),
];

export function azureSpeechConfigured() {
  return Boolean(process.env.AZURE_SPEECH_KEY?.trim() && process.env.AZURE_SPEECH_REGION?.trim());
}

/** The voices offered right now: ElevenLabs through the Gateway, Azure only when its credentials are set. */
export function audiobookVoices(): VoiceOption[] {
  return azureSpeechConfigured() ? [...ELEVENLABS_VOICES, ...AZURE_VOICES] : [...ELEVENLABS_VOICES];
}

/** Who speaks a stored voice id: the provider and the id it knows the voice by. */
export function speechRoute(voice: string): { provider: VoiceProvider | "default"; voice: string } {
  const separator = voice.indexOf(":");
  const provider = separator > 0 ? voice.slice(0, separator) : "";
  if (provider === "elevenlabs" || provider === "azure") return { provider, voice: voice.slice(separator + 1) };
  return { provider: "default", voice };
}

/** Price per character of a catalog voice in USD; null for a default-model voice, which the caller prices. */
export function voiceUsdPerCharacter(voice: string): number | null {
  const route = speechRoute(voice).provider;
  if (route === "default") return null;
  const [name, listPrice] = route === "elevenlabs"
    ? ["AI_ELEVENLABS_USD_PER_CHARACTER", 0.00004] as const // eleven-multilingual-v2 on AI Gateway: US$40 per million
    : ["AZURE_SPEECH_USD_PER_CHARACTER", 0.000016] as const; // Azure neural voices: US$16 per million
  const configured = Number(process.env[name]);
  return process.env[name]?.trim() && Number.isFinite(configured) && configured >= 0 ? configured : listPrice;
}

/** What a voice reads when previewed. Fixed per language, so every sample is drawn once and then served from storage. */
export const VOICE_SAMPLE_TEXT: Record<TranslationLanguage, string> = {
  en: "The rain had stopped by the time she reached the old lighthouse. Inside, a single lamp was still burning.",
  "zh-Hans": "她走到老灯塔时，雨已经停了。塔里，还有一盏灯亮着。",
  "zh-Hant": "她走到老燈塔時，雨已經停了。塔裡，還有一盞燈亮著。",
  ja: "古い灯台にたどり着いたころには、雨はもう上がっていた。中では、ひとつの灯りがまだ燃えていた。",
  ko: "그녀가 오래된 등대에 닿았을 때 비는 이미 그쳐 있었다. 안에는 등불 하나가 아직 타오르고 있었다.",
  es: "Cuando llegó al viejo faro ya había dejado de llover. Dentro, una sola lámpara seguía encendida.",
  fr: "La pluie avait cessé lorsqu'elle atteignit le vieux phare. À l'intérieur, une seule lampe brûlait encore.",
  de: "Als sie den alten Leuchtturm erreichte, hatte der Regen aufgehört. Drinnen brannte noch eine einzige Lampe.",
};
