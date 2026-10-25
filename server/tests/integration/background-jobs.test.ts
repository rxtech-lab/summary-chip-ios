import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { eq } from "drizzle-orm";
import { createGateway } from "@ai-sdk/gateway";
import { podcastVideoTurn } from "@/lib/ai/podcast-video-agent";
import * as listRoute from "@/app/api/v1/background-jobs/route";
import * as detailRoute from "@/app/api/v1/background-jobs/[id]/route";
import * as podcastRoute from "@/app/api/v1/daily-podcasts/route";
import * as summariesRoute from "@/app/api/v1/summaries/route";
import { backgroundJobs, podcastEpisodes, summaries } from "@/lib/db/schema";
import { notifyBackgroundJob, recordJobActivity } from "@/lib/services/background-jobs";
import * as notifications from "@/lib/services/notifications";
import { runPodcastVideoDesignTurn, finishPodcastVideoDesign } from "@/lib/services/podcast-video-design";
import { apiRequest, params, setupTestEnv, type TestEnv } from "../helpers/setup";

let env: TestEnv;
const day = { start: "2030-04-01T00:00:00Z", end: "2030-04-02T00:00:00Z" };
beforeEach(async () => { env = await setupTestEnv(); });
afterEach(() => { vi.restoreAllMocks(); env.teardown(); });
const list = (token = env.tokens.alice, cursor?: string) => listRoute.GET(apiRequest("GET", `/api/v1/background-jobs${cursor ? `?cursor=${cursor}` : ""}`, { token }));
const detail = (id: string, token = env.tokens.alice) => detailRoute.GET(apiRequest("GET", `/api/v1/background-jobs/${id}`, { token }), params({ id }));
async function start() {
  env.ai.video = true;
  const added = await summariesRoute.POST(apiRequest("POST", "/api/v1/summaries", { token: env.tokens.alice,
    body: { source: { type: "text", text: "Researchers report a new battery chemistry with higher energy density.", title: "Batteries" }, followLinks: false } }));
  const chip = await added.json();
  await env.handle.db.update(summaries).set({ createdAt: new Date(day.start) }).where(eq(summaries.id, chip.id));
  const response = await podcastRoute.POST(apiRequest("POST", "/api/v1/daily-podcasts", { token: env.tokens.alice, body: { day, language: "en", includeVideo: true } }));
  expect(response.status).toBe(200);
  return env.podcastVideoDesigns[0];
}

describe("durable background jobs", () => {
  it("lists queued work, persists completion and logs, and fences other accounts", async () => {
    const job = await start();
    const queued = await list();
    expect(queued.headers.get("cache-control")).toContain("no-store");
    expect((await queued.json()).items).toMatchObject([{ id: job.id, status: "running" }]);
    expect((await (await list(env.tokens.bob)).json()).items).toEqual([]);
    expect((await detail(job.id, env.tokens.bob)).status).toBe(404);
    expect((await list(env.tokens.bob, job.id)).status).toBe(400);
    await env.runPodcastVideoDesigns();
    const ready = (await (await detail(job.id)).json()).job;
    expect(ready).toMatchObject({ status: "ready", percent: 100, videoId: job.id });
    expect(ready.logs.length).toBeGreaterThan(1);
    expect(ready.logs.at(-1).message).toContain("Render on This Device");
    // A workflow finish replay after draft cleanup preserves success.
    await finishPodcastVideoDesign(env.handle.db, job, { status: "accepted" });
    expect((await (await detail(job.id)).json()).job.status).toBe("ready");
    await env.handle.db.update(podcastEpisodes).set({ deleted: true }).where(eq(podcastEpisodes.key, job.key));
    expect((await detail(job.id)).status).toBe(404);
    expect((await (await list()).json()).items).toEqual([]);
  });

  it("keeps failed jobs inspectable and sends one actionable owner-routed notification", async () => {
    const sent = vi.spyOn(notifications, "deliver").mockResolvedValue();
    const job = await start();
    vi.spyOn(env.ai, "podcastVideoTurn").mockRejectedValue(new Error("Model unavailable"));
    await env.runPodcastVideoDesigns();
    const failed = (await (await detail(job.id)).json()).job;
    expect(failed.status).toBe("failed");
    expect(failed.error).toMatchObject({ code: "PODCAST_VIDEO_FAILED", message: expect.stringContaining("model request failed") });
    expect(failed.percent).toBe(10);
    expect(failed.logs.at(-1).message).toContain("retry");
    await notifyBackgroundJob(env.handle.db, job.userId, job.id);
    expect(sent).toHaveBeenCalledTimes(1);
    expect(sent.mock.calls[0][2]).toMatchObject({ userId: job.userId, backgroundJobId: job.id,
      aps: { alert: { title: "Video design needs attention", body: expect.stringContaining("retry") } } });
  });

  it("preserves timeout details without inventing progress or exposing provider bodies", async () => {
    const job = await start();
    vi.spyOn(env.ai, "podcastVideoTurn").mockRejectedValue(new DOMException("secret provider body", "TimeoutError"));
    for (let attempt = 0; attempt < 3; attempt++) {
      const outcome = await runPodcastVideoDesignTurn(env.handle.db, job);
      if (attempt === 2) await finishPodcastVideoDesign(env.handle.db, job, outcome);
    }
    const failed = (await (await detail(job.id)).json()).job;
    expect(failed).toMatchObject({ status: "failed", percent: 10, error: { code: "PODCAST_VIDEO_TIMEOUT", message: expect.stringContaining("4 minutes") } });
    expect(JSON.stringify(failed)).not.toContain("secret provider body");
    expect(failed.logs.filter((log: { message: string }) => log.message.includes("Attempt"))).toHaveLength(3);
  });

  it("sends a ready notification with the render step and ignores repeated events", async () => {
    const sent = vi.spyOn(notifications, "deliver").mockResolvedValue();
    const job = await start();
    await recordJobActivity(env.handle.db, job.userId, job.id, "step", "Writing scene");
    await recordJobActivity(env.handle.db, job.userId, job.id, "step", "Writing scene");
    expect((await (await detail(job.id)).json()).job.logs.filter((log: { id: string }) => log.id === "step")).toHaveLength(1);
    await env.runPodcastVideoDesigns();
    await notifyBackgroundJob(env.handle.db, job.userId, job.id);
    expect(sent).toHaveBeenCalledTimes(1);
    expect(sent.mock.calls[0][2].aps.alert.body).toContain("Render on This Device");
  });

  it.skipIf(!process.env.PODCAST_SIMULATION_URL)("exposes real SDK HTTP timeouts in the job and clears them after recovery", async () => {
    const job = await start();
    const original = env.ai.podcastVideoTurn.bind(env.ai);
    const gateway = createGateway({ baseURL: process.env.PODCAST_SIMULATION_URL, apiKey: "local-fixture-only",
      headers: { "x-podcast-fixture-failure": "hang" } });
    const request = vi.spyOn(env.ai, "podcastVideoTurn").mockImplementation((input, draft, options) =>
      podcastVideoTurn(gateway("fixture/video"), input, draft, { ...options, abortSignal: AbortSignal.timeout(300) }));
    await runPodcastVideoDesignTurn(env.handle.db, job);
    const retrying = (await (await detail(job.id)).json()).job;
    expect(retrying).toMatchObject({ status: "running", percent: 10, error: { code: "PODCAST_VIDEO_TIMEOUT" } });
    request.mockImplementation(original);
    await env.runPodcastVideoDesigns();
    const ready = (await (await detail(job.id)).json()).job;
    expect(ready.status).toBe("ready");
    expect(ready.error).toBeUndefined();
  });

  it("paginates stable equal-time jobs without duplicates and exposes stale work as failed", async () => {
    const job = await start();
    const [row] = await env.handle.db.select().from(backgroundJobs);
    for (let i = 0; i < 52; i++) {
      const id = `job-${String(i).padStart(3, "0")}`;
      await env.handle.db.insert(backgroundJobs).values({ ...row, id, document: { ...row.document, id, updatedAt: "2020-01-01T00:00:00Z" } });
    }
    const first = await (await list()).json();
    const second = await (await list(env.tokens.alice, first.nextCursor)).json();
    expect(first.items).toHaveLength(50);
    expect(second.items).toHaveLength(3);
    expect(second.nextCursor).toBeNull();
    expect(new Set([...first.items, ...second.items].map(item => item.id)).size).toBe(53);
    expect(first.items.find((item: { id: string }) => item.id !== job.id).status).toBe("failed");
  });
});
