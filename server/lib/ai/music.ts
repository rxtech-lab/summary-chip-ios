/**
 * Google Lyria music generation over the Gemini REST API (`GEMINI_API_KEY`), used for podcast
 * intro, background and outro music. Lyria isn't served by the AI Gateway, so this calls Google
 * directly. Ported from debate-bot's musicgen client: one POST returns base64 MP3 audio.
 */

/** Lyria model id (`AI_MUSIC_MODEL`). The clip model returns 30 seconds of 48 kHz stereo audio. */
export function musicModelId(): string | null {
  if (!process.env.GEMINI_API_KEY?.trim() || process.env.AI_MUSIC_MODEL?.trim() === "off") return null;
  return process.env.AI_MUSIC_MODEL?.trim() || "lyria-3-clip-preview";
}

/** Price per generated clip in USD (`AI_MUSIC_USD_PER_CLIP`), Lyria 3 Clip's $0.04 by default. */
export function musicUsdPerClip(): number {
  const configured = Number(process.env.AI_MUSIC_USD_PER_CLIP);
  return process.env.AI_MUSIC_USD_PER_CLIP?.trim() && Number.isFinite(configured) && configured >= 0 ? configured : 0.04;
}

class RetryableError extends Error {}

/** Transient transport errors, 429/5xx, Lyria's stochastic content filter (finishReason OTHER and similar) and clips with sung lyrics are re-rolled. */
const ATTEMPTS = 4;

export async function composeMusic(prompt: string, options?: { abortSignal?: AbortSignal }): Promise<Uint8Array> {
  const model = musicModelId();
  if (!model) throw new Error("Music generation is not configured (GEMINI_API_KEY)");
  let last: unknown;
  for (let attempt = 0; attempt < ATTEMPTS; attempt++) {
    if (attempt) await new Promise((resolve) => setTimeout(resolve, 750 * 2 ** (attempt - 1)));
    options?.abortSignal?.throwIfAborted();
    try {
      return await composeOnce(model, prompt, options?.abortSignal);
    } catch (error) {
      last = error;
      if (!(error instanceof RetryableError)) throw error;
    }
  }
  throw new Error(`Lyria failed after ${ATTEMPTS} attempts`, { cause: last });
}

interface LyriaResponse {
  candidates?: { content?: { parts?: { text?: string; inlineData?: { mimeType?: string; data?: string } }[] }; finishReason?: string; finishMessage?: string }[];
}

async function composeOnce(model: string, prompt: string, abortSignal?: AbortSignal) {
  let response: Response;
  try {
    response = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent`, {
      method: "POST",
      headers: { "x-goog-api-key": process.env.GEMINI_API_KEY!.trim(), "content-type": "application/json" },
      // Lyria returns MP3 by default; responseMimeType only accepts text types, so it's omitted.
      body: JSON.stringify({ contents: [{ parts: [{ text: prompt }] }], generationConfig: { responseModalities: ["AUDIO", "TEXT"] } }),
      signal: abortSignal ? AbortSignal.any([abortSignal, AbortSignal.timeout(120_000)]) : AbortSignal.timeout(120_000),
    });
  } catch (error) {
    if (abortSignal?.aborted) throw error;
    throw new RetryableError("Lyria request failed", { cause: error });
  }
  const text = await response.text().catch((error) => { throw new RetryableError("Lyria body was cut off", { cause: error }); });
  if (!response.ok) {
    const message = `Lyria ${response.status}: ${text.slice(0, 400)}`;
    throw response.status === 429 || response.status >= 500 ? new RetryableError(message) : new Error(message);
  }
  const parsed = JSON.parse(text) as LyriaResponse;
  // Lyria returns the lyrics it sang as text; a clip with sung sections is re-rolled, never used.
  const lyrics = parsed.candidates?.flatMap((c) => c.content?.parts ?? []).map((part) => part.text ?? "").join("\n") ?? "";
  if (hasSungLyrics(lyrics)) throw new RetryableError(`Lyria added vocals: ${lyrics.slice(0, 200)}`);
  for (const candidate of parsed.candidates ?? []) {
    for (const part of candidate.content?.parts ?? []) {
      if (part.inlineData?.data && (part.inlineData.mimeType ?? "audio/mpeg").startsWith("audio/")) {
        return Uint8Array.from(Buffer.from(part.inlineData.data, "base64"));
      }
    }
  }
  const filtered = parsed.candidates?.find((c) => ["OTHER", "SAFETY", "RECITATION", "PROHIBITED_CONTENT"].includes(c.finishReason?.toUpperCase() ?? ""));
  if (filtered) throw new RetryableError(`Lyria filter (${filtered.finishReason}): ${filtered.finishMessage?.slice(0, 200) ?? ""}`);
  throw new Error(`Lyria returned no audio: ${text.slice(0, 400)}`);
}

/** True when Lyria's text describes a vocal section (verse, chorus…) followed by lyric lines. */
export function hasSungLyrics(text: string): boolean {
  let vocalSection = false;
  for (const line of text.split("\n").map((l) => l.trim()).filter(Boolean)) {
    const tag = /^[[(](.*)[\])]$/.exec(line)?.[1];
    if (tag !== undefined) { vocalSection = /verse|chorus|hook|refrain|bridge|rap|vocal/i.test(tag) && !/instrumental/i.test(tag); continue; }
    if (vocalSection) return true;
  }
  return false;
}
