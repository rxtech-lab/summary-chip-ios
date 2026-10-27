import { captionText } from "@/lib/services/podcast-captions";

export interface CaptionCue { text: string; startSeconds: number; endSeconds: number; paged?: boolean }
const graphemes = new Intl.Segmenter(undefined, { granularity: "grapheme" });
const words = new Intl.Segmenter(undefined, { granularity: "word" });
const length = (text: string) => Array.from(graphemes.segment(text)).length;

/** Match the device's short two-line pages without changing transcription boundaries or gaps. */
export function pageCloudCaptions(cues: CaptionCue[]): CaptionCue[] {
  return cues.flatMap(cue => {
    if (!Number.isFinite(cue.startSeconds) || !Number.isFinite(cue.endSeconds)
      || cue.startSeconds < 0 || cue.endSeconds <= cue.startSeconds) return [];
    if (cue.paged) return [cue];
    const text = captionText(cue.text);
    const limit = /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]/u.test(text) ? 18 : 36;
    const lines: string[] = [];
    let line = "";
    const flush = () => { if (line.trim()) lines.push(line.trim()); line = ""; };
    for (const { segment } of words.segment(text)) {
      if (length(line + segment) > limit) flush();
      // The limit is soft for a single word: preserve Chinese words and names.
      if (line || segment.trim()) line += segment;
    }
    flush();
    return captionPages(cue, lines);
  });
}

export function captionPages(cue: CaptionCue, lines: string[]): CaptionCue[] {
  const pages: string[] = [];
  for (let i = 0; i < lines.length; i += 2) pages.push(lines.slice(i, i + 2).join("\n"));
  const weights = pages.map(page => Array.from(page).reduce((sum, character) =>
    sum + (/\p{N}/u.test(character) ? 2.5 : /\s/u.test(character) ? 0.5 : 1), 0));
  const total = weights.reduce((sum, weight) => sum + weight, 0);
  let elapsed = 0;
  return pages.map((text, index) => {
    const startSeconds = cue.startSeconds + (cue.endSeconds - cue.startSeconds) * elapsed / total;
    elapsed += weights[index];
    const endSeconds = index === pages.length - 1 ? cue.endSeconds
      : cue.startSeconds + (cue.endSeconds - cue.startSeconds) * elapsed / total;
    return { text, startSeconds, endSeconds, paged: true };
  });
}

export function cloudCaptionsSrt(cues: CaptionCue[]): string {
  const time = (seconds: number) => {
    const ms = Math.max(0, Math.round(seconds * 1000));
    return `${String(Math.floor(ms / 3600000)).padStart(2, "0")}:${String(Math.floor(ms / 60000) % 60).padStart(2, "0")}:${String(Math.floor(ms / 1000) % 60).padStart(2, "0")},${String(ms % 1000).padStart(3, "0")}`;
  };
  return pageCloudCaptions(cues).map((cue, index) =>
    `${index + 1}\n${time(cue.startSeconds)} --> ${time(cue.endSeconds)}\n${cue.text}\n`).join("\n");
}
