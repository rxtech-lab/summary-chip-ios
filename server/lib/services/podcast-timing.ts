import { MPEGDecoder } from "mpg123-decoder";

/**
 * Where a spoken turn is actually audible, in seconds from the turn's start. The speech model gives
 * no word timestamps, so captions are timed against these: the voiced span replaces the turn's
 * padded length, and pauses let phrase boundaries snap to the moments the speaker breathes.
 */
export interface SpeechTiming { voiceStart: number; voiceEnd: number; pauses: number[] }

const WINDOW = 0.01;
/** Silence shorter than this is a gap between words, not a phrase break. */
const MIN_PAUSE = 0.15;
/** Quieter than this fraction of loud speech counts as silence (about −26 dB). */
const SILENCE = 0.05;

/** Measures each turn; a turn that can't be decoded gets null and is timed by its cue alone. */
export async function analyzeSpeech(parts: Uint8Array[]): Promise<(SpeechTiming | null)[]> {
  const decoder = new MPEGDecoder();
  await decoder.ready;
  try {
    const timings: (SpeechTiming | null)[] = [];
    for (const bytes of parts) {
      try {
        await decoder.reset();
        const decoded = decoder.decode(bytes);
        timings.push(decoded.samplesDecoded && decoded.channelData.length
          ? speechTiming(decoded.channelData[0].subarray(0, decoded.samplesDecoded), decoded.sampleRate) : null);
      } catch {
        timings.push(null);
      }
    }
    return timings;
  } finally {
    decoder.free();
  }
}

export function speechTiming(samples: Float32Array, rate: number): SpeechTiming | null {
  const size = Math.max(1, Math.round(rate * WINDOW));
  const levels: number[] = [];
  for (let start = 0; start < samples.length; start += size) {
    const end = Math.min(samples.length, start + size);
    let sum = 0;
    for (let i = start; i < end; i++) sum += samples[i] ** 2;
    levels.push(Math.sqrt(sum / (end - start)));
  }
  // Loud speech is the 90th percentile window, so a few peaks don't raise the silence threshold.
  const loud = [...levels].sort((a, b) => a - b)[Math.floor(levels.length * 0.9)] ?? 0;
  if (loud < 1e-4) return null;
  const voiced = levels.map((level) => level >= Math.max(loud * SILENCE, 1e-4));
  const first = voiced.indexOf(true);
  const last = voiced.lastIndexOf(true);
  const pauses: number[] = [];
  for (let i = first + 1, quiet = -1; i <= last; i++) {
    if (!voiced[i]) { if (quiet < 0) quiet = i; continue; }
    if (quiet >= 0 && (i - quiet) * WINDOW >= MIN_PAUSE) pauses.push(round((quiet + i) / 2 * WINDOW));
    quiet = -1;
  }
  return { voiceStart: round(first * WINDOW), voiceEnd: round(Math.min(samples.length / rate, (last + 1) * WINDOW)), pauses };
}

const round = (seconds: number) => Math.round(seconds * 100) / 100;
