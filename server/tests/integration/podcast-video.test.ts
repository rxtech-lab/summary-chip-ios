import { createGateway } from "@ai-sdk/gateway";
import type { AiProvider } from "@/lib/ai/provider";
import { writePodcastVideo } from "@/lib/ai/podcast-video-agent";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { eq } from "drizzle-orm";
import * as route from "@/app/api/v1/daily-podcasts/route";
import * as videoRoute from "@/app/api/v1/daily-podcasts/[key]/video/route";
import * as uploadRoute from "@/app/api/v1/daily-podcasts/[key]/video/upload/route";
import * as publicationRoute from "@/app/api/v1/daily-podcasts/[key]/video/publication/route";
import * as linksRoute from "@/app/api/v1/daily-podcasts/[key]/links/route";
import * as publicRoute from "@/app/api/public/podcasts/[id]/route";
import * as publicVideo from "@/app/api/public/podcasts/[id]/video/route";
import * as summariesRoute from "@/app/api/v1/summaries/route";
import { summaries } from "@/lib/db/schema";
import type { DailyPodcast, PodcastVideoSource } from "@/lib/contracts/daily-podcast";
import { PODCAST_VIDEO_SCAFFOLD, validatePodcastVideo } from "@/lib/podcast-video/scaffold";
import { apiRequest, params, setupTestEnv, type TestEnv } from "../helpers/setup";

let env: TestEnv;
const day = { start: "2030-04-01T00:00:00+08:00", end: "2030-04-02T00:00:00+08:00" };
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
async function generate(includeVideo?: boolean): Promise<DailyPodcast> {
  const response = await route.POST(apiRequest("POST", "/api/v1/daily-podcasts", { token: env.tokens.alice, body: { day, language: "en", includeVideo } }));
  expect(response.status).toBe(200);
  return (await response.json()).podcast;
}
const query = `?${new URLSearchParams(day)}`;
const source = (key: string, token = env.tokens.alice) => videoRoute.GET(apiRequest("GET", `/video${query}`, { token }), params({ key }));
const compose = (key: string, token = env.tokens.alice) => videoRoute.POST(apiRequest("POST", "/video", { token, body: { day } }), params({ key }));
const upload = (key: string, body: object) => uploadRoute.POST(apiRequest("POST", "/upload", { token: env.tokens.alice, body: { day, ...body } }), params({ key }));
const publish = (key: string, videoId: string) => publicationRoute.POST(apiRequest("POST", "/publication", { token: env.tokens.alice, body: { day, videoId } }), params({ key }));

describe("podcast motion video", () => {
  it("honors audio-only selection even when video generation is configured", async () => {
    env.ai.video = true;
    await chip("Audio only");
    const episode = await generate(false);
    expect(episode.video).toBeUndefined();
    expect(env.ai.calls.writePodcastVideo).toHaveLength(0);
    const updated = await compose(episode.key);
    expect(updated.status).toBe(200);
    expect((await updated.json()).podcast.video.id).toBeTruthy();
    expect(env.ai.calls.writePodcastVideo).toHaveLength(1);
  });
  it("writes the composition alongside the recording, after transcription, from the real phrase timings", async () => {
    env.ai.video = true;
    const topic = await chip("Batteries");
    const podcast = await generate();
    expect(podcast.video?.id).toMatch(/^[0-9a-f-]{36}$/);
    expect(env.ai.calls.writePodcastVideo).toHaveLength(1);
    const input = env.ai.calls.writePodcastVideo[0];
    expect(input.chips).toEqual([{ id: topic.id, title: "Batteries" }]);
    // Speech is transcribed and mixed first, so the agent stages scenes on the phrases at their real times.
    const [segment] = podcast.segments;
    expect(input.segments[0]).toMatchObject({ startSeconds: segment.startSeconds, voiceStartSeconds: segment.voiceStartSeconds,
      phrases: segment.captionCues!.map(({ text, startSeconds, endSeconds }) => ({ text, startSeconds, endSeconds })) });
    const response = await source(podcast.key);
    expect(response.status).toBe(200);
    const video = (await response.json()).video as PodcastVideoSource;
    expect(video).toMatchObject({ id: podcast.video!.id, model: "mock/video", fps: 24, width: 1280, height: 720 });
    expect(Object.keys(video.files).sort()).toEqual(["src/Root.tsx", "src/Video.tsx", "src/index.ts", "src/phrases.json", "src/podcast.ts"]);
    expect(JSON.parse(video.files["src/phrases.json"])).toHaveLength(podcast.segments.length);
    expect((await source(podcast.key, env.tokens.bob)).status).toBe(404);
  });

  it("publishes episodes without video when the model is off or fails, and composes one on request", async () => {
    await chip("Rivers");
    const plain = await generate();
    expect(plain.video).toBeUndefined();
    expect((await source(plain.key)).status).toBe(404);
    expect((await compose(plain.key)).status).toBe(503);

    env.ai.video = true;
    vi.spyOn(env.ai, "writePodcastVideo").mockRejectedValueOnce(new Error("model down"));
    const failed = await (await route.POST(apiRequest("POST", "/api/v1/daily-podcasts", { token: env.tokens.alice, body: { day, language: "en", regenerate: true } }))).json();
    expect(failed.podcast.video).toBeUndefined();

    expect((await compose(plain.key, env.tokens.bob)).status).toBe(404);
    const composed = await compose(plain.key);
    expect(composed.status).toBe(200);
    const updated = (await composed.json()).podcast as DailyPodcast;
    expect(updated.video?.id).toBeDefined();
    expect((await source(plain.key)).status).toBe(200);
  });

  it("uploads the device render, plays it through share links and drops it when the composition changes", async () => {
    env.ai.video = true;
    await chip("Volcanoes");
    const podcast = await generate();
    const videoId = podcast.video!.id;
    expect((await upload(podcast.key, { videoId: crypto.randomUUID(), byteSize: 10 })).status).toBe(409);
    expect((await upload(podcast.key, { videoId, byteSize: 0 })).status).toBe(400);
    const signed = await upload(podcast.key, { videoId, byteSize: 4 });
    expect(signed.status).toBe(201);
    const { uploadUrl, headers } = await signed.json();
    expect(headers["content-type"]).toBe("video/mp4");
    expect((await publish(podcast.key, videoId)).status).toBe(409);
    const objectKey = decodeURIComponent(new URL(uploadUrl).pathname.slice(1));
    await env.store.put(objectKey, { bytes: new Uint8Array([0, 0, 0, 1]), contentType: "video/mp4" });
    const published = await publish(podcast.key, videoId);
    expect(published.status).toBe(200);
    expect((await published.json()).podcast.video.published).toMatchObject({ videoId, byteSize: 4 });

    const link = await (await linksRoute.POST(apiRequest("POST", "/links", { token: env.tokens.alice, body: { day } }), params({ key: podcast.key }))).json();
    const id = new URL(link.url).pathname.split("/").at(-1)!;
    const data = async () => (await publicRoute.GET(apiRequest("GET", "/podcast"), params({ id }))).json();
    expect((await data()).videoPath).toBe(`/api/public/podcasts/${id}/video`);
    const redirect = await publicVideo.GET(apiRequest("GET", "/video"), params({ id }));
    expect(redirect.status).toBe(302);
    expect(redirect.headers.get("location")).toContain(encodeURIComponent(objectKey));
    expect(redirect.headers.get("cache-control")).toBe("private, no-store");

    // A rewritten composition makes the old render stale until it's re-rendered and published.
    await compose(podcast.key);
    expect(env.store.objects.has(objectKey)).toBe(false);
    expect((await data()).videoPath).toBeNull();
    expect((await publicVideo.GET(apiRequest("GET", "/video"), params({ id }))).status).toBe(404);
    expect((await publish(podcast.key, videoId)).status).toBe(409);

    const removed = await publicationRoute.DELETE(apiRequest("DELETE", `/publication${query}`, { token: env.tokens.alice }), params({ key: podcast.key }));
    expect(removed.status).toBe(200);
    expect((await removed.json()).podcast.video.published).toBeUndefined();
  });
});

describe("podcast video validation", () => {
  const video = (body: string) => ({ "src/Video.tsx": `import { AbsoluteFill } from "remotion";\nimport { useSegment, useSceneMotion } from "./podcast";\n${body}` });
  const ok = `export const PodcastVideo: React.FC = () => { const { segment } = useSegment(); const { elapsedSeconds } = useSceneMotion(); return <AbsoluteFill>{segment?.chipTitle}<div style={{ left: 100 + Math.sin(elapsedSeconds) * 80 }} /></AbsoluteFill>; };`;

  it("accepts a composition that compiles against the scaffold", async () => {
    expect(await validatePodcastVideo({ ...video(ok), "src/parts/Title.tsx": "export const Title = () => <h1>Hi</h1>;" })).toEqual([]);
  });

  it("reports compile errors, missing exports and unsupported imports with locations", async () => {
    expect((await validatePodcastVideo(video("export const PodcastVideo = () => <div>;")))[0].message).toMatch(/^\d+:\d+ /);
    expect((await validatePodcastVideo(video("export const Other = () => null;")))[0].message).toContain("PodcastVideo");
    expect((await validatePodcastVideo({ "src/Video.tsx": `import * as THREE from "three";\n${ok}\nexport const scene = new THREE.Scene();` }))[0].message).toContain('Unsupported import "three"');
    expect(await validatePodcastVideo({ "src/Other.tsx": ok })).toContainEqual({ message: "Write src/Video.tsx, exporting PodcastVideo" });
  });

  it("rejects network access, timers, raw media, 3D effects and scaffold overrides", async () => {
    for (const snippet of ["fetch('/x')", "setTimeout(() => {}, 1)", "const u = 'https://evil.example'", "<Audio src='a.mp3' />",
      "const s = { backdropFilter: 'blur(4px)' }", "const t = 'rotateY(20deg)'", "localStorage.getItem('a')", "eval('1')"]) {
      expect(await validatePodcastVideo(video(`${ok}\n${snippet};`)), snippet).not.toEqual([]);
    }
    expect(await validatePodcastVideo({ ...video(ok), "src/Root.tsx": PODCAST_VIDEO_SCAFFOLD["src/Root.tsx"] })).toContainEqual({ file: "src/Root.tsx", message: "This file is provided; don't write it" });
    expect(await validatePodcastVideo({ ...video(ok), "../escape.ts": "" })).not.toEqual([]);
  });
});

describe("video generation stream", () => {
  function request() {
    const req = apiRequest("POST", "/video", { token: env.tokens.alice, body: { day } });
    req.headers.set("accept", "text/event-stream");
    return req;
  }
  const events = (text: string) => text.split("\n").filter(line => line.startsWith("data: ")).map(line => JSON.parse(line.slice(6)));
  it("streams before design completes and shares work between observers", async () => {
    await chip("Video stream");
    const episode = await generate();
    env.ai.video = true;
    const original = env.ai.writePodcastVideo.bind(env.ai);
    let release!: () => void;
    const gate = new Promise<void>(resolve => { release = resolve; });
    const spy = vi.spyOn(env.ai, "writePodcastVideo").mockImplementation(async (...args) => { await gate; const result = await original(...args); (args[1] as import("@/lib/ai/podcast-video-agent").PodcastVideoOptions)?.onProgress?.(50); return result; });
    const first = await videoRoute.POST(request(), params({ key: episode.key }));
    expect(first.headers.get("content-type")).toContain("text/event-stream");
    const reader = first.body!.getReader();
    let text = "";
    try {
      while (!events(text).some(event => event.progress?.stage === "video-design")) {
        text += new TextDecoder().decode((await reader.read()).value);
      }
      expect(events(text).some(event => event.type === "complete")).toBe(false);
      const second = await videoRoute.POST(request(), params({ key: episode.key }));
      release();
      while (true) { const next = await reader.read(); if (next.done) break; text += new TextDecoder().decode(next.value); }
      const result = events(text);
      const other = events(await second.text());
      expect(result.filter(event => event.type === "progress").map(event => event.progress.percent)).toEqual([0, 10, 50, 90, 100]);
      expect(result.find(event => event.progress?.completedSteps === 1).progress.stage).toBe("video-design");
      expect(result.at(-1).podcast.video.id).toBe(other.at(-1).podcast.video.id);
      expect(other[0].progress.stage).toBe("video-design");
      expect(spy).toHaveBeenCalledTimes(1);
    } finally { release(); }
  });
  it.skipIf(!process.env.PODCAST_SIMULATION_URL)("streams completed agent steps through the real SDK over HTTP", async () => {
    await chip("HTTP video");
    const episode = await generate();
    env.ai.video = true;
    const gateway = createGateway({ baseURL: process.env.PODCAST_SIMULATION_URL, apiKey: "local-fixture-only" });
    vi.spyOn(env.ai as AiProvider, "writePodcastVideo").mockImplementation((input, options) => writePodcastVideo(gateway("fixture/video"), input, options));
    const result = events(await (await videoRoute.POST(request(), params({ key: episode.key }))).text());
    expect(result.some(event => event.progress?.stage === "video-design")).toBe(true);
    expect(result.at(-1).type).toBe("complete");
    expect(result.at(-1).podcast.video.id).toBeTruthy();
  });
  it("streams failures without a success or 100 percent event", async () => {
    await chip("Failed video");
    const episode = await generate();
    env.ai.video = true;
    vi.spyOn(env.ai, "writePodcastVideo").mockRejectedValue(new Error("Unavailable"));
    const result = events(await (await videoRoute.POST(request(), params({ key: episode.key }))).text());
    expect(result.at(-1)).toMatchObject({ type: "error", status: 502, error: { code: "PODCAST_VIDEO_FAILED" } });
    expect(result.some(event => event.type === "complete" || event.progress?.percent === 100)).toBe(false);
  });
});
