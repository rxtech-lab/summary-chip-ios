import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { eq } from "drizzle-orm";
import * as create from "@/app/api/v1/audiobooks/route";
import * as optionsRoute from "@/app/api/v1/audiobooks/options/route";
import * as sampleRoute from "@/app/api/v1/audiobooks/voices/sample/route";
import * as planList from "@/app/api/v1/audiobooks/plans/route";
import * as planRoute from "@/app/api/v1/audiobooks/plans/[id]/route";
import * as messagesRoute from "@/app/api/v1/audiobooks/plans/[id]/messages/route";
import * as framesRoute from "@/app/api/v1/audiobooks/plans/[id]/frames/route";
import * as jobRoute from "@/app/api/v1/audiobooks/jobs/[id]/route";
import * as translations from "@/app/api/v1/audiobooks/[key]/translations/route";
import * as linkRoute from "@/app/api/v1/daily-podcasts/[key]/audio/link/route";
import * as audioRoute from "@/app/api/v1/daily-podcasts/[key]/audio/route";
import * as summariesRoute from "@/app/api/v1/summaries/route";
import { podcastEpisodes, summaries } from "@/lib/db/schema";
import { setAudiobookStarterForTests } from "@/lib/services/audiobook-starter";
import { runAudiobookJob, type AudiobookJobInput } from "@/lib/services/audiobooks";
import { runAudiobookVideoJob, type AudiobookVideoJob } from "@/lib/services/audiobook-video";
import { voiceSampleKey } from "@/lib/services/audiobook-voices";
import { podcastInLanguage } from "@/lib/services/daily-podcast";
import { podcastVideoSource } from "@/lib/services/podcast-video";
import { apiRequest, params, setupTestEnv, type TestEnv } from "../helpers/setup";

let env: TestEnv;
let jobs: AudiobookJobInput[];
let videos: AudiobookVideoJob[];
const day = { start: "2030-04-01T00:00:00+08:00", end: "2030-04-02T00:00:00+08:00" };

beforeEach(async () => {
  env = await setupTestEnv();
  jobs = [];
  videos = [];
  setAudiobookStarterForTests({ start: async (job) => { jobs.push(job); }, startVideo: async (job) => { videos.push(job); } });
  vi.stubEnv("AZURE_SPEECH_KEY", "");
  vi.stubEnv("AZURE_SPEECH_REGION", "");
});
afterEach(() => { setAudiobookStarterForTests(undefined); vi.unstubAllEnvs(); vi.restoreAllMocks(); env.teardown(); });

const text = Array.from({ length: 30 }, (_, index) => `The keeper climbed the stairs for the ${index}th time. ${"The sea was loud that night. ".repeat(20)}`).join("\n\n");
async function chip(token = env.tokens.alice, source = text) {
  const response = await summariesRoute.POST(apiRequest("POST", "/api/v1/summaries", { token, body: { source: { type: "text", text: source, title: "The Lighthouse" }, followLinks: false } }));
  expect(response.status).toBe(201);
  return (await response.json()).id as string;
}
const body = (chipIds: string[], extra: object = {}) => ({ day, language: "en", chipIds, planMode: true, ...extra });
async function draft(extra: object = {}) {
  const response = await create.POST(apiRequest("POST", "/api/v1/audiobooks", { token: env.tokens.alice, body: body([await chip()], extra) }));
  expect(response.status).toBe(200);
  return (await response.json()).plan;
}
function planRequest(method: string, id: string, payload?: unknown, token = env.tokens.alice, suffix = "") {
  return apiRequest(method, `/api/v1/audiobooks/plans/${id}${suffix}`, { token, body: payload });
}
/** Confirms a plan and runs its workflow's steps here. */
async function generate(plan: { id: string; revision: number }) {
  const confirmed = await planRoute.POST(planRequest("POST", plan.id, { revision: plan.revision }), params({ id: plan.id }));
  expect(confirmed.status).toBe(200);
  const { job } = await confirmed.json();
  expect(job.status).toBe("running");
  await runAudiobookJob(env.handle.db, jobs.at(-1)!, { ai: env.ai, store: env.store });
  const [row] = await env.handle.db.select().from(podcastEpisodes).where(eq(podcastEpisodes.key, plan.id));
  return { job, podcast: row.document };
}

describe("audiobook plans", () => {
  it("offers the screenshot's voices, and themes that are illustration styles", async () => {
    env.ai.images = true;
    const options = await (await optionsRoute.GET(apiRequest("GET", "/api/v1/audiobooks/options", { token: env.tokens.alice }))).json();
    expect(options.voices.map((voice: { name: string }) => voice.name)).toEqual(["Bella", "Roger", "Sarah", "Laura", "Charlie"]);
    expect(options.themes.map((theme: { id: string }) => theme.id)).toContain("graphic-novel");
    expect(options.video).toBe(true);
  });

  it("drafts without media or a job, and lists the draft", async () => {
    const speak = vi.spyOn(env.ai, "speak");
    const plan = await draft();
    expect(plan.plan.chapters.length).toBeGreaterThan(1);
    expect(plan.estimate.seconds).toBeGreaterThan(0);
    expect(plan.estimate.points).toBeGreaterThan(0);
    expect(speak).not.toHaveBeenCalled();
    expect(jobs).toHaveLength(0);
    expect(await env.handle.db.select().from(podcastEpisodes)).toHaveLength(0);
    const list = await (await planList.GET(apiRequest("GET", "/api/v1/audiobooks/plans", { token: env.tokens.alice }))).json();
    expect(list.plans.map((item: { id: string }) => item.id)).toEqual([plan.id]);
    expect(list.jobs).toEqual([]);
  });

  it("starts at once without plan mode", async () => {
    const response = await create.POST(apiRequest("POST", "/api/v1/audiobooks", { token: env.tokens.alice, body: body([await chip()], { planMode: false }) }));
    const result = await response.json();
    expect(result.job.status).toBe("running");
    expect(jobs).toHaveLength(1);
  });

  it("casts automatically, and honours chosen speakers", async () => {
    const auto = await draft();
    expect(auto.plan.speakers.length).toBe(2);
    const fixed = await draft({ speakers: [{ name: "Ada", voice: "elevenlabs:EXAVITQu4vr4xnSDxMaL" }] });
    expect(fixed.plan.speakers).toMatchObject([{ name: "Ada", voice: "elevenlabs:EXAVITQu4vr4xnSDxMaL" }]);
  });

  it("rejects unknown or duplicate voices before spending anything", async () => {
    const id = await chip();
    const call = (speakers: object[]) => create.POST(apiRequest("POST", "/api/v1/audiobooks", { token: env.tokens.alice, body: body([id], { speakers }) }));
    expect((await call([{ name: "A", voice: "elevenlabs:nope" }])).status).toBe(422);
    expect((await call([{ name: "A", voice: "elevenlabs:EXAVITQu4vr4xnSDxMaL" }, { name: "B", voice: "elevenlabs:EXAVITQu4vr4xnSDxMaL" }])).status).toBe(422);
  });

  it("lets edits and chat change the plan, fencing stale revisions", async () => {
    const plan = await draft();
    const edited = { ...plan.plan, speakers: [{ ...plan.plan.speakers[0], voice: "elevenlabs:FGY2WhTYpPnrIDTdsKH5", name: "Laura" }, plan.plan.speakers[1]], videoTheme: "noir" };
    const patched = await planRoute.PATCH(planRequest("PATCH", plan.id, { revision: 0, plan: edited }), params({ id: plan.id }));
    expect(patched.status).toBe(200);
    const saved = (await patched.json()).plan;
    expect(saved.revision).toBe(1);
    expect(saved.plan.speakers[0].name).toBe("Laura");
    expect(saved.plan.videoTheme).toBe("noir");
    expect((await planRoute.PATCH(planRequest("PATCH", plan.id, { revision: 0, plan: edited }), params({ id: plan.id }))).status).toBe(409);
    const chatted = await messagesRoute.POST(planRequest("POST", plan.id, { revision: 1, message: "Rename the first chapter" }, env.tokens.alice, "/messages"), params({ id: plan.id }));
    const revised = (await chatted.json()).plan;
    expect(revised.plan.chapters[0].title).toContain("(revised)");
    expect(revised.messages.map((message: { role: string }) => message.role)).toEqual(["user", "assistant"]);
  });

  it("keeps a voice from being used twice through an edit", async () => {
    const plan = await draft();
    const edited = { ...plan.plan, speakers: plan.plan.speakers.map((speaker: object) => ({ ...speaker, voice: plan.plan.speakers[0].voice })) };
    expect((await planRoute.PATCH(planRequest("PATCH", plan.id, { revision: 0, plan: edited }), params({ id: plan.id }))).status).toBe(422);
  });

  it("hides other people's plans", async () => {
    const plan = await draft();
    expect((await planRoute.GET(planRequest("GET", plan.id, undefined, env.tokens.bob), params({ id: plan.id }))).status).toBe(404);
    expect((await planRoute.POST(planRequest("POST", plan.id, { revision: 0 }, env.tokens.bob), params({ id: plan.id }))).status).toBe(404);
  });

  it("draws scenes only for review, keeps unchanged ones and redraws under a new theme", async () => {
    env.ai.images = true;
    const plan = await draft();
    const drawn = (await (await framesRoute.POST(planRequest("POST", plan.id, { revision: 0 }, env.tokens.alice, "/frames"), params({ id: plan.id }))).json()).plan;
    expect(drawn.frames.flat().every(Boolean)).toBe(true);
    const count = env.ai.calls.drawAudiobookScene.length;
    const same = (await (await planRoute.PATCH(planRequest("PATCH", plan.id, { revision: 0, plan: { ...drawn.plan, title: "Renamed" } }), params({ id: plan.id }))).json()).plan;
    expect(same.frames.flat().every(Boolean)).toBe(true);
    const themed = (await (await planRoute.PATCH(planRequest("PATCH", plan.id, { revision: 1, plan: { ...same.plan, videoTheme: "anime" } }), params({ id: plan.id }))).json()).plan;
    expect(themed.frames.flat().some(Boolean)).toBe(false);
    expect(env.ai.calls.drawAudiobookScene.length).toBe(count);
  });
});

describe("audiobook generation", () => {
  it("reads the raw text, not the summary, and makes one recording with chapters", async () => {
    const plan = await draft({ includeVideo: false });
    const { podcast } = await generate(plan);
    expect(env.ai.calls.writeAudiobookChapter[0].passages.join(" ")).toContain("The keeper climbed the stairs");
    expect(podcast.format).toBe("audiobook");
    // Older apps decode `type` strictly, so it must stay a value they know.
    expect(podcast.type).toBe("regular");
    expect(podcast.chapters!.length).toBe(plan.plan.chapters.length);
    expect(podcast.chapters![0].startSegment).toBe(0);
    expect(podcast.chapters!.at(-1)!.endSegment).toBe(podcast.segments.length);
    expect(podcast.durationSeconds).toBeGreaterThan(0);
    podcast.segments.forEach((segment, index) => { if (index) expect(segment.startSeconds!).toBeGreaterThanOrEqual(podcast.segments[index - 1].endSeconds! - 0.01); });
    const [row] = await env.handle.db.select().from(summaries).where(eq(summaries.id, podcast.summaryId!));
    expect(row.kind).toBe("podcast");
    expect(row.theme.emoji).toBe("📖");
    const job = (await (await jobRoute.GET(apiRequest("GET", `/api/v1/audiobooks/jobs/${jobs[0].id}`, { token: env.tokens.alice }), params({ id: jobs[0].id }))).json()).job;
    expect(job).toMatchObject({ status: "ready", percent: 100, stage: "complete" });
  });

  it("scores with several cues, changing where the content does, and reuses stored clips", async () => {
    env.ai.music = true;
    const plan = await draft({ includeVideo: false });
    const { podcast } = await generate(plan);
    expect(podcast.music).toBe(true);
    expect(new Set(podcast.segments.map(segment => segment.music)).size).toBeGreaterThan(1);
    expect(env.ai.calls.composeMusic).toHaveLength(plan.plan.musicCues.length);
    expect(env.ai.calls.composeMusic[0]).toContain("INSTRUMENTAL ONLY");
    const again = await draft({ includeVideo: false });
    await generate(again);
    expect(env.ai.calls.composeMusic).toHaveLength(plan.plan.musicCues.length);
  });

  it("publishes without music when composing fails", async () => {
    env.ai.music = true;
    vi.spyOn(env.ai, "composeMusic").mockRejectedValue(new Error("Lyria down"));
    const { podcast } = await generate(await draft({ includeVideo: false }));
    expect(podcast.durationSeconds).toBeGreaterThan(0);
  });

  it("resumes after a crash without voicing finished turns again, and charges nothing twice", async () => {
    const plan = await draft({ includeVideo: false });
    await planRoute.POST(planRequest("POST", plan.id, { revision: 0 }), params({ id: plan.id }));
    const speak = vi.spyOn(env.ai, "speak");
    const failing = vi.spyOn(env.ai, "transcribePodcast").mockRejectedValueOnce(Object.assign(new Error("gateway down"), {}));
    await runAudiobookJob(env.handle.db, jobs[0], { ai: env.ai, store: env.store });
    failing.mockRestore();
    expect((await env.handle.db.select().from(podcastEpisodes))).toHaveLength(1);
    const spoken = speak.mock.calls.length;
    await runAudiobookJob(env.handle.db, jobs[0], { ai: env.ai, store: env.store }).catch(() => undefined);
    expect(speak.mock.calls.length).toBe(spoken);
    expect(await env.handle.db.select().from(podcastEpisodes)).toHaveLength(1);
  });

  it("reports a failure and lets Retry continue from saved chapters", async () => {
    const plan = await draft({ includeVideo: false });
    await planRoute.POST(planRequest("POST", plan.id, { revision: 0 }), params({ id: plan.id }));
    const speak = vi.spyOn(env.ai, "speak").mockRejectedValueOnce(new Error("provider down"));
    await expect(runAudiobookJob(env.handle.db, jobs[0], { ai: env.ai, store: env.store })).rejects.toThrow();
    const failed = (await (await jobRoute.GET(apiRequest("GET", `/api/v1/audiobooks/jobs/${jobs[0].id}`, { token: env.tokens.alice }), params({ id: jobs[0].id }))).json()).job;
    expect(failed.status).toBe("failed");
    const failedTurns = speak.mock.calls.length;
    speak.mockClear();
    const retried = await planRoute.POST(planRequest("POST", plan.id, { revision: 0 }), params({ id: plan.id }));
    expect((await retried.json()).job.status).toBe("running");
    await runAudiobookJob(env.handle.db, jobs.at(-1)!, { ai: env.ai, store: env.store });
    const [row] = await env.handle.db.select().from(podcastEpisodes);
    // Turns voiced before the failure were kept, so the retry speaks fewer than the whole book.
    expect(failedTurns).toBeGreaterThan(1);
    expect(speak.mock.calls.length).toBeLessThanOrEqual(row.document.segments.length);
    expect(row.document.durationSeconds).toBeGreaterThan(0);
  });

  it("can make a video later for a book first made as audio only", async () => {
    env.ai.images = true;
    const { podcast } = await generate(await draft({ includeVideo: false }));
    expect(videos).toHaveLength(0);
    expect(podcast.audiobook!.scenes.length).toBeGreaterThan(0);
    const { createPodcastVideo } = await import("@/lib/services/podcast-video");
    const started = await createPodcastVideo(env.handle.db, "user-alice", day, podcast.key, { ai: env.ai, store: env.store }, undefined, undefined, "watercolor");
    expect(started.videoDesign).toBeTruthy();
    expect(started.audiobook!.videoTheme).toBe("watercolor");
    await runAudiobookVideoJob(env.handle.db, videos[0], { ai: env.ai, store: env.store });
    expect(env.ai.calls.drawAudiobookScene.length).toBeGreaterThan(0);
  });

  it("refuses audiobook themes on ordinary podcasts' video", async () => {
    const { createPodcastVideo } = await import("@/lib/services/podcast-video");
    const { createDailyPodcast } = await import("@/lib/services/daily-podcast");
    env.ai.video = true;
    const podcast = await createDailyPodcast(env.handle.db, "user-alice", { day, language: "en", regenerate: true, library: true, chipIds: [await chip()], includeVideo: false }, { ai: env.ai, store: env.store });
    await expect(createPodcastVideo(env.handle.db, "user-alice", day, podcast.key, { ai: env.ai, store: env.store }, undefined, undefined, "noir")).rejects.toMatchObject({ status: 422 });
  });

  it("adds a version to an existing audiobook chip", async () => {
    const first = await generate(await draft({ includeVideo: false }));
    const second = await generate(await draft({ includeVideo: false, summaryId: first.podcast.summaryId }));
    expect(second.podcast.summaryId).toBe(first.podcast.summaryId);
    const rows = await env.handle.db.select().from(podcastEpisodes).where(eq(podcastEpisodes.summaryId, first.podcast.summaryId!));
    expect(rows.filter(row => row.isDefault).map(row => row.key)).toEqual([second.podcast.key]);
  });

  it("gives the recording's direct link only to its owner, and redirects its audio there", async () => {
    const { podcast } = await generate(await draft({ includeVideo: false }));
    const query = `start=${encodeURIComponent(day.start)}&end=${encodeURIComponent(day.end)}`;
    const link = await linkRoute.GET(apiRequest("GET", `/api/v1/daily-podcasts/${podcast.key}/audio/link?${query}`, { token: env.tokens.alice }), params({ key: podcast.key }));
    expect(link.status).toBe(200);
    expect((await link.json()).byteSize).toBeGreaterThan(0);
    expect((await linkRoute.GET(apiRequest("GET", `/api/v1/daily-podcasts/${podcast.key}/audio/link?${query}`, { token: env.tokens.bob }), params({ key: podcast.key }))).status).toBe(404);
    const audio = await audioRoute.GET(apiRequest("GET", `/api/v1/daily-podcasts/${podcast.key}/audio?${query}`, { token: env.tokens.alice }), params({ key: podcast.key }));
    expect(audio.status).toBe(307);
  });
});

describe("audiobook translations and video", () => {
  const translate = async (key: string, language = "ja") => {
    const response = await translations.POST(apiRequest("POST", `/api/v1/audiobooks/${key}/translations`, { token: env.tokens.alice, body: { day, language } }), params({ key }));
    expect(response.status).toBe(200);
    return (await response.json()).job;
  };

  it("speaks another language with the same speakers and music, chapter for chapter", async () => {
    env.ai.music = true;
    const { podcast } = await generate(await draft({ includeVideo: false }));
    const composed = env.ai.calls.composeMusic.length;
    const job = await translate(podcast.key);
    expect(job.kind).toBe("translate");
    await runAudiobookJob(env.handle.db, jobs.at(-1)!, { ai: env.ai, store: env.store });
    const [row] = await env.handle.db.select().from(podcastEpisodes).where(eq(podcastEpisodes.key, podcast.key));
    const translated = podcastInLanguage(row.document, "ja");
    expect(translated.language).toBe("ja");
    expect(translated.languages).toEqual(["en", "ja"]);
    expect(translated.speakers).toEqual(podcast.speakers);
    expect(translated.chapters).toHaveLength(podcast.chapters!.length);
    expect(translated.segments.map(segment => segment.music)).toEqual(podcast.segments.map(segment => segment.music));
    expect(env.ai.calls.composeMusic.length).toBe(composed);
    expect(translated.audioPath).toContain("language=ja");
    // The original is untouched.
    expect(podcastInLanguage(row.document).language).toBe("en");
  });

  it("shares a running translation rather than paying twice, and refuses the book's own language", async () => {
    const { podcast } = await generate(await draft({ includeVideo: false }));
    const first = await translate(podcast.key);
    expect((await translate(podcast.key)).id).toBe(first.id);
    const same = await translations.POST(apiRequest("POST", `/api/v1/audiobooks/${podcast.key}/translations`, { token: env.tokens.alice, body: { day, language: "en" } }), params({ key: podcast.key }));
    expect(same.status).toBe(422);
  });

  it("illustrates approved scenes first, reuses them and queues a render", async () => {
    env.ai.images = true;
    const plan = await draft();
    const drawnPlan = (await (await framesRoute.POST(planRequest("POST", plan.id, { revision: 0 }, env.tokens.alice, "/frames"), params({ id: plan.id }))).json()).plan;
    const reviewed = env.ai.calls.drawAudiobookScene.length;
    const { podcast } = await generate(drawnPlan);
    expect(videos).toHaveLength(1);
    const started = (await env.handle.db.select().from(podcastEpisodes).where(eq(podcastEpisodes.key, podcast.key)))[0].document;
    expect(started.videoDesign).toBeTruthy();
    await runAudiobookVideoJob(env.handle.db, videos[0], { ai: env.ai, store: env.store });
    expect(env.ai.calls.drawAudiobookScene.length).toBe(reviewed);
    const finished = (await env.handle.db.select().from(podcastEpisodes).where(eq(podcastEpisodes.key, podcast.key)))[0].document;
    expect(finished.videoDesign).toBeUndefined();
    expect(finished.video?.id).toBe(videos[0].id);
    const source = await podcastVideoSource(env.handle.db, "user-alice", day, podcast.key, env.store);
    expect(source.files).toEqual({});
    expect(source.imageSequence!.scenes.length).toBeGreaterThan(0);
    expect(source.imageSequence!.scenes[0].segment).toBe(0);
    expect(env.podcastRenders.map(job => job.videoId)).toContain(videos[0].id);
  });

  it("gives a translation the same scenes without drawing or label work", async () => {
    env.ai.images = true;
    const { podcast } = await generate(await draft());
    await runAudiobookVideoJob(env.handle.db, videos[0], { ai: env.ai, store: env.store });
    const drawn = env.ai.calls.drawAudiobookScene.length;
    await translate(podcast.key);
    await runAudiobookJob(env.handle.db, jobs.at(-1)!, { ai: env.ai, store: env.store });
    const [row] = await env.handle.db.select().from(podcastEpisodes).where(eq(podcastEpisodes.key, podcast.key));
    expect(row.document.translations!.ja.video?.sourceId).toBe(videos[0].id);
    expect(env.ai.calls.drawAudiobookScene.length).toBe(drawn);
    expect(env.ai.calls.translatePodcastVideo).toHaveLength(0);
  });
});

describe("voice samples", () => {
  it("draws a sample once per voice and language, then serves it from storage for free", async () => {
    const speak = vi.spyOn(env.ai, "speak");
    const voice = "elevenlabs:EXAVITQu4vr4xnSDxMaL";
    const url = `/api/v1/audiobooks/voices/sample?voice=${encodeURIComponent(voice)}&language=ja`;
    const first = await sampleRoute.GET(apiRequest("GET", url, { token: env.tokens.alice }));
    expect(first.status).toBe(200);
    expect((await first.json()).url).toBeTruthy();
    await sampleRoute.GET(apiRequest("GET", url, { token: env.tokens.bob }));
    expect(speak).toHaveBeenCalledTimes(1);
    expect(await env.store.head(voiceSampleKey(voice, "ja"))).toBeTruthy();
  });

  it("refuses voices outside the catalog, so nothing else can be drawn", async () => {
    const response = await sampleRoute.GET(apiRequest("GET", "/api/v1/audiobooks/voices/sample?voice=elevenlabs%3Aanything", { token: env.tokens.alice }));
    expect(response.status).toBe(404);
  });
});
