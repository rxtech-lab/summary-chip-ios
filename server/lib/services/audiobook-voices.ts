import { createHash } from "node:crypto";
import { getAiProvider, type AiProvider } from "@/lib/ai/provider";
import { audiobookVoices, elevenLabsModelId, speechRoute, VOICE_SAMPLE_TEXT } from "@/lib/ai/voices";
import type { TranslationLanguage } from "@/lib/contracts/api";
import { ApiError } from "@/lib/http/errors";
import { getObjectStore, type ObjectStore } from "@/lib/storage/r2";

/** Where a voice's sample lives. The model and text are part of the name, so changing either draws a new one. */
export function voiceSampleKey(voice: string, language: TranslationLanguage) {
  const model = speechRoute(voice).provider === "elevenlabs" ? elevenLabsModelId() : "azure";
  const hash = createHash("sha256").update(JSON.stringify([model, voice, VOICE_SAMPLE_TEXT[language]])).digest("hex").slice(0, 32);
  return `audiobook-voices/${hash}.mp3`;
}

/**
 * A short private link to a voice's sample. The first request draws it, later ones read it from storage. Samples hold no
 * user content, and only catalog voices and fixed texts can be drawn, so they are shared by every account and free.
 */
export async function voiceSampleUrl(voice: string, language: TranslationLanguage, deps: { ai?: AiProvider; store?: ObjectStore } = {}) {
  if (!audiobookVoices().some(option => option.id === voice)) throw new ApiError(404, "NOT_FOUND", "This voice isn't available.");
  const store = deps.store ?? getObjectStore();
  const key = voiceSampleKey(voice, language);
  if (!await store.head(key)) {
    const ai = deps.ai ?? await getAiProvider();
    let audio;
    try { audio = await ai.speak(VOICE_SAMPLE_TEXT[language], voice, { abortSignal: AbortSignal.timeout(50_000) }); }
    catch (error) {
      console.error("[audiobook] voice sample failed", { voice, error });
      throw new ApiError(502, "AUDIOBOOK_SAMPLE_FAILED", "This voice's sample couldn't be played. Please try again.");
    }
    await store.put(key, { bytes: audio.bytes, contentType: "audio/mpeg", cacheControl: "private, max-age=31536000, immutable" });
  }
  const signed = await store.signedGet(key, { filename: "sample.mp3", inline: true, expiresInSeconds: 3600 });
  return { url: signed.url, expiresAt: signed.expiresAt.toISOString() };
}
