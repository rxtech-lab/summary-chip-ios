import { getDatabase } from "@/lib/db/client";
import { failAudiobook, finishAudiobook, notifyAudiobook, runAudiobookChapterMix, runAudiobookChapterScript, runAudiobookChapterVoices, runAudiobookMusic, type AudiobookJobInput } from "@/lib/services/audiobooks";

/** Chapters made at once; more would only meet provider rate limits. */
const CHAPTER_CONCURRENCY = 3;

/**
 * Makes a whole audiobook in the background. Every step is small and saves its work to storage, so a long book
 * never outlives a function invocation and a crash, redeploy or Retry continues from the last saved turn.
 */
export async function generateAudiobook(job: AudiobookJobInput) {
  "use workflow";
  try {
    let music = await composeMusic(job);
    while (!music.done) music = await composeMusic(job);
    const chapters = Array.from({ length: music.chapters }, (_, index) => index);
    for (let start = 0; start < chapters.length; start += CHAPTER_CONCURRENCY) {
      await Promise.all(chapters.slice(start, start + CHAPTER_CONCURRENCY).map(async (chapter) => {
        await writeChapter(job, chapter);
        while (!await voiceChapter(job, chapter)) { /* continues in the next step */ }
        await mixChapter(job, chapter);
      }));
    }
    await finish(job);
  } catch {
    await fail(job);
  }
  await notify(job);
}

async function composeMusic(job: AudiobookJobInput) { "use step"; return runAudiobookMusic(getDatabase(), job); }
async function writeChapter(job: AudiobookJobInput, chapter: number) { "use step"; await runAudiobookChapterScript(getDatabase(), job, chapter); }
async function voiceChapter(job: AudiobookJobInput, chapter: number) { "use step"; return runAudiobookChapterVoices(getDatabase(), job, chapter); }
async function mixChapter(job: AudiobookJobInput, chapter: number) { "use step"; await runAudiobookChapterMix(getDatabase(), job, chapter); }
async function finish(job: AudiobookJobInput) { "use step"; await finishAudiobook(getDatabase(), job); }
async function fail(job: AudiobookJobInput) { "use step"; await failAudiobook(getDatabase(), job); }
async function notify(job: AudiobookJobInput) { "use step"; await notifyAudiobook(getDatabase(), job); }
