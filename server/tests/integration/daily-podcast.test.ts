import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { eq } from "drizzle-orm";
import * as route from "@/app/api/v1/daily-podcasts/route";
import * as audioRoute from "@/app/api/v1/daily-podcasts/[key]/audio/route";
import * as summariesRoute from "@/app/api/v1/summaries/route";
import * as linksRoute from "@/app/api/v1/daily-podcasts/[key]/links/route";
import * as linkRoute from "@/app/api/v1/daily-podcasts/[key]/links/[linkId]/route";
import * as publicRoute from "@/app/api/public/podcasts/[id]/route";
import * as publicAudio from "@/app/api/public/podcasts/[id]/audio/route";
import * as publicArt from "@/app/api/public/podcasts/[id]/art/[index]/route";
import { podcastShareLinks, summaries, summaryViews } from "@/lib/db/schema";
import { podcastDaySchema, type DailyPodcast } from "@/lib/contracts/daily-podcast";
import { createShareLink } from "@/lib/services/share-links";
import { apiRequest, params, setupTestEnv, type TestEnv } from "../helpers/setup";

let env: TestEnv;
const day = { start: "2030-04-01T00:00:00+08:00", end: "2030-04-02T00:00:00+08:00" };
const path = `/api/v1/daily-podcasts?${new URLSearchParams(day)}`;
beforeEach(async () => { env = await setupTestEnv(); });
afterEach(() => { vi.restoreAllMocks(); env.teardown(); });

async function chip(title: string, token = env.tokens.alice, at = day.start) {
  const response = await summariesRoute.POST(apiRequest("POST", "/api/v1/summaries", { token, body: {
    source: { type: "text", text: `${title}: researchers studied this topic and published their results.`, title }, followLinks: false,
  } }));
  expect(response.status).toBe(201);
  const result = await response.json();
  await env.handle.db.update(summaries).set({ createdAt: new Date(at) }).where(eq(summaries.id, result.id));
  return result;
}
const generate = (extra = {}, token = env.tokens.alice) => route.POST(apiRequest("POST", "/api/v1/daily-podcasts", { token, body: { day, language: "ja", ...extra } }));
const saved = (token = env.tokens.alice) => route.GET(apiRequest("GET", path, { token }));
function audio(podcast: DailyPodcast, token = env.tokens.alice, key = podcast.key) {
  return audioRoute.GET(apiRequest("GET", podcast.audioPath!, { token }), params({ key }));
}

describe("daily podcast contract", () => {
  it("requires authentication and validates language and a single local day including DST", async () => {
    expect((await route.GET(apiRequest("GET", path))).status).toBe(401);
    expect((await generate({ language: "auto" })).status).toBe(400);
    expect((await generate({ day: { ...day, end: "2030-04-10T00:00:00Z" } })).status).toBe(400);
    expect(podcastDaySchema.safeParse({ start: "2030-03-10T00:00:00-05:00", end: "2030-03-11T00:00:00-04:00" }).success).toBe(true);
    expect((await saved()).status).toBe(200);
    expect((await (await saved()).json()).podcast).toBeNull();
    expect((await generate()).status).toBe(422);
  });

  it("selects all readable chips on the local activity day, persists audio and reuses it without AI", async () => {
    const own = await chip("Local midnight");
    await chip("Tomorrow", env.tokens.alice, day.end);
    const shared = await chip("Opened today", env.tokens.bob, "2029-01-01T00:00:00Z");
    await env.handle.db.insert(summaryViews).values({ summaryId: shared.id, userId: "user-alice", viewedAt: new Date(day.start) });
    const writer = vi.spyOn(env.ai, "writePodcast");
    const response = await generate();
    expect(response.status).toBe(200);
    const { podcast } = await response.json() as { podcast: DailyPodcast };
    expect(new Set(podcast.chipIds)).toEqual(new Set([own.id, shared.id]));
    expect(writer.mock.calls[0][0].language).toBe("Japanese");
    expect(env.ai.calls.speak).toHaveLength(2);
    expect(podcast.durationSeconds).toBeGreaterThan(0);
    expect(podcast.segments[0].startSeconds).toBe(0);
    expect(podcast.segments[1].startSeconds).toBe(podcast.segments[0].endSeconds);
    expect(podcast.segments.at(-1)?.endSeconds).toBe(podcast.durationSeconds);
    expect([...env.store.objects.keys()].filter((key) => key.endsWith(".mp3"))).toHaveLength(1);
    expect((await audio(podcast)).status).toBe(200);
    expect((await audio(podcast)).headers.get("content-type")).toBe("audio/mpeg");
    expect((await (await generate({ language: "en" })).json()).podcast.key).toBe(podcast.key);
    expect((await (await saved()).json()).podcast.key).toBe(podcast.key);
    expect(writer).toHaveBeenCalledTimes(1);
    expect(env.ai.calls.speak).toHaveLength(2);
    expect((await audio(podcast, env.tokens.bob)).status).toBe(404);
    expect((await audio(podcast, env.tokens.alice, "invalid")).status).toBe(404);
    await env.handle.db.update(summaries).set({ visibility: "private" }).where(eq(summaries.id, shared.id));
    expect((await audio(podcast)).status).toBe(404);
    expect((await saved()).status).toBe(404);
    // Revoked chips do not prevent explicitly generating a new episode from the remaining chips.
    const regenerated = await generate({ regenerate: true });
    expect(regenerated.status).toBe(200);
    expect((await regenerated.json()).podcast.chipIds).toEqual([own.id]);
  });

  it("shares concurrent generation and preserves a working saved episode when regeneration fails", async () => {
    await chip("A useful discovery");
    const writer = vi.spyOn(env.ai, "writePodcast");
    const [a, b] = await Promise.all([generate(), generate()]);
    const first = (await a.json()).podcast as DailyPodcast;
    expect((await b.json()).podcast.key).toBe(first.key);
    expect(writer).toHaveBeenCalledTimes(1);
    vi.spyOn(env.ai, "speak").mockRejectedValueOnce(new Error("Speech unavailable"));
    expect((await generate({ regenerate: true })).status).toBe(502);
    expect((await (await saved()).json()).podcast.key).toBe(first.key);
    expect((await audio(first)).status).toBe(200);
    expect((await generate({ regenerate: true, language: "en" })).status).toBe(200);
    const latest = (await (await saved()).json()).podcast as DailyPodcast;
    expect(latest.key).not.toBe(first.key);
    expect(latest.language).toBe("en");
    expect((await audio(first)).status).toBe(200);
    expect((await audio(latest)).status).toBe(200);
  });

  it("refuses invalid agent references and unavailable speech before publishing", async () => {
    await chip("Source");
    vi.spyOn(env.ai, "speechModelId").mockReturnValueOnce(null);
    expect((await generate()).status).toBe(503);
    vi.spyOn(env.ai, "writePodcast").mockResolvedValueOnce({ title: "Bad", mood: "calm", speakers: [{ name: "Host", voice: "invented" }],
      segments: [{ speaker: 0, chipId: "not-a-chip", caption: "Invented" }] });
    expect((await generate()).status).toBe(502);
    expect((await (await saved()).json()).podcast).toBeNull();
  });

  it("mixes shared theme music into the recording, generating each clip once", async () => {
    await chip("Morning news");
    await chip("Evening news");
    env.ai.music = true;
    const podcast = (await (await generate()).json()).podcast as DailyPodcast;
    expect(podcast.music).toBe(true);
    expect(env.ai.calls.composeMusic).toHaveLength(3);
    // Voices start after the intro, a topic change leaves a musical break, and the outro follows the last word.
    expect(podcast.segments[0].startSeconds).toBeGreaterThan(0);
    expect(podcast.segments[1].startSeconds! - podcast.segments[0].endSeconds!).toBeGreaterThan(1);
    expect(podcast.durationSeconds).toBeGreaterThan(podcast.segments[1].endSeconds!);
    expect((await audio(podcast)).status).toBe(200);
    const musicKeys = [...env.store.objects.keys()].filter((key) => key.startsWith("podcast-music/"));
    expect(musicKeys).toHaveLength(3);
    // Regeneration reuses the stored clips.
    expect((await (await generate({ regenerate: true })).json()).podcast.music).toBe(true);
    expect(env.ai.calls.composeMusic).toHaveLength(3);
  });

  it("publishes voices only when music generation fails", async () => {
    await chip("Quiet day");
    env.ai.music = true;
    vi.spyOn(env.ai, "composeMusic").mockRejectedValue(new Error("Lyria unavailable"));
    vi.spyOn(console, "error").mockImplementation(() => {});
    const response = await generate();
    expect(response.status).toBe(200);
    const podcast = (await response.json()).podcast as DailyPodcast;
    expect(podcast.music).toBe(false);
    expect(podcast.segments[0].startSeconds).toBe(0);
  });

  it("upgrades a saved episode into one MP3 without calling AI again", async () => {
    await chip("An older episode");
    const podcast = (await (await generate()).json()).podcast as DailyPodcast;
    const latestKey = [...env.store.objects.keys()].find((key) => key.endsWith("/latest.json"))!;
    const base = latestKey.slice(0, -"/latest.json".length);
    const sourceAudio = await env.ai.speak("Original recorded words");
    await env.store.put(`${base}/${podcast.key}/0.mp3`, { bytes: sourceAudio.bytes, contentType: "audio/mpeg" });
    delete podcast.audioPath;
    delete podcast.durationSeconds;
    delete podcast.segments[0].startSeconds;
    delete podcast.segments[0].endSeconds;
    const object = { bytes: new TextEncoder().encode(JSON.stringify(podcast)), contentType: "application/json" };
    await env.store.put(latestKey, object);
    await env.store.put(`${base}/${podcast.key}.json`, object);
    await env.store.delete(`${base}/${podcast.key}/audio.mp3`);
    const voiceCalls = env.ai.calls.speak.length;
    const upgraded = (await (await saved()).json()).podcast as DailyPodcast;
    expect(upgraded.audioPath).toContain(`/${podcast.key}/audio?`);
    expect(upgraded.durationSeconds).toBeGreaterThan(0);
    expect(upgraded.segments[0].startSeconds).toBe(0);
    expect((await audio(upgraded)).status).toBe(200);
    expect(env.ai.calls.speak).toHaveLength(voiceCalls);
  });

  it("shares the saved recording through revocable links with expiration and protected artwork", async () => {
    const source = await chip("A private source I own");
    await env.handle.db.update(summaries).set({ visibility: "private", artImageKey: "fixture-art" }).where(eq(summaries.id, source.id));
    await env.store.put("fixture-art", { bytes: new Uint8Array([1, 2, 3]), contentType: "image/png" });
    const podcast = (await (await generate()).json()).podcast as DailyPodcast;
    const context = params({ key: podcast.key });
    const create = (body: object, token = env.tokens.alice) => linksRoute.POST(apiRequest("POST", "/links", {
      token, body: { day, ...body },
    }), context);
    const list = async () => (await (await linksRoute.GET(apiRequest("GET", "/links", { token: env.tokens.alice }), context)).json()).items;
    const patch = (linkId: string, body: object, token = env.tokens.alice) => linkRoute.PATCH(apiRequest("PATCH", "/links", { token, body }),
      params({ key: podcast.key, linkId }));
    const remove = (linkId: string, token = env.tokens.alice) => linkRoute.DELETE(apiRequest("DELETE", "/links", { token }), params({ key: podcast.key, linkId }));
    expect((await linksRoute.GET(apiRequest("GET", "/links"), context)).status).toBe(401);
    expect(await list()).toEqual([]);
    expect((await create({ ttlDays: 2 })).status).toBe(400);
    expect((await create({ ttlDays: 7 }, env.tokens.bob)).status).toBe(404);
    const writer = vi.spyOn(env.ai, "writePodcast");
    const response = await create({ label: "Family", ttlDays: 7 });
    expect(response.status).toBe(201);
    const link = await response.json();
    expect(link).toMatchObject({ label: "Family", access: "anyone", ttlDays: 7, isExpired: false, emails: [] });
    const id = new URL(link.url).pathname.split("/").at(-1)!;
    const read = (token = id) => publicRoute.GET(apiRequest("GET", `/api/public/podcasts/${token}`), params({ id: token }));
    const recording = (range?: string) => publicAudio.GET(apiRequest("GET", "/audio", { headers: range ? { range } : {} }), params({ id }));
    const art = () => publicArt.GET(apiRequest("GET", "/art/0"), params({ id, index: "0" }));
    const result = await read();
    expect(result.status).toBe(200);
    const data = await result.json();
    expect(data.title).toBe(podcast.title);
    expect(data.audioPath).toBe(`/api/public/podcasts/${id}/audio`);
    expect(data.segments[0].caption).toBe(podcast.segments[0].caption);
    expect(JSON.stringify(data)).not.toContain(source.id);
    expect(data).not.toHaveProperty("chipIds");
    expect((await art()).status).toBe(200);
    const ownerAudio = new Uint8Array(await (await audio(podcast)).arrayBuffer());
    expect(new Uint8Array(await (await recording()).arrayBuffer())).toEqual(ownerAudio);
    const partial = await recording("bytes=0-9");
    expect(partial.status).toBe(206);
    expect(partial.headers.get("content-range")).toBe(`bytes 0-9/${ownerAudio.length}`);
    expect(new Uint8Array(await partial.arrayBuffer())).toEqual(ownerAudio.slice(0, 10));
    expect(new Uint8Array(await (await recording("bytes=-10")).arrayBuffer())).toEqual(ownerAudio.slice(-10));
    expect((await recording("bytes=999999999-")).status).toBe(416);
    expect((await recording("bytes=4-2")).status).toBe(416);
    expect((await recording("bytes=-0")).status).toBe(416);

    // A second link opens the same episode independently and can be deleted on its own.
    const second = await (await create({})).json();
    expect(second.url).not.toBe(link.url);
    expect(second.label).toBeNull();
    const secondId = new URL(second.url).pathname.split("/").at(-1)!;
    expect((await read(secondId)).status).toBe(200);
    expect((await list()).map((item: { id: string }) => item.id)).toEqual([link.id, second.id]);
    expect((await remove(second.id, env.tokens.bob)).status).toBe(404);
    expect((await remove(second.id)).status).toBe(204);
    expect((await read(secondId)).status).toBe(404);
    expect((await read()).status).toBe(200);

    expect((await patch(link.id, { label: "Team" }, env.tokens.bob)).status).toBe(404);
    const renamed = await (await patch(link.id, { label: "Team" })).json();
    expect(renamed).toMatchObject({ url: link.url, label: "Team", expiresAt: link.expiresAt });
    await env.handle.db.update(podcastShareLinks).set({ expiresAt: new Date(0) }).where(eq(podcastShareLinks.id, link.id));
    expect((await read()).status).toBe(404);
    expect((await recording()).status).toBe(404);
    expect((await art()).status).toBe(404);
    expect((await list())[0].isExpired).toBe(true);
    const never = await (await patch(link.id, { ttlDays: null })).json();
    expect(never).toMatchObject({ url: link.url, ttlDays: null, expiresAt: null, isExpired: false });
    expect((await read()).status).toBe(200);
    const regenerated = (await (await generate({ regenerate: true })).json()).podcast as DailyPodcast;
    const otherLinks = await linksRoute.GET(apiRequest("GET", "/links", { token: env.tokens.alice }), params({ key: regenerated.key }));
    expect((await otherLinks.json()).items).toEqual([]);
    expect((await read()).status).toBe(200);
    await env.handle.db.delete(summaries).where(eq(summaries.id, source.id));
    expect((await read()).status).toBe(404);
    expect((await recording()).status).toBe(404);
    expect((await art()).status).toBe(404);
    // Owners can still see and delete links after their sources disappear.
    expect(await list()).toHaveLength(1);
    expect((await remove(link.id)).status).toBe(204);
    expect(writer).toHaveBeenCalledTimes(1); // The explicit regeneration only; sharing never generates.
  });

  it("stops a published episode when someone else's source chip becomes private", async () => {
    await saved(); // Creates the authenticated viewer before inserting its view row.
    const source = await chip("Someone else's public chip", env.tokens.bob);
    await env.handle.db.insert(summaryViews).values({ summaryId: source.id, userId: "user-alice", viewedAt: new Date(day.start) });
    const podcast = (await (await generate()).json()).podcast as DailyPodcast;
    const request = () => linksRoute.POST(apiRequest("POST", "/links", { token: env.tokens.alice,
      body: { day, ttlDays: null } }), params({ key: podcast.key }));
    const created = await (await request()).json();
    const id = new URL(created.url).pathname.split("/").at(-1)!;
    expect((await publicRoute.GET(apiRequest("GET", "/podcast"), params({ id }))).status).toBe(200);
    await env.handle.db.update(summaries).set({ visibility: "private" }).where(eq(summaries.id, source.id));
    expect((await publicRoute.GET(apiRequest("GET", "/podcast"), params({ id }))).status).toBe(404);
    expect((await request()).status).toBe(404);
    const link = await createShareLink(env.handle.db, "user-bob", source.id, { access: "anyone", emails: [], ttlDays: null });
    await env.handle.db.update(summaryViews).set({ shareLinkId: link.id }).where(eq(summaryViews.summaryId, source.id));
    // Alice can read through a private chip's separate share link, but cannot republish it.
    expect((await saved()).status).toBe(200);
    expect((await request()).status).toBe(403);
  });
});
