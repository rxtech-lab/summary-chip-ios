import * as linkedPodcastsRoute from "@/app/api/v1/summaries/[id]/podcasts/route";
import * as publicCover from "@/app/api/public/podcasts/[id]/cover/route";
import { generateMetadata } from "@/app/podcast/[id]/page";
import type { AiProvider } from "@/lib/ai/provider";
import { createGateway } from "@ai-sdk/gateway";
import { generateSpeech } from "ai";
import { writePodcast } from "@/lib/ai/podcast-agent";
import * as versionsRoute from "@/app/api/v1/daily-podcasts/versions/route";
import * as versionRoute from "@/app/api/v1/daily-podcasts/[key]/route";
import * as libraryPodcastRoute from "@/app/api/v1/summaries/[id]/podcast/route";
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
import { podcastEpisodes, podcastShareLinks, summaries, summaryViews } from "@/lib/db/schema";
import { podcastDaySchema, type DailyPodcast } from "@/lib/contracts/daily-podcast";
import { dayKey } from "@/lib/services/daily-podcast";
import { getHeadlines } from "@/lib/services/headlines";
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

describe("podcast selection and versions", () => {
  it("selects chips explicitly and rejects empty, out-of-day and inaccessible selections before AI", async () => {
    const one = await chip("One");
    await chip("Two");
    const tomorrow = await chip("Tomorrow", env.tokens.alice, day.end);
    const writer = vi.spyOn(env.ai, "writePodcast");
    const response = await generate({ chipIds: [one.id] });
    expect(response.status).toBe(200);
    expect((await response.json()).podcast.chipIds).toEqual([one.id]);
    expect((await generate({ chipIds: [] })).status).toBe(400);
    expect((await generate({ regenerate: true, chipIds: [tomorrow.id] })).status).toBe(422);
    expect((await generate({ regenerate: true, chipIds: ["unavailable"] })).status).toBe(422);
    expect(writer).toHaveBeenCalledTimes(1);
    const candidates = await versionsRoute.GET(apiRequest("GET", `${path.replace("?", "/versions?")}&chips=true`, { token: env.tokens.alice }));
    expect((await candidates.json()).items.map((item: { id: string }) => item.id)).toContain(one.id);
  });

  it("persists corrected caption cues in episode time", async () => {
    await chip("Caption timing");
    const response = await generate();
    expect(response.status).toBe(200);
    const { podcast } = await response.json() as { podcast: DailyPodcast };
    for (const segment of podcast.segments) {
      expect(segment.captionCues?.length).toBeGreaterThan(0);
      expect(segment.captionCues![0].startSeconds).toBeCloseTo(segment.startSeconds!, 2);
      expect(segment.captionCues!.at(-1)!.endSeconds).toBeCloseTo(segment.endSeconds!, 2);
      expect(segment.captionCues!.every(cue => !/\p{P}/u.test(cue.text))).toBe(true);
    }
    expect((await (await saved()).json()).podcast.segments).toEqual(podcast.segments);
  });

  it("does not publish an episode when transcription has no timestamps", async () => {
    await chip("Missing timestamps");
    vi.spyOn(env.ai, "transcribePodcast").mockResolvedValue([]);
    expect((await generate()).status).toBe(502);
    expect((await (await saved()).json()).podcast).toBeNull();
  });

  it("keeps versions, switches the default without AI, removes versions and revokes their links", async () => {
    await chip("Discovery");
    const first = (await (await generate()).json()).podcast as DailyPodcast;
    const second = (await (await generate({ regenerate: true })).json()).podcast as DailyPodcast;
    const versionURL = `/api/v1/daily-podcasts/versions?${new URLSearchParams(day)}`;
    const list = async () => (await (await versionsRoute.GET(apiRequest("GET", versionURL, { token: env.tokens.alice }))).json()).items;
    expect((await list()).map((v: { podcast: DailyPodcast }) => v.podcast.key).sort()).toEqual([first.key, second.key].sort());
    const action = (method: "PATCH" | "DELETE", episode: DailyPodcast, token = env.tokens.alice) => versionRoute[method](
      apiRequest(method, `/api/v1/daily-podcasts/${episode.key}?${new URLSearchParams(day)}`, { token }), params({ key: episode.key }));
    expect((await action("PATCH", first, env.tokens.bob)).status).toBe(404);
    const link = await linksRoute.POST(apiRequest("POST", `/api/v1/daily-podcasts/${first.key}/links`, { token: env.tokens.alice, body: { day } }), params({ key: first.key }));
    const shared = await link.json();
    expect(link.status).toBe(201);
    const storageCalls = ["get", "put", "delete"].map((method) =>
      vi.spyOn(env.store, method as "get").mockRejectedValue(new Error("Storage unavailable")));
    expect((await action("PATCH", first)).status).toBe(200);
    expect((await (await saved()).json()).podcast.key).toBe(first.key);
    const calls = env.ai.calls.speak.length;
    expect((await action("DELETE", first)).status).toBe(200);
    expect((await audio(first)).status).toBe(404);
    expect((await (await saved()).json()).podcast.key).toBe(second.key);
    expect((await list())).toHaveLength(1);
    const publicToken = new URL(shared.url).pathname.split("/").at(-1)!;
    expect((await publicRoute.GET(new Request(shared.url), params({ id: publicToken }))).status).toBe(404);
    expect((await action("DELETE", second)).status).toBe(200);
    expect((await (await saved()).json()).podcast).toBeNull();
    expect((await list())).toHaveLength(0);
    expect(env.ai.calls.speak.length).toBe(calls);
    for (const call of storageCalls) expect(call).not.toHaveBeenCalled();
  });

  it("creates a searchable library podcast from older chips without changing the daily default or duplicating source content", async () => {
    const today = await chip("Today");
    const old = await chip("Old source", env.tokens.alice, "2029-01-01T00:00:00Z");
    const daily = (await (await generate()).json()).podcast as DailyPodcast;
    const result = await generate({ library: true, chipIds: [old.id], regenerate: true });
    expect(result.status).toBe(200);
    const podcast = (await result.json()).podcast as DailyPodcast;
    expect(podcast.summaryId).toBeTruthy();
    await vi.waitFor(async () => {
      const headlines = await getHeadlines(env.handle.db, "user-alice");
      expect(headlines.items.find((item) => item.id === podcast.summaryId)).toMatchObject({ kind: "podcast", score: 75 });
    });
    const library = await summariesRoute.GET(apiRequest("GET", "/api/v1/summaries?kind=podcast", { token: env.tokens.alice }));
    expect((await library.json()).items.map((item: { id: string }) => item.id)).toEqual([podcast.summaryId]);
    expect((await (await saved()).json()).podcast.key).toBe(daily.key);
    const detail = await libraryPodcastRoute.GET(apiRequest("GET", `/api/v1/summaries/${podcast.summaryId}/podcast`, { token: env.tokens.alice }), params({ id: podcast.summaryId! }));
    expect((await detail.json()).podcast.key).toBe(podcast.key);
    expect((await audio(podcast, env.tokens.bob)).status).toBe(404);
    // Put the generated library chip on this activity day; it must still never become source content.
    await env.handle.db.update(summaries).set({ createdAt: new Date(day.start) }).where(eq(summaries.id, podcast.summaryId!));
    const regenerated = (await (await generate({ regenerate: true })).json()).podcast as DailyPodcast;
    expect(regenerated.chipIds).toEqual([today.id]);
    expect((await generate({ library: true, chipIds: [podcast.summaryId], regenerate: true })).status).toBe(422);
    await env.handle.db.delete(summaries).where(eq(summaries.id, podcast.summaryId!));
    expect((await audio(podcast)).status).toBe(404);
  });
});

describe("source chip video links", () => {
  it("returns only this viewer's readable saved videos, including older versions", async () => {
    const source = await chip("Source");
    const other = await chip("Other source", env.tokens.bob);
    const episode = (await (await generate({ library: true, chipIds: [source.id, other.id], includeVideo: false })).json()).podcast as DailyPodcast;
    const videoEpisode = { ...episode, video: { id: "video-1", createdAt: episode.createdAt } };
    await env.handle.db.update(podcastEpisodes).set({ document: videoEpisode }).where(eq(podcastEpisodes.key, episode.key));
    // A newer audio-only version must not hide an earlier watchable version.
    await generate({ library: true, summaryId: episode.summaryId, chipIds: [source.id], includeVideo: false, regenerate: true });
    const list = (token: string | undefined = env.tokens.alice, id = source.id) => linkedPodcastsRoute.GET(
      apiRequest("GET", `/api/v1/summaries/${id}/podcasts`, { token }), params({ id }));
    expect((await (await list()).json()).items.map((p: DailyPodcast) => p.key)).toEqual([episode.key]);
    expect((await (await list(env.tokens.bob)).json()).items).toEqual([]);
    expect((await linkedPodcastsRoute.GET(apiRequest("GET", `/api/v1/summaries/${source.id}/podcasts`), params({ id: source.id }))).status).toBe(401);
    expect((await list(env.tokens.alice, "missing")).status).toBe(404);
    await env.handle.db.update(summaries).set({ visibility: "private" }).where(eq(summaries.id, other.id));
    expect((await (await list()).json()).items).toEqual([]);
    await env.handle.db.update(summaries).set({ visibility: "public" }).where(eq(summaries.id, other.id));
    await env.handle.db.update(podcastEpisodes).set({ deleted: true }).where(eq(podcastEpisodes.key, episode.key));
    expect((await (await list()).json()).items).toEqual([]);
  });
});

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

  it("generates and reopens a complete episode for a day with more than 24 chips", async () => {
    const chips = [];
    for (let index = 0; index < 30; index++) chips.push(await chip(`Discovery ${index}`));
    const writer = vi.spyOn(env.ai, "writePodcast");
    const response = await generate();
    expect(response.status).toBe(200);
    const { podcast } = await response.json() as { podcast: DailyPodcast };
    const ids = new Set(chips.map((item) => item.id));
    expect(new Set(writer.mock.calls[0][0].chips.map((item) => item.id))).toEqual(ids);
    expect(new Set(podcast.chipIds)).toEqual(ids);
    expect(new Set(podcast.segments.map((segment) => segment.chipId))).toEqual(ids);
    expect(podcast.segments).toHaveLength(30);
    expect(env.ai.calls.speak).toHaveLength(30);
    expect(podcast.segments.at(-1)?.endSeconds).toBe(podcast.durationSeconds);
    expect((await audio(podcast)).status).toBe(200);
    expect((await (await saved()).json()).podcast).toEqual(podcast);
    expect(writer).toHaveBeenCalledTimes(1);
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

  it("reads database documents without storage and never imports storage-only episodes", async () => {
    await chip("Database episode");
    const podcast = (await (await generate()).json()).podcast as DailyPodcast;
    expect([...env.store.objects.keys()].some((key) => key.endsWith(`/latest.json`) || key.endsWith(`/${podcast.key}.json`))).toBe(false);
    const stored = { ...podcast, title: "Updated in the database" };
    await env.handle.db.update(podcastEpisodes).set({ document: stored }).where(eq(podcastEpisodes.key, podcast.key));
    const legacy = { bytes: new TextEncoder().encode(JSON.stringify(podcast)), contentType: "application/json" };
    const base = dayKey("user-alice", day);
    await env.store.put(`${base}/latest.json`, legacy);
    await env.store.put(`${base}/${podcast.key}.json`, legacy);
    const read = vi.spyOn(env.store, "get").mockRejectedValue(new Error("Storage unavailable"));
    expect((await (await saved()).json()).podcast).toEqual(stored);
    const detail = (date = day, token = env.tokens.alice) => versionRoute.GET(apiRequest("GET",
      `/api/v1/daily-podcasts/${podcast.key}?${new URLSearchParams(date)}`, { token }), params({ key: podcast.key }));
    expect((await (await detail()).json()).podcast).toEqual(stored);
    expect((await detail(day, env.tokens.bob)).status).toBe(404);
    expect((await detail({ start: "2030-04-02T00:00:00+08:00", end: "2030-04-03T00:00:00+08:00" })).status).toBe(404);
    const list = () => versionsRoute.GET(apiRequest("GET", `/api/v1/daily-podcasts/versions?${new URLSearchParams(day)}`, { token: env.tokens.alice }));
    expect((await (await list()).json()).items[0].podcast).toEqual(stored);
    expect((await versionsRoute.GET(apiRequest("GET", `/api/v1/daily-podcasts/versions?${new URLSearchParams(day)}`, { token: env.tokens.bob }))).status).toBe(200);
    await env.handle.db.delete(podcastEpisodes).where(eq(podcastEpisodes.key, podcast.key));
    expect((await (await saved()).json()).podcast).toBeNull();
    expect((await (await list()).json()).items).toEqual([]);
    expect((await audio(podcast)).status).toBe(404);
    expect(read).not.toHaveBeenCalled();
  });

  it("omits versions whose source access was revoked", async () => {
    await saved();
    const shared = await chip("Shared source", env.tokens.bob);
    await env.handle.db.insert(summaryViews).values({ summaryId: shared.id, userId: "user-alice", viewedAt: new Date(day.start) });
    await generate();
    const own = await chip("Own source");
    const allowed = (await (await generate({ regenerate: true, chipIds: [own.id] })).json()).podcast;
    await env.handle.db.update(summaries).set({ visibility: "private" }).where(eq(summaries.id, shared.id));
    const response = await versionsRoute.GET(apiRequest("GET", `/api/v1/daily-podcasts/versions?${new URLSearchParams(day)}`, { token: env.tokens.alice }));
    expect((await response.json()).items.map((item: { podcast: DailyPodcast }) => item.podcast.key)).toEqual([allowed.key]);
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
    const articleWriter = vi.spyOn(env.ai, "writePodcastArticle");
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
    expect(data.article.sections[0].startSeconds).toBe(podcast.segments[0].startSeconds);
    expect(data.article.sections[0].paragraphs[0]).not.toBe(podcast.segments[0].caption);
    const cover = () => publicCover.GET(apiRequest("GET", data.coverPath), params({ id }));
    const image = await cover();
    expect(image.status).toBe(200);
    expect(image.headers.get("content-type")).toBe("image/png");
    expect(image.headers.get("cache-control")).toBe("private, no-store");
    expect([...new Uint8Array(await image.arrayBuffer()).slice(0, 8)]).toEqual([137, 80, 78, 71, 13, 10, 26, 10]);
    const metadata = await generateMetadata({ params: Promise.resolve({ id }), searchParams: Promise.resolve({}) });
    expect(metadata.openGraph).toMatchObject({ title: podcast.title, description: data.article.description });
    expect(metadata.twitter).toMatchObject({ card: "summary_large_image" });
    expect(articleWriter).toHaveBeenCalledTimes(1);
    expect(data.audioPath).toBe(`/api/public/podcasts/${id}/audio`);
    expect(data.segments[0].caption).toBe(podcast.segments[0].caption);
    expect(data.segments[0].captionCues).toEqual(podcast.segments[0].captionCues);
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
    expect((await cover()).status).toBe(404);
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
    expect((await cover()).status).toBe(404);
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

describe("live podcast progress", () => {
  function streamRequest() {
    const request = apiRequest("POST", "/api/v1/daily-podcasts", { token: env.tokens.alice, body: { day, language: "ja", regenerate: true } });
    request.headers.set("accept", "text/event-stream");
    return request;
  }
  function events(text: string) {
    return text.split("\n").filter((line) => line.startsWith("data: ")).map((line) => JSON.parse(line.slice(6)));
  }
  it("delivers progress before speech finishes and shares generation with another subscriber", async () => {
    await chip("Streamed discovery");
    const speak = env.ai.speak.bind(env.ai);
    let release!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const spy = vi.spyOn(env.ai, "speak").mockImplementation(async (...args) => { await gate; return speak(...args); });
    const first = await route.POST(streamRequest());
    expect(first.headers.get("content-type")).toContain("text/event-stream");
    const reader = first.body!.getReader();
    const decoder = new TextDecoder();
    let text = "";
    try {
      while (!events(text).some((event) => event.progress?.stage === "speech")) {
        text += decoder.decode((await reader.read()).value);
      }
      expect(events(text).some((event) => event.type === "complete")).toBe(false);
      const second = await route.POST(streamRequest());
      release();
      while (true) { const next = await reader.read(); if (next.done) break; text += decoder.decode(next.value); }
      const one = events(text);
      const two = events(await second.text());
      const progress = one.filter((event) => event.type === "progress").map((event) => event.progress);
      expect(progress.map((p) => p.percent)).toEqual(progress.map((p) => p.percent).sort((a, b) => a - b));
      expect(progress.at(-1).percent).toBe(100);
      const speech = progress.filter((p) => p.stage === "speech");
      expect(speech.at(-1).completedSegments).toBe(speech.at(-1).totalSegments);
      expect(spy).toHaveBeenCalledTimes(speech.at(-1).totalSegments);
      expect(two[0].progress.stage).toBe("speech");
      expect(two.at(-1).podcast.key).toBe(one.at(-1).podcast.key);
      expect((await (await saved()).json()).podcast.key).toBe(one.at(-1).podcast.key);
    } finally { release(); }
  });
  it.skipIf(!process.env.PODCAST_SIMULATION_URL)("streams generation using the real SDK against the HTTP simulation", async () => {
    await chip("HTTP streamed discovery");
    const gateway = createGateway({ baseURL: process.env.PODCAST_SIMULATION_URL, apiKey: "local-fixture-only" });
    vi.spyOn(env.ai as AiProvider, "writePodcast").mockImplementation((input, options) => writePodcast(gateway("fixture/podcast"), input, options));
    vi.spyOn(env.ai as AiProvider, "speak").mockImplementation(async (text, voice) => {
      const result = await generateSpeech({ model: gateway.speechModel("fixture/speech"), text, voice, outputFormat: "mp3" });
      return { bytes: result.audio.uint8Array, mediaType: "audio/mpeg" };
    });
    const result = events(await (await route.POST(streamRequest())).text());
    expect(result.some((event) => event.progress?.completedSegments > 0)).toBe(true);
    expect(result.at(-1).type).toBe("complete");
    expect(result.at(-1).podcast.durationSeconds).toBeGreaterThan(0);
  });

  it("ends with a structured error without completion on failed speech", async () => {
    await chip("Failed speech");
    vi.spyOn(env.ai, "speak").mockRejectedValue(new Error("Provider unavailable"));
    const result = events(await (await route.POST(streamRequest())).text());
    expect(result.at(-1)).toMatchObject({ type: "error", status: 502, error: { code: "PODCAST_FAILED" } });
    expect(result.some((event) => event.type === "complete" || event.progress?.percent === 100)).toBe(false);
  });
});
