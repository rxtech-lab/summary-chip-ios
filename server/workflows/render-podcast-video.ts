import { sleep } from "workflow";
import { getDatabase } from "@/lib/db/client";
import { currentPodcastRender, finishPodcastRender, type PodcastRenderJob } from "@/lib/services/podcast-render";
import { getCloudPodcastRenderer, type RenderSession } from "@/lib/podcast-video/sandbox-renderer";
import { notifyBackgroundJob, recordJobActivity } from "@/lib/services/background-jobs";

/** Detached container execution survives function invocations. Each short poll is a durable step. */
export async function renderPodcastVideo(job: PodcastRenderJob) {
  "use workflow";
  let session: RenderSession | undefined;
  try {
    session = await launch(job);
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
  return getCloudPodcastRenderer().launch(getDatabase(), job);
}
// Never automatically start another billable sandbox when a launch response is lost.
launch.maxRetries = 0;
async function poll(job: PodcastRenderJob, session: RenderSession) {
  "use step";
  await currentPodcastRender(getDatabase(), job);
  await recordJobActivity(getDatabase(), job.userId, job.id, "rendering", "Rendering in the cloud. You can close the app.", { percent: 50 });
  return getCloudPodcastRenderer().poll(session);
}
async function upload(job: PodcastRenderJob, session: RenderSession, bytes: number) {
  "use step";
  await currentPodcastRender(getDatabase(), job);
  await getCloudPodcastRenderer().upload(session, job, bytes);
}
async function finish(job: PodcastRenderJob, bytes?: number) {
  "use step";
  await finishPodcastRender(getDatabase(), job, bytes);
}
async function stop(session: RenderSession) {
  "use step";
  await getCloudPodcastRenderer().stop(session).catch(() => {});
}
async function notify(job: PodcastRenderJob) {
  "use step";
  await notifyBackgroundJob(getDatabase(), job.userId, job.id);
}
