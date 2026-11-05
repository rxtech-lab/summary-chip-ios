import { getDatabase } from "@/lib/db/client";
import { drawAudiobookVideoScenes, finishAudiobookVideo, type AudiobookVideoJob } from "@/lib/services/audiobook-video";
import { notifyBackgroundJob } from "@/lib/services/background-jobs";

/** Illustrates an audiobook's scenes a few at a time, then queues the cloud render. */
export async function designAudiobookVideo(job: AudiobookVideoJob) {
  "use workflow";
  let failed = false;
  try {
    while (!await draw(job)) { /* continues in the next step */ }
  } catch { failed = true; }
  await finish(job, failed);
  await notify(job);
}
async function draw(job: AudiobookVideoJob) { "use step"; return drawAudiobookVideoScenes(getDatabase(), job); }
async function finish(job: AudiobookVideoJob, failed: boolean) { "use step"; await finishAudiobookVideo(getDatabase(), job, failed); }
async function notify(job: AudiobookVideoJob) { "use step"; await notifyBackgroundJob(getDatabase(), job.userId, job.id); }
