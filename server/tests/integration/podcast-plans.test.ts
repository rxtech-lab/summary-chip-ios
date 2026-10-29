import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { eq } from "drizzle-orm";
import * as plans from "@/app/api/v1/daily-podcasts/plans/route";
import * as planRoute from "@/app/api/v1/daily-podcasts/plans/[id]/route";
import * as messagesRoute from "@/app/api/v1/daily-podcasts/plans/[id]/messages/route";
import * as framesRoute from "@/app/api/v1/daily-podcasts/plans/[id]/frames/route";
import * as summariesRoute from "@/app/api/v1/summaries/route";
import type { AiProvider } from "@/lib/ai/provider";
import { createGateway } from "@ai-sdk/gateway";
import { writePodcast } from "@/lib/ai/podcast-agent";
import { dayKey } from "@/lib/services/daily-podcast";
import { podcastEpisodes, podcastPlans, summaries } from "@/lib/db/schema";
import { podcastVideoInput, podcastVideoSource } from "@/lib/services/podcast-video";
import { runPodcastVideoDesignJob } from "@/lib/services/podcast-video-design";
import { apiRequest, params, setupTestEnv, type TestEnv } from "../helpers/setup";
let env: TestEnv;
const day = { start: "2030-04-01T00:00:00+08:00", end: "2030-04-02T00:00:00+08:00" };
beforeEach(async () => { env = await setupTestEnv(); });
afterEach(() => { vi.restoreAllMocks(); env.teardown(); });
async function prepare() {
  const response = await summariesRoute.POST(apiRequest("POST", "/api/v1/summaries", { token: env.tokens.alice, body: {
    source: { type: "text", text: "A research group published battery results.", title: "Batteries" }, followLinks: false,
  } }));
  const chip = await response.json();
  await env.handle.db.update(summaries).set({ createdAt: new Date(day.start) }).where(eq(summaries.id, chip.id));
  const result = await plans.POST(apiRequest("POST", "/api/v1/daily-podcasts/plans", { token: env.tokens.alice,
    body: { day, language: "en", chipIds: [chip.id], includeVideo: true } }));
  expect(result.status).toBe(200);
  return (await result.json()).plan;
}
function request(method: string, id: string, body?: unknown, token = env.tokens.alice, suffix = "") {
  return apiRequest(method, `/api/v1/daily-podcasts/plans/${id}${suffix}`, { token, body });
}
describe("podcast plan review gate", () => {
  it("plans without media, saves revisions, then uses approved narration and camera directions", async () => {
    env.ai.video = true;
    const speech = vi.spyOn(env.ai, "speak");
    const writer = vi.spyOn(env.ai, "writePodcast");
    const plan = await prepare();
    expect(speech).not.toHaveBeenCalled();
    expect(env.podcastVideoDesigns).toHaveLength(0);
    expect(await env.handle.db.select().from(podcastEpisodes)).toHaveLength(0);
    plan.script.segments[0].caption = "This is the revised narration.";
    plan.script.segments[0].camera = "Overhead shot of a battery diagram. Slow zoom, then fade out.";
    const patched = await planRoute.PATCH(request("PATCH", plan.id, { revision: 0, script: plan.script }), params({ id: plan.id }));
    expect(patched.status).toBe(200);
    expect((await patched.json()).plan.revision).toBe(1);
    expect((await planRoute.POST(request("POST", plan.id, { revision: 0 }), params({ id: plan.id }))).status).toBe(409);
    const confirm = await planRoute.POST(request("POST", plan.id, { revision: 1 }), params({ id: plan.id }));
    expect(confirm.status).toBe(200);
    const { podcast } = await confirm.json();
    expect(podcast.key).toBe(plan.id);
    expect(env.podcastVideoDesigns).toHaveLength(1);
    const job = env.podcastVideoDesigns[0];
    const state = JSON.parse(new TextDecoder().decode((await env.store.get(`${dayKey(job.userId, job.day)}/${job.key}/video-design/${job.id}.json`)).bytes));
    expect(state.input.segments[0].camera).toBe(plan.script.segments[0].camera);
    expect(writer).toHaveBeenCalledTimes(1);
    expect(speech).toHaveBeenCalledWith(plan.script.segments[0].caption, plan.script.speakers[0].voice, expect.any(Object));
    expect(podcastVideoInput(podcast, []).segments[0].camera).toBe(plan.script.segments[0].camera);
    const count = speech.mock.calls.length;
    expect((await planRoute.POST(request("POST", plan.id, { revision: 1 }), params({ id: plan.id }))).status).toBe(200);
    expect(speech).toHaveBeenCalledTimes(count);
    expect((await planRoute.PATCH(request("PATCH", plan.id, { revision: 1, script: plan.script }), params({ id: plan.id }))).status).toBe(409);
  });
  it("enforces owner access, valid references, and nonempty camera directions", async () => {
    const plan = await prepare();
    expect((await planRoute.GET(request("GET", plan.id, undefined, env.tokens.bob), params({ id: plan.id }))).status).toBe(404);
    expect((await planRoute.POST(request("POST", plan.id, { revision: 0 }, env.tokens.bob), params({ id: plan.id }))).status).toBe(404);
    const original = structuredClone(plan.script);
    plan.script.segments[0].camera = " ";
    expect((await planRoute.PATCH(request("PATCH", plan.id, { revision: 0, script: plan.script }), params({ id: plan.id }))).status).toBe(400);
    original.segments[0].chipId = "foreign-chip";
    expect((await planRoute.PATCH(request("PATCH", plan.id, { revision: 0, script: original }), params({ id: plan.id }))).status).toBe(422);
  });
  it.skipIf(!process.env.PODCAST_SIMULATION_URL)("prepares a persisted storyboard through the real gateway HTTP adapter", async () => {
    const gateway = createGateway({ baseURL: process.env.PODCAST_SIMULATION_URL, apiKey: "local-fixture-only" });
    vi.spyOn(env.ai as AiProvider, "writePodcast").mockImplementation((input, options) => writePodcast(gateway("fixture/podcast"), input, options));
    const speech = vi.spyOn(env.ai, "speak");
    const plan = await prepare();
    expect(plan.script.segments[0].camera).toContain("slow push in");
    expect(speech).not.toHaveBeenCalled();
    expect((await planRoute.GET(request("GET", plan.id), params({ id: plan.id }))).status).toBe(200);
  });
  it("rejects a concurrent media generation lease before speech and permits retry after a failed generation", async () => {
    const plan = await prepare();
    const speech = vi.spyOn(env.ai, "speak");
    await env.handle.db.update(podcastPlans).set({ generatingUntil: Date.now() + 330_000 }).where(eq(podcastPlans.id, plan.id));
    expect((await planRoute.POST(request("POST", plan.id, { revision: 0 }), params({ id: plan.id }))).status).toBe(409);
    expect(speech).not.toHaveBeenCalled();
    await env.handle.db.update(podcastPlans).set({ generatingUntil: 0 }).where(eq(podcastPlans.id, plan.id));
    speech.mockRejectedValueOnce(new Error("fixture voice failure"));
    expect((await planRoute.POST(request("POST", plan.id, { revision: 0 }), params({ id: plan.id }))).status).toBe(502);
    const [stored] = await env.handle.db.select().from(podcastPlans).where(eq(podcastPlans.id, plan.id));
    expect(stored.generatingUntil).toBe(0);
    expect((await planRoute.POST(request("POST", plan.id, { revision: 0 }), params({ id: plan.id }))).status).toBe(200);
  });
  it("rechecks source access before confirmation", async () => {
    const plan = await prepare();
    await env.handle.db.delete(summaries).where(eq(summaries.id, plan.script.segments[0].chipId));
    expect((await planRoute.POST(request("POST", plan.id, { revision: 0 }), params({ id: plan.id }))).status).toBe(422);
    expect(await env.handle.db.select().from(podcastEpisodes)).toHaveLength(0);
  });
  it("draws storyboard frames, refines the plan in chat, and hands approved frames to the video designer", async () => {
    env.ai.video = true;
    env.ai.storyboardFrames = true;
    const plan = await prepare();
    expect(plan.frames).toEqual([null]);
    expect(plan.messages).toEqual([]);
    const drawn = await framesRoute.POST(request("POST", plan.id, { revision: 0 }, env.tokens.alice, "/frames"), params({ id: plan.id }));
    expect(drawn.status).toBe(200);
    const withFrames = (await drawn.json()).plan;
    expect(withFrames.frames[0]).toMatch(/^https:\/\/downloads\.invalid\//);
    expect(env.ai.calls.drawStoryboardFrame).toHaveLength(1);
    expect(env.ai.calls.drawStoryboardFrame[0].camera).toBe(plan.script.segments[0].camera);
    // Nothing is missing, so drawing again draws nothing.
    await framesRoute.POST(request("POST", plan.id, { revision: 0 }, env.tokens.alice, "/frames"), params({ id: plan.id }));
    expect(env.ai.calls.drawStoryboardFrame).toHaveLength(1);
    const chat = await messagesRoute.POST(request("POST", plan.id, { revision: 0, message: "Make the first shot an aerial view." }, env.tokens.alice, "/messages"), params({ id: plan.id }));
    expect(chat.status).toBe(200);
    const refined = (await chat.json()).plan;
    expect(refined.revision).toBe(1);
    expect(refined.messages.map((message: { role: string }) => message.role)).toEqual(["user", "assistant"]);
    expect(refined.script.segments[0].camera).toContain("aerial view");
    // The changed direction lost its frame, and the stale picture was deleted.
    expect(refined.frames).toEqual([null]);
    const [stale] = await env.handle.db.select().from(podcastPlans).where(eq(podcastPlans.id, plan.id));
    expect(stale.frames).toEqual({});
    expect((await messagesRoute.POST(request("POST", plan.id, { revision: 0, message: "Again" }, env.tokens.alice, "/messages"), params({ id: plan.id }))).status).toBe(409);
    await framesRoute.POST(request("POST", plan.id, { revision: 1 }, env.tokens.alice, "/frames"), params({ id: plan.id }));
    const confirm = await planRoute.POST(request("POST", plan.id, { revision: 1 }), params({ id: plan.id }));
    expect(confirm.status).toBe(200);
    const { podcast } = await confirm.json();
    const episode = `${dayKey(env.podcastVideoDesigns[0].userId, podcast.day)}/${podcast.key}`;
    expect(await env.store.head(`${episode}/video-assets/plan/storyboard-1.png`)).not.toBeNull();
    const job = env.podcastVideoDesigns[0];
    const state = JSON.parse(new TextDecoder().decode((await env.store.get(`${episode}/video-design/${job.id}.json`)).bytes));
    expect(state.input.segments[0].storyboardImage).toBe("gen/storyboard-1.png");
    expect(state.draft.images["gen/storyboard-1.png"]).toMatchObject({ file: "video-assets/plan/storyboard-1.png", supplied: true, width: 1280, height: 720 });
    expect((await runPodcastVideoDesignJob(env.handle.db, job, { ai: env.ai, store: env.store })).status).toBe("accepted");
    expect(env.ai.calls.writePodcastVideo.at(-1)?.segments[0].storyboardImage).toBe("gen/storyboard-1.png");
    const source = await podcastVideoSource(env.handle.db, job.userId, podcast.day, podcast.key, env.store);
    expect(source.assets).toContainEqual({ path: "gen/storyboard-1.png", file: "video-assets/plan/storyboard-1.png", width: 1280, height: 720 });
  });
  it("refuses frames when storyboards are off and keeps another owner's plan private", async () => {
    const plan = await prepare();
    expect((await framesRoute.POST(request("POST", plan.id, { revision: 0 }, env.tokens.alice, "/frames"), params({ id: plan.id }))).status).toBe(503);
    expect((await messagesRoute.POST(request("POST", plan.id, { revision: 0, message: "Shorter" }, env.tokens.bob, "/messages"), params({ id: plan.id }))).status).toBe(404);
  });
  it("lists unconfirmed plans for the library and deletes them with their frames", async () => {
    env.ai.storyboardFrames = true;
    const plan = await prepare();
    await framesRoute.POST(request("POST", plan.id, { revision: 0 }, env.tokens.alice, "/frames"), params({ id: plan.id }));
    const list = async (token = env.tokens.alice) => (await (await plans.GET(apiRequest("GET", "/api/v1/daily-podcasts/plans", { token }))).json()).plans;
    const [listed] = await list();
    expect(listed).toMatchObject({ id: plan.id, title: plan.script.title, lineCount: 1, library: false, language: "en" });
    expect(listed.thumbnailUrl).toMatch(/^https:\/\/downloads\.invalid\//);
    expect(Date.parse(listed.updatedAt)).toBeGreaterThan(0);
    expect(await list(env.tokens.bob)).toEqual([]);
    const [row] = await env.handle.db.select().from(podcastPlans).where(eq(podcastPlans.id, plan.id));
    const frameKeys = Object.values(row.frames).map(frame => frame.key);
    expect((await planRoute.DELETE(request("DELETE", plan.id, undefined, env.tokens.bob), params({ id: plan.id }))).status).toBe(404);
    await env.handle.db.update(podcastPlans).set({ generatingUntil: Date.now() + 60_000 }).where(eq(podcastPlans.id, plan.id));
    expect((await planRoute.DELETE(request("DELETE", plan.id), params({ id: plan.id }))).status).toBe(409);
    await env.handle.db.update(podcastPlans).set({ generatingUntil: 0 }).where(eq(podcastPlans.id, plan.id));
    expect((await planRoute.DELETE(request("DELETE", plan.id), params({ id: plan.id }))).status).toBe(204);
    expect(await list()).toEqual([]);
    for (const key of frameKeys) expect(await env.store.head(key)).toBeNull();
    // Confirmed plans leave the list and can't be deleted.
    const confirmed = await prepare();
    expect((await planRoute.POST(request("POST", confirmed.id, { revision: 0 }), params({ id: confirmed.id }))).status).toBe(200);
    expect(await list()).toEqual([]);
    expect((await planRoute.DELETE(request("DELETE", confirmed.id), params({ id: confirmed.id }))).status).toBe(409);
  });
});
