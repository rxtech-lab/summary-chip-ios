import { getAiProvider } from "@/lib/ai/provider";
import { sandboxCredentials } from "./sandbox-auth";
import { Sandbox } from "@vercel/sandbox";
import { eq } from "drizzle-orm";
import type { Database } from "@/lib/db/client";
import { summaries } from "@/lib/db/schema";
import { MAX_PODCAST_VIDEO_BYTES } from "@/lib/contracts/daily-podcast";
import { ApiError } from "@/lib/http/errors";
import { getObjectStore } from "@/lib/storage/r2";
import { dailyPodcastRecording } from "@/lib/services/daily-podcast";
import { currentPodcastRender, podcastRenderKey, type PodcastRenderJob } from "@/lib/services/podcast-render";
import { podcastVideoInput, podcastVideoSource } from "@/lib/services/podcast-video";
import { cloudCaptionsSrt } from "./captions";
import { CLOUD_RENDER_RUNNER } from "./cloud-runner";

export interface RenderSession { name: string }
export interface CloudPodcastRenderer {
  launch(db: Database, job: PodcastRenderJob): Promise<RenderSession>;
  poll(session: RenderSession): Promise<{ status: "running" | "ready" | "failed"; byteSize?: number }>;
  upload(session: RenderSession, job: PodcastRenderJob, byteSize: number): Promise<void>;
  stop(session: RenderSession): Promise<void>;
}
const directory = "/vercel/sandbox";
const production: CloudPodcastRenderer = {
  async launch(db, job) {
    const snapshotId = process.env.PODCAST_RENDER_SNAPSHOT_ID;
    if (!snapshotId) throw new ApiError(503, "PODCAST_RENDER_UNAVAILABLE", "The cloud video renderer has not been configured.");
    const podcast = await currentPodcastRender(db, job);
    const source = await podcastVideoSource(db, job.userId, job.day, job.key, undefined, job.language);
    if (source.id !== job.videoId) throw new ApiError(409, "PODCAST_VIDEO_CHANGED", "The video changed.");
    const store = getObjectStore();
    const files = Object.entries(source.files).map(([path, value]) => {
      if (!/^src\/(?:[A-Za-z0-9_-]+\/)*[A-Za-z0-9_.-]+\.(?:tsx|ts|css|json)$/.test(path)) throw new Error("Invalid source path");
      return { path: `${directory}/${path}`, content: Buffer.from(value) };
    });
    const input = podcastVideoInput(podcast, source.chips);
    const images = new Map<string, string>();
    for (const path of new Set(podcast.segments.flatMap(s => s.imagePath ? [s.imagePath] : []))) {
      const slug = /^\/s\/([^/]+)\/art\.png$/.exec(path)?.[1];
      if (!slug) continue;
      // Read only artwork belonging to this episode's already-authorized source chips.
      const [chip] = await db.select().from(summaries).where(eq(summaries.slug, slug));
      if (!chip?.artImageKey || !podcast.chipIds.includes(chip.id)) continue;
      const image = await store.get(chip.artImageKey).catch(() => null);
      if (!image) continue;
      const name = `art/${images.size}.png`;
      images.set(path, name);
      files.push({ path: `${directory}/public/${name}`, content: Buffer.from(image.bytes) });
    }
    files.push({ path: `${directory}/src/data.json`, content: Buffer.from(JSON.stringify({
      ...input, fps: source.fps, width: source.width, height: source.height,
      speakers: podcast.speakers.map(s => ({ name: s.name })),
      segments: input.segments.map(s => ({ ...s, caption: "", chipTitle: source.chips.find(c => c.id === s.chipId)?.title ?? "",
        image: s.image ? images.get(s.image) ?? null : null, icon: s.icon ?? "🎙️" })),
    })) });
    // Use normalized voice windows for legacy episodes, including empty cue arrays.
    const captions = input.segments.flatMap(segment => segment.phrases);
    files.push({ path: `${directory}/captions.srt`, content: Buffer.from(cloudCaptionsSrt(await (await getAiProvider()).splitPodcastCaptions(captions))) });
    files.push({ path: `${directory}/public/podcast.mp3`, content: Buffer.from((await dailyPodcastRecording(db, job.userId, job.day, job.key, store, job.language)).bytes) });
    files.push({ path: `${directory}/render.mjs`, content: Buffer.from(CLOUD_RENDER_RUNNER) });
    // No external network or account credentials while agent-authored code runs.
    const sandbox = await Sandbox.create({ ...sandboxCredentials(), source: { type: "snapshot", snapshotId }, timeout: 60 * 60_000, persistent: false,
      resources: { vcpus: 4 }, networkPolicy: "deny-all" }).catch((error: unknown) => {
      // An expired or revoked token fails every render; retrying can't help, so report it as configuration.
      const status = (error as { response?: { status?: number } }).response?.status;
      if (status === 401 || status === 403) throw new ApiError(503, "PODCAST_RENDER_UNAVAILABLE", "Vercel Sandbox rejected the renderer's credentials.");
      throw error;
    });
    try {
      await sandbox.writeFiles(files);
      await sandbox.runCommand({ cmd: "node", args: ["render.mjs", String(job.resolution), String(podcast.maxDurationSeconds ?? 0), podcast.language], cwd: directory, detached: true });
      return { name: sandbox.name };
    } catch (error) { await sandbox.stop(); throw error; }
  },
  async poll(session) {
    const sandbox = await Sandbox.get({ ...sandboxCredentials(), name: session.name });
    const bytes = await sandbox.readFileToBuffer({ path: `${directory}/status.json` });
    if (!bytes) return { status: "running" };
    const result = JSON.parse(bytes.toString());
    if (result.status !== "ready" || !Number.isSafeInteger(result.byteSize) || result.byteSize <= 0 || result.byteSize > MAX_PODCAST_VIDEO_BYTES)
      return { status: "failed" };
    return { status: "ready", byteSize: result.byteSize };
  },
  async upload(session, job, byteSize) {
    const sandbox = await Sandbox.get({ ...sandboxCredentials(), name: session.name });
    const signed = await getObjectStore().signedPut(podcastRenderKey(job), "video/mp4", byteSize);
    await sandbox.updateNetworkPolicy({ allow: [new URL(signed.url).hostname] });
    // Only a short-lived capability for this single output object enters the container.
    const command = await sandbox.runCommand({ cmd: "curl", args: ["--fail", "--silent", "--show-error", "--max-time", "240", "-X", "PUT",
      "-H", "content-type: video/mp4", "--upload-file", `${directory}/render.mp4`, signed.url] });
    if (command.exitCode !== 0) throw new Error("R2 upload failed");
    const head = await getObjectStore().head(podcastRenderKey(job));
    if (head?.byteSize !== byteSize || head.contentType !== "video/mp4") throw new Error("R2 upload incomplete");
  },
  async stop(session) { await (await Sandbox.get({ ...sandboxCredentials(), name: session.name })).stop(); },
};
let override: CloudPodcastRenderer | undefined;
export function setCloudPodcastRendererForTests(value?: CloudPodcastRenderer) { override = value; }
export function getCloudPodcastRenderer() { return override ?? production; }
