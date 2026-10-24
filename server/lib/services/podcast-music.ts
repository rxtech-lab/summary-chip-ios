import { createHash } from "node:crypto";
import type { AiProvider } from "@/lib/ai/provider";
import type { PodcastMusicMood } from "@/lib/contracts/daily-podcast";
import { ApiError } from "@/lib/http/errors";
import type { ObjectStore } from "@/lib/storage/r2";

/**
 * Theme music for daily podcasts, in the spirit of debate-bot's per-phase Lyria beds. Prompts describe
 * only a mood, never chip content, so each clip is generated once and shared by every episode.
 */
export type MusicRole = "intro" | "bed" | "outro";
export type PodcastMusic = Record<MusicRole, Uint8Array> & { generatedClips: number };

// Lyria writes and sings lyrics unless told otherwise, and reads words like "human", "host" or
// "conversation" as an invitation to add voices, so the prompts describe only instruments and texture.
// Keep the no-vocals line short: a long list of exclusions trips Lyria's prompt filter (PROHIBITED_CONTENT).
const MOODS: Record<PodcastMusicMood, string> = {
  bright: "upbeat modern pop-electronic instrumental, plucked synths, light claps and a bouncy bassline, optimistic and playful, around 110 BPM",
  calm: "gentle lo-fi acoustic instrumental, soft felt piano, nylon guitar and brushed drums, relaxed and easygoing, around 80 BPM",
  focused: "clean modern tech-news instrumental theme, pulsing synth arpeggios, tight electronic drums and a confident bass, crisp and forward-moving, around 100 BPM",
  warm: "indie folk instrumental, acoustic guitar, upright bass, light percussion and a hint of glockenspiel, cosy and inviting, around 90 BPM",
  reflective: "thoughtful cinematic ambient instrumental, sustained piano, soft strings and airy synth pads, sincere and contemplative, around 70 BPM",
};

const ROLES: Record<MusicRole, string> = {
  intro: "A short instrumental intro theme. Opens with a clear, memorable melodic hook played by the lead instrument in the first two seconds, plays the main theme with full energy, then settles into a lighter, sparser groove.",
  bed: "A steady, unobtrusive instrumental background loop. Consistent energy and texture throughout with no build-ups, drops, breaks or endings, so it can loop seamlessly. Sparse in the midrange, carried by soft rhythm and low-register instruments.",
  outro: "An instrumental outro theme. Starts as a light, sparse groove, then restates the main theme with a satisfying final cadence and ends cleanly on a held final chord that rings out.",
};

/** Exported for tests and tooling that inspect prompts without generating. */
export function musicPrompt(mood: PodcastMusicMood, role: MusicRole) {
  return `${ROLES[role]}\n\nStyle: ${MOODS[mood]}.\n\nINSTRUMENTAL ONLY: no vocals, no singing, no lyrics, no spoken word; every melody is played by instruments. Professionally mixed and mastered production music with a clean stereo image.`;
}

/**
 * Loads the mood's intro, background and outro clips from storage, generating any missing ones with
 * Lyria. Returns null when music isn't configured or failed, so the episode is published without music.
 */
export async function podcastMusic(ai: AiProvider, store: ObjectStore, mood: PodcastMusicMood, abortSignal?: AbortSignal): Promise<PodcastMusic | null> {
  const model = ai.musicModelId();
  if (!model) return null;
  let generatedClips = 0;
  try {
    const [intro, bed, outro] = await Promise.all((["intro", "bed", "outro"] as const).map(async (role) => {
      const prompt = musicPrompt(mood, role);
      const path = `podcast-music/${model.replace(/[^a-z0-9.-]/gi, "_")}/${mood}-${role}-${createHash("sha256").update(prompt).digest("hex").slice(0, 16)}.mp3`;
      try { return (await store.get(path)).bytes; }
      catch (error) { if (!(error instanceof ApiError && error.code === "OBJECT_MISSING")) throw error; }
      const bytes = await ai.composeMusic(prompt, { abortSignal });
      generatedClips++;
      await store.put(path, { bytes, contentType: "audio/mpeg", cacheControl: "private, max-age=31536000, immutable" });
      return bytes;
    }));
    return { intro, bed, outro, generatedClips };
  } catch (error) {
    console.error("[podcast] music unavailable, publishing without music", error);
    return null;
  }
}
