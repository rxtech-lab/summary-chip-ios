import { randomUUID } from "node:crypto";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { createMcpServer } from "@/lib/mcp/server";
import { podcastEpisodes, users } from "@/lib/db/schema";
import { currentPodcastRender, finishPodcastRender, podcastRenderKey, podcastRenderStatus, startPodcastRender } from "@/lib/services/podcast-render";
import { dailyPodcastEpisode, updatePodcastDocument } from "@/lib/services/daily-podcast";
import { setPodcastRenderStarterForTests } from "@/lib/podcast-video/render-workflow";
import * as renderRoute from "@/app/api/v1/daily-podcasts/[key]/video/render/route";
import { apiRequest, params, setupTestEnv, type TestEnv } from "../helpers/setup";
let env: TestEnv;
let key: string;
const day = { start: "2030-04-01T00:00:00Z", end: "2030-04-02T00:00:00Z" };
beforeEach(async () => {
  env = await setupTestEnv(); key = randomUUID();
  await env.handle.db.insert(users).values([{ id: "user-alice" }, { id: "user-bob" }]).onConflictDoNothing();
  await env.handle.db.insert(podcastEpisodes).values({ key, ownerId: "user-alice", dayStart: Date.parse(day.start), dayEnd: Date.parse(day.end), document: {
    key, day, title: "Cloud video", language: "en", createdAt: day.start, speakers: [], segments: [], chipIds: [], mood: "calm",
    video: { id: randomUUID(), createdAt: day.start },
    translations: { ja: { language: "ja", title: "Japanese", createdAt: day.start, speakers: [], segments: [], video: { id: randomUUID(), createdAt: day.start } } },
  } });
});
afterEach(() => { vi.restoreAllMocks(); env.teardown(); });
const start = (resolution = 1080, token = env.tokens.alice, language?: string) => renderRoute.POST(apiRequest("POST", "/video/render", { token, body: { day, resolution, language } }), params({ key }));
const status = (token = env.tokens.alice) => renderRoute.GET(apiRequest("GET", `/video/render?${new URLSearchParams(day)}`, { token }), params({ key }));
it("fences accounts, rejects cloud 4K, and never starts work from a status read", async () => {
  expect((await renderRoute.POST(apiRequest("POST", "/video/render", { body: { day } }), params({ key }))).status).toBe(401);
  expect((await start(1080, env.tokens.bob)).status).toBe(404);
  expect((await status(env.tokens.bob)).status).toBe(404);
  expect((await start(2160)).status).toBe(400);
  expect((await start(1440)).status).toBe(400);
  const read = await status();
  expect(read.headers.get("cache-control")).toContain("no-store");
  expect((await read.json()).render).toBeNull();
  expect(env.podcastRenders).toHaveLength(0);
});
it("reuses work, scopes translations/resolutions, and leaves publication untouched", async () => {
  const first = await (await start()).json();
  expect((await (await start()).json()).render.id).toBe(first.render.id);
  expect(env.podcastRenders).toHaveLength(1);
  const job = env.podcastRenders[0];
  await env.store.put(podcastRenderKey(job), { bytes: new Uint8Array(10), contentType: "video/mp4" });
  await finishPodcastRender(env.handle.db, job, 10);
  const ready = await (await status()).json();
  expect(ready.render).toMatchObject({ status: "ready", byteSize: 10, resolution: 1080 });
  expect(ready.downloadUrl).toContain("downloads.invalid");
  expect((await (await start()).json()).render.id).toBe(first.render.id);
  expect(env.podcastRenders).toHaveLength(1);
  const ja = await (await start(720, env.tokens.alice, "ja")).json();
  expect(ja.videoId).not.toBe(first.videoId);
  expect(ja.render).toMatchObject({ resolution: 720, status: "running" });
  const episode = await dailyPodcastEpisode(env.handle.db, "user-alice", day, key);
  expect(episode.video?.published).toBeUndefined();
  expect(episode.video?.renders?.[720]).toBeUndefined();
  expect(episode.translations?.ja.video?.renders?.[720]?.id).toBe(ja.render.id);
});
it("records launch failure safely and permits an explicit retry", async () => {
  setPodcastRenderStarterForTests({ start: async () => { throw new Error("secret provider response"); } });
  expect((await start()).status).toBe(503);
  const failed = await (await status()).json();
  expect(failed.render).toMatchObject({ status: "failed", error: { code: "PODCAST_RENDER_FAILED" } });
  expect(JSON.stringify(failed)).not.toContain("secret");
  setPodcastRenderStarterForTests({ start: async job => { env.podcastRenders.push(job); } });
  const retry = await (await start()).json();
  expect(retry.render.id).not.toBe(failed.render.id);
  expect(retry.render.status).toBe("running");
});
it("rejects stale completions, cleans their output and preserves a replacement", async () => {
  await start(); const job = env.podcastRenders[0];
  await env.store.put(podcastRenderKey(job), { bytes: new Uint8Array(10), contentType: "video/mp4" });
  const replacement = randomUUID();
  await updatePodcastDocument(env.handle.db, "user-alice", key, episode => { episode.video = { id: replacement, createdAt: day.start }; });
  await expect(currentPodcastRender(env.handle.db, job)).rejects.toMatchObject({ code: "PODCAST_VIDEO_CHANGED" });
  await finishPodcastRender(env.handle.db, job, 10);
  expect(await env.store.head(podcastRenderKey(job))).toBeNull();
  expect((await dailyPodcastEpisode(env.handle.db, "user-alice", day, key)).video?.id).toBe(replacement);
  expect((await podcastRenderStatus(env.handle.db, "user-alice", day, key)).render).toBeNull();
});
it("times out stopped work and replaces the claim on retry", async () => {
  await start(); const job = env.podcastRenders[0];
  await updatePodcastDocument(env.handle.db, "user-alice", key, episode => { episode.video!.renders![1080]!.updatedAt = "2020-01-01T00:00:00Z"; });
  expect((await (await status()).json()).render).toMatchObject({ status: "failed", error: { code: "PODCAST_RENDER_TIMEOUT" } });
  expect((await (await start()).json()).render.id).not.toBe(job.id);
  await expect(currentPodcastRender(env.handle.db, job)).rejects.toMatchObject({ code: "PODCAST_VIDEO_CHANGED" });
});
it("coalesces simultaneous render claims", async () => {
  const results = await Promise.all([startPodcastRender(env.handle.db, "user-alice", day, key), startPodcastRender(env.handle.db, "user-alice", day, key)]);
  expect(results[0].render?.id).toBe(results[1].render?.id);
  expect(env.podcastRenders).toHaveLength(1);
});
it("requires MCP write scope to render and allows read-only status polling", async () => {
  const server = createMcpServer({ db: env.handle.db, principal: { sub: "user-alice", scopes: ["chippy:read"], clientId: "render-test" }, accepted: null });
  const client = new Client({ name: "render-test", version: "1" });
  const [a, b] = InMemoryTransport.createLinkedPair(); await server.connect(b); await client.connect(a);
  try {
    const read = await client.callTool({ name: "get_podcast_video_render", arguments: { day, key } });
    expect(read.isError).not.toBe(true);
    const write = await client.callTool({ name: "render_podcast_video", arguments: { day, key } });
    expect(write.isError).toBe(true);
    expect(write._meta).toHaveProperty("mcp/www_authenticate");
    expect(env.podcastRenders).toHaveLength(0);
  } finally { await client.close(); await server.close(); }
});

it("runs the cloud workflow through polling, R2 upload, completion and cleanup", async () => {
  const { renderPodcastVideo } = await import("@/workflows/render-podcast-video");
  const { setCloudPodcastRendererForTests } = await import("@/lib/podcast-video/sandbox-renderer");
  await start(); const job = env.podcastRenders[0];
  const stop = vi.fn().mockResolvedValue(undefined);
  const poll = vi.fn().mockResolvedValueOnce({ status: "running" }).mockResolvedValue({ status: "ready", byteSize: 10 });
  setCloudPodcastRendererForTests({ launch: async () => ({ name: "test-render" }), poll, stop,
    upload: async (_session, job) => { await env.store.put(podcastRenderKey(job), { bytes: new Uint8Array(10), contentType: "video/mp4" }); } });
  try {
    await renderPodcastVideo(job);
    expect(poll).toHaveBeenCalledTimes(2);
    expect(stop).toHaveBeenCalledWith({ name: "test-render" });
    const state = await podcastRenderStatus(env.handle.db, "user-alice", day, key);
    expect(state.render).toMatchObject({ status: "ready", byteSize: 10 });
    expect(state.downloadUrl).toContain("downloads.invalid");
    expect((await dailyPodcastEpisode(env.handle.db, "user-alice", day, key)).video?.published).toBeUndefined();
  } finally { setCloudPodcastRendererForTests(undefined); }
});

it("records renderer failure and stops the container without a download", async () => {
  const { renderPodcastVideo } = await import("@/workflows/render-podcast-video");
  const { setCloudPodcastRendererForTests } = await import("@/lib/podcast-video/sandbox-renderer");
  await start(); const job = env.podcastRenders[0];
  const stop = vi.fn().mockResolvedValue(undefined);
  const upload = vi.fn();
  setCloudPodcastRendererForTests({ launch: async () => ({ name: "test-render" }), poll: async () => ({ status: "failed" }), stop, upload });
  try {
    await renderPodcastVideo(job);
    const state = await podcastRenderStatus(env.handle.db, "user-alice", day, key);
    expect(state.render).toMatchObject({ status: "failed", error: { code: "PODCAST_RENDER_FAILED" } });
    expect(state.downloadUrl).toBeUndefined();
    expect(upload).not.toHaveBeenCalled();
    expect(stop).toHaveBeenCalledOnce();
  } finally { setCloudPodcastRendererForTests(undefined); }
});

// Executes workflow control flow locally, without workflow sleep or provider calls. Deployment
// compilation is checked separately; these tests do not establish durable remote execution.
vi.mock("workflow", () => ({ sleep: vi.fn().mockResolvedValue(undefined) }));

it("retires a removed translation's private R2 exports and fences its running jobs", async () => {
  const { removePodcastTranslation } = await import("@/lib/services/podcast-translation");
  await start(720, env.tokens.alice, "ja"); const job = env.podcastRenders[0];
  await env.store.put(podcastRenderKey(job), { bytes: new Uint8Array(10), contentType: "video/mp4" });
  await finishPodcastRender(env.handle.db, job, 10);
  await removePodcastTranslation(env.handle.db, "user-alice", day, key, "ja");
  expect(await env.store.head(podcastRenderKey(job))).toBeNull();
  await expect(currentPodcastRender(env.handle.db, job)).rejects.toMatchObject({ status: 404 });
  // A delayed upload/completion must not resurrect the translation or retain its output.
  await env.store.put(podcastRenderKey(job), { bytes: new Uint8Array(10), contentType: "video/mp4" });
  await finishPodcastRender(env.handle.db, job, 10);
  expect(await env.store.head(podcastRenderKey(job))).toBeNull();
  expect((await dailyPodcastEpisode(env.handle.db, "user-alice", day, key)).translations?.ja).toBeUndefined();
});
