import { MPEGDecoder } from "mpg123-decoder";
import { Mp3Encoder } from "@breezystack/lamejs";
import { joinPodcastAudio } from "./podcast-audio";
import type { PodcastMusic } from "./podcast-music";

/**
 * Mixes spoken turns with theme music into one produced episode, in pure JS/WASM so it runs on
 * Vercel without an FFmpeg binary. Unlike debate-bot's realtime PCM mixer (musicmixer), the whole
 * episode is known up front, so it's laid out on one timeline and encoded once:
 *
 *   intro theme alone → ducks under the welcome → background bed under the conversation, swelling
 *   between topics → outro rises under the sign-off and rings out.
 *
 * Music levels are set relative to the voices' measured loudness, so loud masters and quiet speech
 * models balance the same way.
 */
const RATE = 44100;
const KBPS = 128;

/** Silence between turns about the same chip, and the musical breath when the topic changes. */
const TURN_GAP = 0.35;
const TOPIC_GAP = 1.6;
/** The intro plays alone before the first word, then continues quietly under the welcome. */
const INTRO_SOLO = 5;
const INTRO_UNDER = 6;
/** The outro enters under the last words, then rises once they finish. */
const OUTRO_UNDER = 4;
const OUTRO_MAX = 18;
const FADE = 3;
const BED_CROSSFADE = 2;

/** Music gain relative to voice loudness (RMS): theme at full, under speech, background, topic swell. */
const FULL = 0.85;
const UNDER = 0.2;
const BED = 0.1;
const SWELL = 0.4;

interface Stereo { left: Float32Array; right: Float32Array }
type Envelope = [seconds: number, gain: number][];

export interface MixedPodcast {
  bytes: Uint8Array;
  cues: { startSeconds: number; endSeconds: number }[];
  durationSeconds: number;
}

const CHAPTER_INTRO = 4;
const CHAPTER_BREATH = 2.4;
const CHAPTER_TAIL = 5;
const SILENT_INTRO = 0.6;
const SILENT_TAIL = 1;

/**
 * Mixes one audiobook chapter. Each run of turns under the same cue gets its own looped bed: it rises in the chapter's
 * opening or the breath before the run, sits quietly under the voices, and crossfades into the next cue where the
 * content changes. Without clips the voices are laid out alone, still resampled to one rate, so speakers
 * from different providers join into one recording.
 */
export async function mixAudiobookChapter(turns: { bytes: Uint8Array; cue?: string }[], clips: Map<string, Uint8Array>): Promise<MixedPodcast> {
  const decoder = new MPEGDecoder();
  await decoder.ready;
  const speech: Stereo[] = [];
  const beds = new Map<string, Stereo>();
  try {
    const decode = async (bytes: Uint8Array) => { await decoder.reset(); return decodeStereo(decoder, bytes); };
    for (const turn of turns) speech.push(await decode(turn.bytes));
    for (const [id, bytes] of clips) {
      // A clip that can't be decoded leaves its stretch to a neighbouring cue, not the whole chapter silent.
      try { beds.set(id, await decode(bytes)); } catch (error) { console.warn("[audiobook] music clip could not be decoded", { id, error }); }
    }
  } finally {
    decoder.free();
  }
  const scored = beds.size > 0;
  const fallback = [...beds.keys()][0];
  const cueOf = (index: number) => { const cue = turns[index].cue; return cue && beds.has(cue) ? cue : fallback; };

  const cues: MixedPodcast["cues"] = [];
  const runs: { cue: string; breakStart: number; voiceStart: number; voiceEnd: number }[] = [];
  let at = scored ? CHAPTER_INTRO : SILENT_INTRO;
  speech.forEach((turn, index) => {
    if (index) {
      const changed = scored && cueOf(index) !== cueOf(index - 1);
      const breakStart = at;
      at += changed ? CHAPTER_BREATH : TURN_GAP;
      if (changed) runs.push({ cue: cueOf(index), breakStart, voiceStart: at, voiceEnd: at });
    } else if (scored) {
      runs.push({ cue: cueOf(0), breakStart: 0, voiceStart: at, voiceEnd: at });
    }
    cues.push({ startSeconds: at, endSeconds: at + seconds(turn) });
    at += seconds(turn);
    if (runs.length) runs[runs.length - 1].voiceEnd = at;
  });
  const total = at + (scored ? CHAPTER_TAIL : SILENT_TAIL);
  const out = { left: new Float32Array(Math.ceil(total * RATE)), right: new Float32Array(Math.ceil(total * RATE)) };
  const voice = rms(speech);
  runs.forEach((run, index) => {
    const bed = beds.get(run.cue)!;
    const level = rms([bed]);
    const gain = level > 1e-4 && voice > 1e-4 ? voice / level : 0;
    const next = runs[index + 1];
    const end = next ? next.voiceStart : total;
    // The opening and each breath let the new cue be heard before the voice returns over it.
    const envelope: Envelope = [[run.breakStart, 0], [run.breakStart + 1, SWELL * gain], [run.voiceStart - 0.4, SWELL * gain], [run.voiceStart, BED * gain],
      [run.voiceEnd, BED * gain], [run.voiceEnd + 0.5, SWELL * gain], [end - (next ? 0.4 : FADE), SWELL * gain], [end, 0]];
    mixIn(out, loop(bed, end - run.breakStart), run.breakStart, end, envelope);
  });
  speech.forEach((turn, index) => mixIn(out, turn, cues[index].startSeconds, cues[index].endSeconds, [[0, 1]]));
  const joined = joinPodcastAudio([encode(out)]);
  return { bytes: joined.bytes, cues, durationSeconds: joined.durationSeconds };
}

export async function mixPodcast(turns: { bytes: Uint8Array; topic: string }[], music: Omit<PodcastMusic, "generatedClips">): Promise<MixedPodcast> {
  const decoder = new MPEGDecoder();
  await decoder.ready;
  let speech: Stereo[], intro: Stereo, bed: Stereo, outro: Stereo;
  try {
    const decode = async (bytes: Uint8Array) => { await decoder.reset(); return decodeStereo(decoder, bytes); };
    speech = [];
    for (const turn of turns) speech.push(await decode(turn.bytes));
    intro = await decode(music.intro);
    bed = await decode(music.bed);
    outro = await decode(music.outro);
  } finally {
    decoder.free();
  }

  // Lay out the voices.
  const introSolo = Math.min(INTRO_SOLO, Math.max(1, seconds(intro) - FADE));
  const cues: MixedPodcast["cues"] = [];
  const topicBreaks: [number, number][] = [];
  let at = introSolo;
  speech.forEach((turn, index) => {
    if (index) {
      const gap = turns[index].topic === turns[index - 1].topic ? TURN_GAP : TOPIC_GAP;
      if (gap === TOPIC_GAP) topicBreaks.push([at, at + gap]);
      at += gap;
    }
    cues.push({ startSeconds: at, endSeconds: at + seconds(turn) });
    at += seconds(turn);
  });
  const speechEnd = at;
  const outroStart = Math.max(introSolo, speechEnd - OUTRO_UNDER);
  const outroLength = Math.min(seconds(outro), OUTRO_MAX);
  const total = Math.max(speechEnd, outroStart + outroLength) + 0.5;
  const out = { left: new Float32Array(Math.ceil(total * RATE)), right: new Float32Array(Math.ceil(total * RATE)) };

  const voice = rms(speech);
  const scale = (clip: Stereo) => { const level = rms([clip]); return level > 1e-4 && voice > 1e-4 ? voice / level : 0; };

  // Intro: full, ducking just before the first word, then fading out under the welcome.
  const introEnd = Math.min(seconds(intro), introSolo + INTRO_UNDER + FADE);
  const introGain = scale(intro);
  mixIn(out, intro, 0, introEnd, [[0, FULL * introGain], [introSolo - 0.8, FULL * introGain], [introSolo, UNDER * introGain],
    [introEnd - FADE, UNDER * introGain], [introEnd, 0]]);

  // Background bed: enters as the intro leaves, swells in each topic change, leaves for the outro.
  const bedStart = introEnd - FADE;
  const bedEnd = outroStart + 1;
  if (bedEnd - bedStart > FADE * 2) {
    const bedGain = scale(bed);
    const envelope: Envelope = [[bedStart, 0], [bedStart + FADE, BED * bedGain]];
    for (const [start, end] of topicBreaks) {
      if (start - 0.3 <= bedStart + FADE || end + 0.3 >= bedEnd - FADE) continue;
      envelope.push([start - 0.3, BED * bedGain], [start + 0.3, SWELL * bedGain], [end - 0.3, SWELL * bedGain], [end + 0.3, BED * bedGain]);
    }
    envelope.push([bedEnd - FADE, BED * bedGain], [bedEnd, 0]);
    mixIn(out, loop(bed, bedEnd - bedStart), bedStart, bedEnd, envelope);
  }

  // Outro: under the sign-off, rising after the last word and ringing out.
  const outroGain = scale(outro);
  const rise = Math.min(speechEnd + 0.2, outroStart + outroLength - FADE - 1);
  mixIn(out, outro, outroStart, outroStart + outroLength, [[outroStart, 0], [outroStart + 1, UNDER * outroGain], [rise, UNDER * outroGain],
    [rise + 1, FULL * outroGain], [outroStart + outroLength - FADE, FULL * outroGain], [outroStart + outroLength, 0]]);

  speech.forEach((turn, index) => mixIn(out, turn, cues[index].startSeconds, cues[index].endSeconds, [[0, 1]]));

  const encoded = encode(out);
  // Re-reading the encoder output adds the complete-file Xing seek header the players rely on.
  const joined = joinPodcastAudio([encoded]);
  return { bytes: joined.bytes, cues, durationSeconds: joined.durationSeconds };
}

const seconds = (clip: Stereo) => clip.left.length / RATE;

function decodeStereo(decoder: MPEGDecoder, bytes: Uint8Array): Stereo {
  const decoded = decoder.decode(bytes);
  if (!decoded.samplesDecoded || !decoded.channelData.length) throw new Error("Audio could not be decoded");
  const left = decoded.channelData[0].subarray(0, decoded.samplesDecoded);
  const right = (decoded.channelData[1] ?? decoded.channelData[0]).subarray(0, decoded.samplesDecoded);
  return { left: resample(left, decoded.sampleRate), right: resample(right, decoded.sampleRate) };
}

/** Linear-interpolation resampling to the episode rate. */
function resample(samples: Float32Array, rate: number) {
  if (rate === RATE) return Float32Array.from(samples);
  const ratio = rate / RATE;
  const result = new Float32Array(Math.floor(samples.length / ratio));
  for (let i = 0; i < result.length; i++) {
    const position = i * ratio;
    const index = Math.floor(position);
    const next = samples[Math.min(index + 1, samples.length - 1)];
    result[i] = samples[index] + (next - samples[index]) * (position - index);
  }
  return result;
}

function rms(clips: Stereo[]) {
  let sum = 0, count = 0;
  for (const clip of clips) {
    for (let i = 0; i < clip.left.length; i++) sum += clip.left[i] ** 2 + clip.right[i] ** 2;
    count += clip.left.length * 2;
  }
  return count ? Math.sqrt(sum / count) : 0;
}

/** Repeats a clip to `length` seconds with equal-power crossfades at each seam. */
function loop(clip: Stereo, length: number): Stereo {
  const size = Math.ceil(length * RATE);
  const fade = Math.min(Math.floor(BED_CROSSFADE * RATE), Math.floor(clip.left.length / 3));
  const step = clip.left.length - fade;
  const result = { left: new Float32Array(size), right: new Float32Array(size) };
  for (let start = 0; start < size; start += step) {
    for (let i = 0; i < clip.left.length && start + i < size; i++) {
      const gain = start && i < fade ? Math.sin((i / fade) * Math.PI / 2)
        : i >= step ? Math.cos(((i - step) / fade) * Math.PI / 2) : 1;
      result.left[start + i] += clip.left[i] * gain;
      result.right[start + i] += clip.right[i] * gain;
    }
  }
  return result;
}

/**
 * Adds `clip` to the timeline from `start` to `end` seconds. `envelope` is linear gain over absolute
 * timeline seconds; it holds its first and last values beyond its points.
 */
function mixIn(out: Stereo, clip: Stereo, start: number, end: number, envelope: Envelope) {
  const first = Math.max(0, Math.round(start * RATE));
  const last = Math.min(out.left.length, first + clip.left.length, Math.round(end * RATE));
  let point = 0;
  for (let i = first; i < last; i++) {
    const time = i / RATE;
    while (point < envelope.length - 1 && envelope[point + 1][0] <= time) point++;
    const [t0, g0] = envelope[point];
    const [t1, g1] = envelope[Math.min(point + 1, envelope.length - 1)];
    const gain = time <= t0 || t1 <= t0 ? g0 : g0 + (g1 - g0) * Math.min(1, (time - t0) / (t1 - t0));
    if (!gain) continue;
    out.left[i] += clip.left[i - first] * gain;
    out.right[i] += clip.right[i - first] * gain;
  }
}

/** Soft-limits peaks above 0.9 instead of hard clipping, then encodes stereo MP3. */
function encode(audio: Stereo) {
  const encoder = new Mp3Encoder(2, RATE, KBPS);
  const chunks: Uint8Array[] = [];
  const block = 1152 * 10;
  const left = new Int16Array(block), right = new Int16Array(block);
  const pcm = (x: number) => {
    const magnitude = Math.abs(x);
    const limited = magnitude <= 0.9 ? magnitude : 0.9 + 0.1 * Math.tanh((magnitude - 0.9) / 0.1);
    return Math.round(Math.sign(x) * limited * 32767);
  };
  for (let start = 0; start < audio.left.length; start += block) {
    const count = Math.min(block, audio.left.length - start);
    for (let i = 0; i < count; i++) { left[i] = pcm(audio.left[start + i]); right[i] = pcm(audio.right[start + i]); }
    chunks.push(encoder.encodeBuffer(left.subarray(0, count), right.subarray(0, count)));
  }
  chunks.push(encoder.flush());
  const bytes = new Uint8Array(chunks.reduce((sum, chunk) => sum + chunk.length, 0));
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  return bytes;
}
