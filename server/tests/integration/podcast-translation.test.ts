import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { eq } from "drizzle-orm";
import * as route from "@/app/api/v1/daily-podcasts/route";
import * as episodeRoute from "@/app/api/v1/daily-podcasts/[key]/route";
import * as audioRoute from "@/app/api/v1/daily-podcasts/[key]/audio/route";
import * as translationsRoute from "@/app/api/v1/daily-podcasts/[key]/translations/route";
import * as translationRoute from "@/app/api/v1/daily-podcasts/[key]/translations/[language]/route";
import * as videoRoute from "@/app/api/v1/daily-podcasts/[key]/video/route";
import * as uploadRoute from "@/app/api/v1/daily-podcasts/[key]/video/upload/route";
import * as publicationRoute from "@/app/api/v1/daily-podcasts/[key]/video/publication/route";
import * as versionsRoute from "@/app/api/v1/daily-podcasts/versions/route";
import * as linksRoute from "@/app/api/v1/daily-podcasts/[key]/links/route";
import * as libraryPodcastRoute from "@/app/api/v1/summaries/[id]/podcast/route";
import * as publicRoute from "@/app/api/public/podcasts/[id]/route";
import * as publicAudio from "@/app/api/public/podcasts/[id]/audio/route";
import * as publicVideo from "@/app/api/public/podcasts/[id]/video/route";
import * as summariesRoute from "@/app/api/v1/summaries/route";
import { podcastEpisodes, summaries } from "@/lib/db/schema";
import type { DailyPodcast, PodcastVideoSource } from "@/lib/contracts/daily-podcast";
import { apiRequest, params, setupTestEnv, type TestEnv } from "../helpers/setup";

let env: TestEnv;
const day = { start: "2030-04-01T00:00:00+08:00", end: "2030-04-02T00:00:00+08:00" };
const query = new URLSearchParams(day);
beforeEach(async () => { env = await setupTestEnv(); });
afterEach(() => { vi.restoreAllMocks(); env.teardown(); });

async function chip(title: string) {
  const response = await summariesRoute.POST(apiRequest("POST", "/api/v1/summaries", { token: env.tokens.alice, body: {
    source: { type: "text", text: `${title}: researchers studied this topic and published their results.`, title }, followLinks: false,
  } }));
  const result = await response.json();
  await env.handle.db.update(summaries).set({ createdAt: new Date(day.start) }).where(eq(summaries.id, result.id));
  return result;
}
async function generate(extra: object = {}): Promise<DailyPodcast> {
  const response = await route.POST(apiRequest("POST", "/api/v1/daily-podcasts", { token: env.tokens.alice, body: { day, language: "en", ...extra } }));
  expect(response.status).toBe(200);
  return (await response.json()).podcast;
}
const translate = (key: string, language: string, token = env.tokens.alice) =>
  translationsRoute.POST(apiRequest("POST", `/api/v1/daily-podcasts/${key}/translations`, { token, body: { day, language } }), params({ key }));
const episode = (key: string, language?: string) => episodeRoute.GET(apiRequest("GET",
  `/api/v1/daily-podcasts/${key}?${new URLSearchParams({ ...day, ...(language ? { language } : {}) })}`, { token: env.tokens.alice }), params({ key }));
const audio = (podcast: DailyPodcast) => audioRoute.GET(apiRequest("GET", podcast.audioPath!, { token: env.tokens.alice }), params({ key: podcast.key }));

describe("podcast translations", () => {
  it("speaks an episode in another language turn for turn and serves each language separately", async () => {
    await chip("Volcanoes");
    await chip("Glaciers");
    const original = await generate();
    expect(original).toMatchObject({ language: "en", originalLanguage: "en", languages: ["en"] });
    const speech = env.ai.calls.speak.length;
    const response = await translate(original.key, "fr");
    expect(response.status).toBe(200);
    const french = (await response.json()).podcast as DailyPodcast;
    expect(french).toMatchObject({ key: original.key, language: "fr", originalLanguage: "en", languages: ["en", "fr"], title: `[French] ${original.title}` });
    expect(french).not.toHaveProperty("translations");
    expect(french.audioPath).toContain("language=fr");
    expect(french.segments.map((segment) => [segment.speaker, segment.chipId, segment.imagePath]))
      .toEqual(original.segments.map((segment) => [segment.speaker, segment.chipId, segment.imagePath]));
    expect(french.segments.map((segment) => segment.caption)).toEqual(original.segments.map((segment) => `[French] ${segment.caption}`));
    expect(french.segments.every((segment) => segment.captionCues?.length && segment.startSeconds !== undefined)).toBe(true);
    expect(env.ai.calls.speak.length - speech).toBe(original.segments.length);
    expect(env.ai.calls.speak.slice(speech).every((text) => text.startsWith("[French] "))).toBe(true);
    const frenchAudio = await audio(french);
    expect(frenchAudio.status).toBe(200);
    expect(frenchAudio.headers.get("content-disposition")).toContain(`podcast-${original.key}-fr.mp3`);
    expect([...env.store.objects.keys()].some((key) => key.endsWith(`/${original.key}/translations/fr/audio.mp3`))).toBe(true);
    expect((await audio(original)).status).toBe(200);

    // The original stays the default presentation; a translation is opened by language and is free to reopen.
    expect((await (await episode(original.key)).json()).podcast).toMatchObject({ language: "en", languages: ["en", "fr"] });
    expect((await (await episode(original.key, "fr")).json()).podcast.title).toBe(french.title);
    expect((await episode(original.key, "de")).status).toBe(404);
    expect((await (await route.GET(apiRequest("GET", `/api/v1/daily-podcasts?${new URLSearchParams({ ...day, language: "fr" })}`, { token: env.tokens.alice }))).json()).podcast.language).toBe("fr");
    expect((await translate(original.key, "fr")).status).toBe(200);
    expect(env.ai.calls.translatePodcast).toHaveLength(1);
    expect((await translate(original.key, "en")).status).toBe(422);
    expect((await translate(original.key, "ja", env.tokens.bob)).status).toBe(404);

    const removed = await translationRoute.DELETE(apiRequest("DELETE", `/api/v1/daily-podcasts/${original.key}/translations/fr?${query}`, { token: env.tokens.alice }),
      params({ key: original.key, language: "fr" }));
    expect(removed.status).toBe(200);
    expect((await removed.json()).podcast.languages).toEqual(["en"]);
    expect((await audio(french)).status).toBe(404);
  });

  it("keeps the episode untranslated when the translation fails", async () => {
    await chip("Tides");
    const original = await generate();
    env.ai.translates = false;
    expect((await translate(original.key, "ja")).status).toBe(502);
    expect((await (await episode(original.key)).json()).podcast.languages).toEqual(["en"]);
  });

  it("reuses the composition with translated titles and labels, and publishes and shares each language's video", async () => {
    env.ai.video = true;
    await chip("Volcanoes");
    const created = await generate();
    // The original's video is designed in the background before a translation can reuse it.
    await env.runPodcastVideoDesigns();
    const original = (await (await episode(created.key)).json()).podcast as typeof created;
    const japanese = (await (await translate(original.key, "ja")).json()).podcast as DailyPodcast;
    expect(japanese.video?.id).toBeTruthy();
    expect(japanese.video!.id).not.toBe(original.video!.id);
    expect(env.ai.calls.writePodcastVideo).toHaveLength(1);
    const source = async (language?: string) => (await (await videoRoute.GET(apiRequest("GET",
      `/video?${new URLSearchParams({ ...day, ...(language ? { language } : {}) })}`, { token: env.tokens.alice }), params({ key: original.key }))).json()).video as PodcastVideoSource;
    const translated = await source("ja");
    expect(translated.id).toBe(japanese.video!.id);
    expect(translated.chips[0].title).toMatch(/^\[Japanese\] /);
    expect(translated.files["src/Video.tsx"]).toMatch(/^\/\/ Japanese/);
    expect((await source()).files["src/Video.tsx"]).not.toMatch(/^\/\/ Japanese/);

    const videoId = japanese.video!.id;
    const signed = await uploadRoute.POST(apiRequest("POST", "/upload", { token: env.tokens.alice, body: { day, videoId, byteSize: 4, language: "ja" } }), params({ key: original.key }));
    expect(signed.status).toBe(201);
    const objectKey = decodeURIComponent(new URL((await signed.json()).uploadUrl).pathname.slice(1));
    await env.store.put(objectKey, { bytes: new Uint8Array([0, 0, 0, 1]), contentType: "video/mp4" });
    const published = await publicationRoute.POST(apiRequest("POST", "/publication", { token: env.tokens.alice, body: { day, videoId, language: "ja" } }), params({ key: original.key }));
    expect(published.status).toBe(200);
    expect((await published.json()).podcast).toMatchObject({ language: "ja", video: { published: { videoId } } });
    expect((await (await episode(original.key)).json()).podcast.video.published).toBeUndefined();

    const link = await (await linksRoute.POST(apiRequest("POST", "/links", { token: env.tokens.alice, body: { day } }), params({ key: original.key }))).json();
    const id = new URL(link.url).pathname.split("/").at(-1)!;
    const data = async (language?: string) => (await publicRoute.GET(apiRequest("GET", `/podcast${language ? `?language=${language}` : ""}`), params({ id }))).json();
    expect(await data()).toMatchObject({ language: "en", languages: ["en", "ja"], videoPath: null });
    expect(await data("ja")).toMatchObject({ language: "ja", videoPath: `/api/public/podcasts/${id}/video?language=ja`, audioPath: `/api/public/podcasts/${id}/audio?language=ja` });
    expect((await data("ko")).language).toBe("en");
    const sharedAudio = await publicAudio.GET(apiRequest("GET", "/audio?language=ja"), params({ id }));
    expect(sharedAudio.status).toBe(200);
    expect(Number(sharedAudio.headers.get("content-length"))).toBe(
      env.store.objects.get([...env.store.objects.keys()].find((key) => key.endsWith("/translations/ja/audio.mp3"))!)!.bytes.length);
    expect((await publicVideo.GET(apiRequest("GET", "/video?language=ja"), params({ id }))).headers.get("location")).toContain(encodeURIComponent(objectKey));

    // A new original composition replaces the translated one, which can be made again from it.
    await videoRoute.POST(apiRequest("POST", "/video", { token: env.tokens.alice, body: { day } }), params({ key: original.key }));
    await env.runPodcastVideoDesigns();
    expect(env.store.objects.has(objectKey)).toBe(false);
    expect((await (await episode(original.key, "ja")).json()).podcast.video).toBeUndefined();
    const remade = await videoRoute.POST(apiRequest("POST", "/video", { token: env.tokens.alice, body: { day, language: "ja" } }), params({ key: original.key }));
    expect(remade.status).toBe(200);
    expect((await remade.json()).podcast).toMatchObject({ language: "ja", video: { id: expect.any(String) } });
    expect(env.ai.calls.writePodcastVideo).toHaveLength(2);
  });
});

describe("library podcast versions", () => {
  it("regenerates a library podcast as a new version of the same chip", async () => {
    const source = await chip("Old source");
    const first = await generate({ library: true, chipIds: [source.id], regenerate: true });
    const chipRow = async () => (await env.handle.db.select().from(summaries).where(eq(summaries.id, first.summaryId!)))[0];
    const firstCover = await chipRow();
    // The chip gets a podcast cover illustrated like other chips.
    expect(firstCover).toMatchObject({ imageStyle: "illustration", ogImageKey: expect.any(String), artImageKey: expect.any(String) });
    expect(env.ai.calls.illustrate.at(-1)).toMatchObject({ kind: "podcast" });
    const second = await generate({ library: true, chipIds: [source.id], regenerate: true, summaryId: first.summaryId });
    expect(second.summaryId).toBe(first.summaryId);
    expect(second.key).not.toBe(first.key);
    // Regenerating redraws the cover and retires the old images.
    const secondCover = await chipRow();
    expect(secondCover.ogImageKey).toBeTruthy();
    expect(secondCover.ogImageKey).not.toBe(firstCover.ogImageKey);
    expect(env.store.objects.has(firstCover.ogImageKey!)).toBe(false);
    expect(env.store.objects.has(firstCover.artImageKey!)).toBe(false);
    const library = await summariesRoute.GET(apiRequest("GET", "/api/v1/summaries?kind=podcast", { token: env.tokens.alice }));
    expect((await library.json()).items.map((item: { id: string }) => item.id)).toEqual([first.summaryId]);

    const versions = async () => (await (await versionsRoute.GET(apiRequest("GET", `/api/v1/daily-podcasts/versions?summaryId=${first.summaryId}`, { token: env.tokens.alice }))).json()).items as { podcast: DailyPodcast; isDefault: boolean }[];
    expect((await versions()).map((item) => [item.podcast.key, item.isDefault])).toEqual([[second.key, true], [first.key, false]]);
    const opened = async () => (await (await libraryPodcastRoute.GET(apiRequest("GET", `/api/v1/summaries/${first.summaryId}/podcast`, { token: env.tokens.alice }), params({ id: first.summaryId! }))).json()).podcast.key;
    expect(await opened()).toBe(second.key);

    const action = (method: "PATCH" | "DELETE", podcast: DailyPodcast) => episodeRoute[method](
      apiRequest(method, `/api/v1/daily-podcasts/${podcast.key}?${new URLSearchParams(podcast.day)}`, { token: env.tokens.alice }), params({ key: podcast.key }));
    expect((await action("PATCH", first)).status).toBe(200);
    expect(await opened()).toBe(first.key);
    expect((await action("DELETE", first)).status).toBe(200);
    expect(await opened()).toBe(second.key);
    expect((await action("DELETE", second)).status).toBe(422);
    // A daily default on the same day leaves the library chip's default alone.
    await generate();
    expect(await opened()).toBe(second.key);
    const [row] = await env.handle.db.select().from(podcastEpisodes).where(eq(podcastEpisodes.key, second.key));
    expect(row.isDefault).toBe(true);
  });

  it("only regenerates the caller's own podcast chips", async () => {
    const source = await chip("Source");
    expect((await route.POST(apiRequest("POST", "/api/v1/daily-podcasts", { token: env.tokens.alice,
      body: { day, language: "en", chipIds: [source.id], summaryId: source.id } }))).status).toBe(400);
    expect((await route.POST(apiRequest("POST", "/api/v1/daily-podcasts", { token: env.tokens.alice,
      body: { day, language: "en", library: true, chipIds: [source.id], summaryId: source.id } }))).status).toBe(404);
  });
});
