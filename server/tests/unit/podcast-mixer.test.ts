import { readFileSync } from "node:fs";
import { MPEGDecoder } from "mpg123-decoder";
import { describe, expect, it } from "vitest";
import { joinPodcastAudio } from "@/lib/services/podcast-audio";
import { mixPodcast } from "@/lib/services/podcast-mixer";
import { hasSungLyrics } from "@/lib/ai/music";
import { musicPrompt } from "@/lib/services/podcast-music";
import { analyzeSpeech, speechTiming } from "@/lib/services/podcast-timing";

const fixture = (name: string) => new Uint8Array(readFileSync(new URL(`../fixtures/podcast/${name}.mp3`, import.meta.url)));
const music = { intro: fixture("music"), bed: fixture("music"), outro: fixture("music") };

async function decode(bytes: Uint8Array) {
  const decoder = new MPEGDecoder();
  await decoder.ready;
  try { return decoder.decode(bytes); } finally { decoder.free(); }
}
const level = (samples: Float32Array, rate: number, from: number, to: number) => {
  const part = samples.subarray(Math.floor(from * rate), Math.floor(to * rate));
  return Math.sqrt(part.reduce((sum, x) => sum + x * x, 0) / part.length);
};

describe("podcast music mix", () => {
  it("places voices after the intro, separates topics with music and ends with the outro", async () => {
    const turns = [{ bytes: fixture("one"), topic: "a" }, { bytes: fixture("voice-24k"), topic: "a" }, { bytes: fixture("two"), topic: "b" }];
    const mixed = await mixPodcast(turns, music);
    const [first, second, third] = mixed.cues;
    // The intro plays alone first; a same-topic reply follows quickly; a topic change gets a longer musical break.
    expect(first.startSeconds).toBeGreaterThan(4);
    expect(second.startSeconds - first.endSeconds).toBeCloseTo(0.35, 5);
    expect(third.startSeconds - second.endSeconds).toBeCloseTo(1.6, 5);
    // The 24 kHz voice is resampled, keeping its length.
    expect(second.endSeconds - second.startSeconds).toBeCloseTo(1.2, 1);
    expect(mixed.durationSeconds).toBeGreaterThan(third.endSeconds + 3);

    // One seekable stereo recording, re-readable as a whole.
    expect(joinPodcastAudio([mixed.bytes]).durationSeconds).toBeCloseTo(mixed.durationSeconds, 5);
    const decoded = await decode(mixed.bytes);
    expect(decoded.channelData).toHaveLength(2);
    expect(decoded.sampleRate).toBe(44100);
    const left = decoded.channelData[0];
    // Music is loud alone at the start, quieter under the voices, and nothing clips.
    const intro = level(left, 44100, 0.5, 3);
    expect(intro).toBeGreaterThan(0.05);
    expect(level(left, 44100, first.endSeconds + 0.05, second.startSeconds - 0.05)).toBeLessThan(intro);
    expect(left.reduce((peak, x) => Math.max(peak, Math.abs(x)), 0)).toBeLessThanOrEqual(1);
  });

  it("describes only a mood and an instrumental role to Lyria", () => {
    const prompt = musicPrompt("focused", "bed");
    expect(prompt).toMatch(/INSTRUMENTAL ONLY/);
    expect(prompt).toMatch(/no singing, no vocals, no lyrics/);
    // Words that invite Lyria to add a voice stay out of every prompt.
    for (const role of ["intro", "bed", "outro"] as const) expect(musicPrompt("warm", role)).not.toMatch(/\b(host|human|spoken conversation|talk over)\b/i);
    expect(prompt).toMatch(/loop/);
    expect(musicPrompt("focused", "intro")).not.toBe(prompt);
  });

  it("re-rolls clips whose returned lyrics show sung sections", () => {
    expect(hasSungLyrics("[Verse 1]\nMorning light across the city\n[Chorus]\nWe rise")).toBe(true);
    expect(hasSungLyrics("[Intro]\n[Instrumental]\n[Outro]")).toBe(false);
    expect(hasSungLyrics("[Instrumental chorus]\nSynth lead carries the melody")).toBe(false);
    expect(hasSungLyrics("An upbeat instrumental with plucked synths.")).toBe(false);
    expect(hasSungLyrics("")).toBe(false);
  });
});

describe("podcast speech timing", () => {
  const rate = 1000;
  // Silence 0–0.3s, voice to 1s, a 0.4s pause, voice to 2s, a 0.05s word gap, voice to 2.5s, silence to 3s.
  const samples = new Float32Array(3 * rate).map((_, i) => {
    const t = i / rate;
    const voiced = (t >= 0.3 && t < 1) || (t >= 1.4 && t < 2) || (t >= 2.05 && t < 2.5);
    return voiced ? 0.3 * Math.sin(i) : 0.0005;
  });

  it("finds the voiced span and phrase pauses, ignoring gaps between words", () => {
    const timing = speechTiming(samples, rate)!;
    expect(timing.voiceStart).toBeCloseTo(0.3, 1);
    expect(timing.voiceEnd).toBeCloseTo(2.5, 1);
    expect(timing.pauses).toHaveLength(1);
    expect(timing.pauses[0]).toBeCloseTo(1.2, 1);
    expect(speechTiming(new Float32Array(rate), rate)).toBeNull();
  });

  it("measures recorded turns and tolerates undecodable ones", async () => {
    const [voice, broken] = await analyzeSpeech([fixture("voice-24k"), new Uint8Array([1, 2, 3])]);
    expect(voice!.voiceEnd).toBeGreaterThan(voice!.voiceStart);
    expect(voice!.voiceEnd).toBeLessThanOrEqual(1.3);
    expect(broken).toBeNull();
  });
});
