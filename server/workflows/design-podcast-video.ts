import { notifyBackgroundJob } from "@/lib/services/background-jobs";
import { getDatabase } from "@/lib/db/client";
import {
  finishPodcastVideoDesign,
  runPodcastVideoDesignTurn,
  translatePodcastVideoDesign,
  type PodcastVideoJob,
  type PodcastVideoOutcome,
} from "@/lib/services/podcast-video-design";

/** A safety bound: the agent's own turn and failure limits end the run well before it. */
const MAX_TURNS = 100;

/**
 * Designs an episode's motion video in the background, so the owner can leave the app while the agent
 * works. Every agent turn (one small file, edit, preview or submission) is its own step that saves the
 * draft, so no invocation runs long and a crash resumes from the last turn. The accepted composition queues a cloud HD render.
 */
export async function designPodcastVideo(job: PodcastVideoJob) {
  "use workflow";

  let outcome: PodcastVideoOutcome = { status: "running" };
  try {
    for (let turn = 0; turn < MAX_TURNS && outcome.status === "running"; turn += 1) {
      outcome = await designTurn(job);
    }
  } catch {
    // The step failed every retry (storage or database): record the failure so the app can retry.
    outcome = { status: "failed", code: "PODCAST_VIDEO_FAILED", error: { code: "PODCAST_VIDEO_FAILED",
      message: "The background workflow could not save or load its draft after retrying. Please retry video design." } };
  }
  if (outcome.status === "running") outcome = { status: "failed", code: "PODCAST_VIDEO_FAILED" };
  const saved = await finish(job, outcome);
  if (saved && job.language) await translate(job);
  await notify(job);
  return outcome;
}

async function designTurn(job: PodcastVideoJob) {
  "use step";
  return runPodcastVideoDesignTurn(getDatabase(), job);
}

async function finish(job: PodcastVideoJob, outcome: PodcastVideoOutcome) {
  "use step";
  return finishPodcastVideoDesign(getDatabase(), job, outcome);
}

async function translate(job: PodcastVideoJob) {
  "use step";
  await translatePodcastVideoDesign(getDatabase(), job);
}

async function notify(job: PodcastVideoJob) {
  "use step";
  await notifyBackgroundJob(getDatabase(), job.userId, job.id);
}
