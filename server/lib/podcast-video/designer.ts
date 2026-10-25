import type { PodcastVideoJob } from "@/lib/services/podcast-video-design";

/**
 * Starts `designPodcastVideo` workflow runs. Behind an interface so services (and tests) never import
 * the workflow runtime directly.
 */
export interface PodcastVideoDesigner {
  /** Starts a background run that designs the episode's motion video one agent turn at a time. */
  start(job: PodcastVideoJob): Promise<void>;
}

let override: PodcastVideoDesigner | undefined;

export function setPodcastVideoDesignerForTests(designer?: PodcastVideoDesigner): void {
  override = designer;
}

const workflowDesigner: PodcastVideoDesigner = {
  async start(job) {
    const [{ start }, { designPodcastVideo }] = await Promise.all([import("workflow/api"), import("@/workflows/design-podcast-video")]);
    await start(designPodcastVideo, [job]);
  },
};

export function getPodcastVideoDesigner(): PodcastVideoDesigner {
  return override ?? workflowDesigner;
}
