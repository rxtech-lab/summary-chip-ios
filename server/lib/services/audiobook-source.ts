import { extractPdfText } from "@/lib/extract/pdf";
import type { SummaryRow } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import type { ObjectStore } from "@/lib/storage/r2";
import { MAX_AUDIOBOOK_CHAPTER_SECONDS, MAX_AUDIOBOOK_SECONDS, type AudiobookChapterPlan, type AudiobookPlanDocument } from "@/lib/contracts/audiobook";

/** A source is cut into numbered passages at paragraph ends; chapters name ranges of them. */
const PASSAGE_CHARACTERS = 3500;
/** The longest source read: far past what four hours can narrate, but bounds memory and storage. */
const MAX_SOURCE_CHARACTERS = 3_000_000;
/** Sources up to this size reach the planner whole; longer ones as each passage's opening. */
const FULL_PLANNING_CHARACTERS = 300_000;
const PASSAGE_PREVIEW = 400;

export interface StoredPassage { chipId: string; chipTitle: string; text: string }

/**
 * A chip's complete source text. Stored text is capped when a summary is made, so a chip the viewer uploaded as a PDF
 * is read again from the PDF, which is what lets a whole book be narrated. Falls back to stored extracted text or
 * the owner's saved source document when it can't be. Private local source documents are never read for other viewers.
 */
export async function chipSourceText(chip: SummaryRow, viewer: string, store: ObjectStore): Promise<string> {
  // Local imports deliberately leave contentText empty. When the owner opts to
  // keep the source, the document writer saves it in contentMarkdown instead.
  const savedDocument = chip.ownerId === viewer ? chip.contentMarkdown?.trim() : "";
  const stored = chip.contentText.trim() || savedDocument || chip.contentExcerpt || "";
  if (chip.ownerId !== viewer || (chip.sourceType !== "pdf" && chip.source !== "pdf") || !chip.sourceFileKey) return stored;
  try {
    const { text } = await extractPdfText((await store.get(chip.sourceFileKey)).bytes);
    return text.length > stored.length ? text : stored;
  } catch (error) {
    console.warn("[audiobook] PDF could not be read again; using the stored text", { chip: chip.id, error });
    return stored;
  }
}

/** Cuts text into passages at paragraph or, for very long paragraphs, sentence ends. */
export function splitPassages(text: string, size = PASSAGE_CHARACTERS): string[] {
  const passages: string[] = [];
  let current = "";
  const flush = () => { if (current.trim()) passages.push(current.trim()); current = ""; };
  for (const paragraph of text.replace(/\r\n?/g, "\n").split(/\n{2,}|\n(?=\s)/)) {
    const clean = paragraph.replace(/[ \t]*\n[ \t]*/g, " ").trim();
    if (!clean) continue;
    if (current.length + clean.length + 2 <= size) { current += `${current ? "\n\n" : ""}${clean}`; continue; }
    flush();
    if (clean.length <= size) { current = clean; continue; }
    for (const sentence of clean.match(/[^.!?。！？]+[.!?。！？]*["'”’）)]*\s*/gu) ?? [clean]) {
      if (current.length + sentence.length > size) flush();
      // A single run of text with no sentence ends is cut at the passage size.
      if (sentence.length > size) { for (let at = 0; at < sentence.length; at += size) passages.push(sentence.slice(at, at + size).trim()); }
      else current += sentence;
    }
    flush();
  }
  flush();
  return passages;
}

export async function audiobookPassages(chips: SummaryRow[], viewer: string, store: ObjectStore): Promise<StoredPassage[]> {
  const passages: StoredPassage[] = [];
  let total = 0;
  for (const chip of chips) {
    const text = (await chipSourceText(chip, viewer, store)).trim();
    if (!text) throw new ApiError(422, "AUDIOBOOK_NO_TEXT", `“${chip.title}” has no stored text to narrate.`);
    total += text.length;
    if (total > MAX_SOURCE_CHARACTERS) throw new ApiError(422, "AUDIOBOOK_SOURCE_TOO_LONG", "These sources are too long for one audiobook. Choose fewer.");
    for (const passage of splitPassages(text)) passages.push({ chipId: chip.id, chipTitle: chip.title, text: passage });
  }
  return passages;
}

/** What the planner reads: everything when it fits, otherwise each passage's opening, which is enough to find the structure. */
export function passagesForPlanning(passages: StoredPassage[]) {
  const whole = passages.reduce((sum, passage) => sum + passage.text.length, 0) <= FULL_PLANNING_CHARACTERS;
  return passages.map((passage, index) => ({ index, chip: passage.chipTitle, text: whole ? passage.text : passage.text.slice(0, PASSAGE_PREVIEW) }));
}

/** About how long text takes to read aloud. CJK characters take a syllable each, other scripts about a fifteenth of a second. */
export function narrationSeconds(text: string) {
  const cjk = (text.match(/[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]/gu) ?? []).length;
  return cjk * 0.2 + (text.length - cjk) * 0.067;
}

/** The share of the source's reading time that fits the target and the book-length limit. */
export function narrationRatio(sourceSeconds: number, targetSeconds?: number) {
  const limit = Math.min(targetSeconds ?? MAX_AUDIOBOOK_SECONDS, MAX_AUDIOBOOK_SECONDS);
  return sourceSeconds > 0 ? Math.min(1, limit / sourceSeconds) : 1;
}

/**
 * Repairs what the model or an editor left inconsistent, so everything after it can rely on the plan: passage ranges
 * are ordered and cover the source, over-long chapters become parts, and no stretch of narration is left on one piece
 * of music for long. Long chapters get more cues in rotation, and a chapter never starts on the cue the last one ended on.
 */
export function normalizeAudiobookPlan(plan: AudiobookPlanDocument, passages: Pick<StoredPassage, "text">[], ratio: number): AudiobookPlanDocument {
  const cueIds = plan.musicCues.map(cue => cue.id);
  const ordered = [...plan.chapters].sort((a, b) => a.firstPassage - b.firstPassage);
  const last = passages.length - 1;
  const ranged = ordered.map((chapter, index) => ({ ...chapter,
    firstPassage: index === 0 ? 0 : Math.min(last, Math.max(chapter.firstPassage, ordered[index - 1].firstPassage + 1)),
    music: chapter.music.filter(id => cueIds.includes(id)) }));
  ranged.forEach((chapter, index) => { chapter.lastPassage = index === ranged.length - 1 ? last : Math.max(chapter.firstPassage, ranged[index + 1].firstPassage - 1); });
  const secondsOf = (chapter: Pick<AudiobookChapterPlan, "firstPassage" | "lastPassage">) =>
    passages.slice(chapter.firstPassage, chapter.lastPassage + 1).reduce((sum, passage) => sum + narrationSeconds(passage.text), 0) * ratio;

  const split: AudiobookChapterPlan[] = ranged.filter(chapter => chapter.firstPassage <= chapter.lastPassage).flatMap((chapter) => {
    const count = chapter.lastPassage - chapter.firstPassage + 1;
    const parts = Math.min(count, Math.ceil(secondsOf(chapter) / MAX_AUDIOBOOK_CHAPTER_SECONDS));
    if (parts <= 1) return [chapter];
    return Array.from({ length: parts }, (_, part) => {
      const share = (values: unknown[]) => [Math.floor(values.length * part / parts), Math.floor(values.length * (part + 1) / parts)];
      const [sceneFrom, sceneTo] = share(chapter.scenes);
      const [musicFrom, musicTo] = share(chapter.music);
      return { ...chapter,
        title: `${chapter.title} (${part + 1}/${parts})`.slice(0, 120),
        firstPassage: chapter.firstPassage + Math.floor(count * part / parts),
        lastPassage: chapter.firstPassage + Math.floor(count * (part + 1) / parts) - 1,
        scenes: chapter.scenes.slice(sceneFrom, sceneTo),
        music: chapter.music.slice(musicFrom, musicTo) };
    });
  });

  let rotation = 0;
  const nextCue = (avoid: string | undefined) => {
    let cue = cueIds[rotation++ % cueIds.length];
    if (cue === avoid) cue = cueIds[rotation++ % cueIds.length];
    return cue;
  };
  let previous: string | undefined;
  const scored = split.map((chapter) => {
    // A 30-second clip loops under its stretch, so a stretch stays under about five minutes.
    const wanted = Math.min(8, Math.max(1, Math.ceil(secondsOf(chapter) / 300)));
    const music = [...chapter.music];
    if (!music.length) music.push(nextCue(previous));
    if (music[0] === previous) {
      const other = music.findIndex(id => id !== previous);
      if (other > 0) [music[0], music[other]] = [music[other], music[0]];
      else music[0] = nextCue(previous);
    }
    while (music.length < wanted) music.push(nextCue(music[music.length - 1]));
    previous = music[music.length - 1];
    return { ...chapter, music: music.slice(0, 8) };
  });
  return { ...plan, chapters: scored };
}
