import type { AudiobookJobInput } from "./audiobooks";
import type { AudiobookVideoJob } from "./audiobook-video";

/** Starts audiobook workflows; behind an interface so services and tests never import the workflow runtime directly. */
export interface AudiobookStarter {
  start(job: AudiobookJobInput): Promise<void>;
  startVideo(job: AudiobookVideoJob): Promise<void>;
}
let override: AudiobookStarter | undefined;
export function setAudiobookStarterForTests(starter?: AudiobookStarter) { override = starter; }
export function getAudiobookStarter(): AudiobookStarter {
  return override ?? {
    async start(job) {
      const [{ start }, { generateAudiobook }] = await Promise.all([import("workflow/api"), import("@/workflows/generate-audiobook")]);
      await start(generateAudiobook, [job]);
    },
    async startVideo(job) {
      const [{ start }, { designAudiobookVideo }] = await Promise.all([import("workflow/api"), import("@/workflows/design-audiobook-video")]);
      await start(designAudiobookVideo, [job]);
    },
  };
}
