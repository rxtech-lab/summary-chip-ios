import type { PodcastRenderJob } from "@/lib/services/podcast-render";

export interface PodcastRenderStarter { start(job: PodcastRenderJob): Promise<void> }
let override: PodcastRenderStarter | undefined;
export function setPodcastRenderStarterForTests(value?: PodcastRenderStarter) { override = value; }
export function getPodcastRenderStarter(): PodcastRenderStarter {
  return override ?? { async start(job) {
    const [{ start }, { renderPodcastVideo }] = await Promise.all([import("workflow/api"), import("@/workflows/render-podcast-video")]);
    await start(renderPodcastVideo, [job]);
  } };
}
