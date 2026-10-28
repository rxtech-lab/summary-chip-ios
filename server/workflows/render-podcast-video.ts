import { sleep } from "workflow";
import { getDatabase } from "@/lib/db/client";
import { currentPodcastRender, finishPodcastRender, markPodcastRenderStarted, podcastRenderError, type PodcastRenderJob } from "@/lib/services/podcast-render";
import { getCloudPodcastRenderer, type RenderSession } from "@/lib/podcast-video/sandbox-renderer";
import { notifyBackgroundJob } from "@/lib/services/background-jobs";

/** Detached container execution survives function invocations. Each short poll is a durable step. */
export async function renderPodcastVideo(job: PodcastRenderJob) {
  "use workflow";
  let session: RenderSession | undefined;
  try {
    const launched = await launch(job);
    if ("error" in launched) {
      await finish(job, undefined, launched.error);
      return;
    }
    session = launched.session;
    await started(job);
    for (let attempt = 0; attempt < 350; attempt++) {
      await sleep("10s");
      const result = await poll(job, session);
      if (result.status === "failed") throw new Error("Render failed");
      if (result.status === "ready") {
        await upload(job, session, result.byteSize!);
        await finish(job, result.byteSize!);
        return;
      }
    }
    throw new Error("Render timed out");
  } catch {
    await finish(job);
  } finally {
    if (session) await stop(session);
    await notify(job);
  }
}
async function launch(job: PodcastRenderJob) {
  "use step";
  try {
    return { session: await getCloudPodcastRenderer().launch(getDatabase(), job) };
  } catch (error) {
    console.error("[podcast-render] launch failed", { job: job.id }, error);
    return { error: podcastRenderError(error) };
  }
}
// Never automatically start another billable sandbox when a launch response is lost.
launch.maxRetries = 0;
async function poll(job: PodcastRenderJob, session: RenderSession) {
  "use step";
  await currentPodcastRender(getDatabase(), job);
  return getCloudPodcastRenderer().poll(session);
}
async function started(job: PodcastRenderJob) {
  "use step";
  await markPodcastRenderStarted(getDatabase(), job);
}
async function upload(job: PodcastRenderJob, session: RenderSession, bytes: number) {
  "use step";
  await currentPodcastRender(getDatabase(), job);
  await getCloudPodcastRenderer().upload(session, job, bytes);
}
async function finish(job: PodcastRenderJob, bytes?: number, error?: { code: string }) {
  "use step";
  await finishPodcastRender(getDatabase(), job, bytes, error);
}
async function stop(session: RenderSession) {
  "use step";
  await getCloudPodcastRenderer().stop(session).catch(() => {});
}
async function notify(job: PodcastRenderJob) {
  "use step";
  await notifyBackgroundJob(getDatabase(), job.userId, job.id);
}
