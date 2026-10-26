import { Converter } from "opencc-js/t2cn";

export interface TranscribedCaption { text: string; startSecond: number; endSecond: number }
export interface PodcastCaptionCue { text: string; startSeconds: number; endSeconds: number }

export function captionText(text: string): string {
  return text.replace(/['’]/gu, "").replace(/\p{P}/gu, " ").replace(/\s+/gu, " ").trim();
}
const segmenter = new Intl.Segmenter(undefined, { granularity: "word" });
const simplified = Converter({ from: "tw", to: "cn" });
function tokens(text: string) {
  // Han word boundaries vary between scripts and ASR segments. Align individual
  // Han characters, retaining original UTF-16 offsets for displayed captions.
  return [...segmenter.segment(text)].filter((part) => part.isWordLike).flatMap((part) =>
    [...part.segment.matchAll(/\p{Script=Han}|[^\p{Script=Han}]+/gu)].map((match) => ({
      index: part.index + match.index,
      key: simplified(match[0].normalize("NFKC")).toLowerCase(),
    })));
}

/** Edit alignment restores script spelling while retaining the recognizer's segment boundaries.
 * Work per spoken turn (script limit 500 characters), never across speakers or music.
 * No proportional whole-turn timing fallback: unusable transcription fails generation.
 */
export function alignPodcastCaptions(original: string, segments: TranscribedCaption[]): PodcastCaptionCue[] {
  if (!segments.length || segments.some((s, i) => !Number.isFinite(s.startSecond) || !Number.isFinite(s.endSecond)
    || s.startSecond < 0 || s.endSecond <= s.startSecond || (i > 0 && s.startSecond < segments[i - 1].endSecond))) {
    throw new Error("Transcription returned missing or invalid caption timestamps");
  }
  const clean = captionText(original);
  const source = tokens(clean);
  const groups = segments.map((s) => tokens(captionText(s.text)));
  const heard = groups.flat();
  if (!source.length || !heard.length || heard.length > 2000) throw new Error("Unusable podcast transcript");
  const n = source.length, m = heard.length;
  const cost = Array.from({ length: n + 1 }, () => new Uint16Array(m + 1));
  for (let i = 0; i <= n; i++) cost[i][0] = i;
  for (let j = 0; j <= m; j++) cost[0][j] = j;
  for (let i = 1; i <= n; i++) for (let j = 1; j <= m; j++) {
    cost[i][j] = Math.min(cost[i - 1][j] + 1, cost[i][j - 1] + 1,
      cost[i - 1][j - 1] + Number(source[i - 1].key !== heard[j - 1].key));
  }
  if (cost[n][m] / Math.max(n, m) > 0.65) throw new Error("Transcript does not match podcast script");
  const boundaries = new Array<number>(m + 1);
  let i = n, j = m;
  boundaries[m] = n;
  while (i || j) {
    if (i && j && cost[i][j] === cost[i - 1][j - 1] + Number(source[i - 1].key !== heard[j - 1].key)) {
      i--; j--;
    } else if (i && cost[i][j] === cost[i - 1][j] + 1) { i--; }
    else { j--; }
    boundaries[j] = i;
  }
  boundaries[0] = 0;
  boundaries[m] = n;
  let consumed = 0, start = 0;
  const cues: PodcastCaptionCue[] = [];
  for (let k = 0; k < segments.length; k++) {
    consumed += groups[k].length;
    const end = boundaries[consumed];
    const text = clean.slice(source[start]?.index ?? clean.length, source[end]?.index ?? clean.length).trim();
    if (text) cues.push({ text, startSeconds: segments[k].startSecond, endSeconds: segments[k].endSecond });
    start = end;
  }
  if (!cues.length) throw new Error("No aligned captions");
  return cues;
}
