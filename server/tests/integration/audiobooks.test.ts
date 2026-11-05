import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { eq } from "drizzle-orm";
import * as uploadsRoute from "@/app/api/v1/uploads/route";
import * as create from "@/app/api/v1/audiobooks/route";
import * as optionsRoute from "@/app/api/v1/audiobooks/options/route";
import * as sampleRoute from "@/app/api/v1/audiobooks/voices/sample/route";
import * as planList from "@/app/api/v1/audiobooks/plans/route";
import * as planRoute from "@/app/api/v1/audiobooks/plans/[id]/route";
import * as messagesRoute from "@/app/api/v1/audiobooks/plans/[id]/messages/route";
import * as framesRoute from "@/app/api/v1/audiobooks/plans/[id]/frames/route";
import * as jobRoute from "@/app/api/v1/audiobooks/jobs/[id]/route";
import * as translations from "@/app/api/v1/audiobooks/[key]/translations/route";
import * as chaptersRoute from "@/app/api/v1/audiobooks/[key]/chapters/route";
import * as linkRoute from "@/app/api/v1/daily-podcasts/[key]/audio/link/route";
import * as audioRoute from "@/app/api/v1/daily-podcasts/[key]/audio/route";
import * as episodeRoute from "@/app/api/v1/daily-podcasts/[key]/route";
import * as summariesRoute from "@/app/api/v1/summaries/route";
import * as summaryRoute from "@/app/api/v1/summaries/[id]/route";
import { audiobookPlans, podcastEpisodes, summaries } from "@/lib/db/schema";
import { setAudiobookStarterForTests } from "@/lib/services/audiobook-starter";
import { mergeLegacyAudiobooks } from "@/lib/services/audiobook-book";
import { dayKey } from "@/lib/services/daily-podcast";
import { runAudiobookJob, type AudiobookJobInput } from "@/lib/services/audiobooks";
import { runAudiobookVideoJob, type AudiobookVideoJob } from "@/lib/services/audiobook-video";
import { voiceSampleKey } from "@/lib/services/audiobook-voices";
import { podcastInLanguage } from "@/lib/services/daily-podcast";
import { podcastVideoSource } from "@/lib/services/podcast-video";
import { buildPdf, apiRequest, params, setupTestEnv, type TestEnv } from "../helpers/setup";

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

/** The saved episode behind one of a book's chapters. */
async function chapterEpisode(book: { chapters?: { versionId?: string }[] }, index = 0) {
  const [row] = await env.handle.db.select().from(podcastEpisodes).where(eq(podcastEpisodes.key, book.chapters![index].versionId!));
  return row.document;
}
/** Rows the library lists, which excludes the recordings behind each chapter. */
const listedBooks = async () => (await env.handle.db.select().from(podcastEpisodes)).filter(row => !row.document.bookKey);

describe("audiobook plans", () => {
  it("generates from a direct PDF without creating a source chip", async () => {
    const bytes = buildPdf();
    const upload = await (await uploadsRoute.POST(apiRequest("POST", "/api/v1/uploads", {
      token: env.tokens.alice, body: { filename: "Book.pdf", mimeType: "application/pdf", byteSize: bytes.length },
    }))).json();
    await env.store.put(upload.key, { bytes, contentType: "application/pdf" });
    const payload = body([], { includeVideo: false, pdfSources: [{ uploadKey: upload.key, filename: "Book.pdf", ocrText: text }] });
    const foreign = await create.POST(apiRequest("POST", "/api/v1/audiobooks", { token: env.tokens.bob, body: payload }));
    expect(foreign.status).toBe(403);
    const response = await create.POST(apiRequest("POST", "/api/v1/audiobooks", { token: env.tokens.alice, body: payload }));
    expect(response.status).toBe(200);
    expect(await env.handle.db.select().from(summaries)).toHaveLength(0);
    const { podcast } = await generate((await response.json()).plan);
    const rows = await env.handle.db.select().from(summaries);
    expect(rows).toHaveLength(1);
    expect(rows[0].kind).toBe("audiobook");
    expect(podcast.chipIds).toEqual([]);
    expect(podcast.segments.length).toBeGreaterThan(0);
  });

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
    expect(row.kind).toBe("audiobook");
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
    expect(await listedBooks()).toHaveLength(1);
    const spoken = speak.mock.calls.length;
    await runAudiobookJob(env.handle.db, jobs[0], { ai: env.ai, store: env.store }).catch(() => undefined);
    expect(speak.mock.calls.length).toBe(spoken);
    expect(await listedBooks()).toHaveLength(1);
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
    const [row] = await listedBooks();
    // Turns voiced before the failure were kept, so the retry speaks fewer than the whole book.
    expect(failedTurns).toBeGreaterThan(1);
    expect(speak.mock.calls.length).toBeLessThanOrEqual(row.document.segments.length);
    expect(row.document.durationSeconds).toBeGreaterThan(0);
  });

  it("can make a video later for a book first made as audio only", async () => {
    env.ai.images = true;
    const { podcast: book } = await generate(await draft({ includeVideo: false }));
    expect(videos).toHaveLength(0);
    const podcast = await chapterEpisode(book);
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

  it("keeps a book made from selected chapters readable, playable and illustrated", async () => {
    env.ai.images = true;
    const plan = await draft();
    const confirmed = await planRoute.POST(planRequest("POST", plan.id, { revision: plan.revision, chapters: [0] }), params({ id: plan.id }));
    expect(confirmed.status).toBe(200);
    const { job } = await confirmed.json();
    await runAudiobookJob(env.handle.db, jobs.at(-1)!, { ai: env.ai, store: env.store });
    expect(job.episodeKey).toBe(plan.id);
    const query = `start=${encodeURIComponent(day.start)}&end=${encodeURIComponent(day.end)}`;
    const opened = await episodeRoute.GET(apiRequest("GET", `/api/v1/daily-podcasts/${plan.id}?${query}`, { token: env.tokens.alice }), params({ key: plan.id }));
    expect(opened.status).toBe(200);
    const saved = (await opened.json()).podcast;
    expect(saved.chapters).toHaveLength(1);
    expect(saved.title).toBe(plan.plan.title);
    const key = saved.chapters[0].versionId as string;
    expect((await episodeRoute.GET(apiRequest("GET", `/api/v1/daily-podcasts/${key}?${query}`, { token: env.tokens.alice }), params({ key }))).status).toBe(200);
    expect((await linkRoute.GET(apiRequest("GET", `/api/v1/daily-podcasts/${key}/audio/link?${query}`, { token: env.tokens.alice }), params({ key }))).status).toBe(200);
    expect((await episodeRoute.GET(apiRequest("GET", `/api/v1/daily-podcasts/${key}?${query}`, { token: env.tokens.bob }), params({ key }))).status).toBe(404);
    expect(videos).toHaveLength(1);
    await runAudiobookVideoJob(env.handle.db, videos[0], { ai: env.ai, store: env.store });
    const [row] = await env.handle.db.select().from(podcastEpisodes).where(eq(podcastEpisodes.key, key));
    expect(row.document.video?.id).toBe(videos[0].id);
  });

  it("gives the recording's direct link only to its owner, and redirects its audio there", async () => {
    const podcast = await chapterEpisode((await generate(await draft({ includeVideo: false }))).podcast);
    const query = `start=${encodeURIComponent(day.start)}&end=${encodeURIComponent(day.end)}`;
    const link = await linkRoute.GET(apiRequest("GET", `/api/v1/daily-podcasts/${podcast.key}/audio/link?${query}`, { token: env.tokens.alice }), params({ key: podcast.key }));
    expect(link.status).toBe(200);
    expect((await link.json()).byteSize).toBeGreaterThan(0);
    expect((await linkRoute.GET(apiRequest("GET", `/api/v1/daily-podcasts/${podcast.key}/audio/link?${query}`, { token: env.tokens.bob }), params({ key: podcast.key }))).status).toBe(404);
    const audio = await audioRoute.GET(apiRequest("GET", `/api/v1/daily-podcasts/${podcast.key}/audio?${query}`, { token: env.tokens.alice }), params({ key: podcast.key }));
    expect(audio.status).toBe(307);
  });
});

describe("generating a plan's chapters more than once", () => {
  async function generateChapters(plan: { id: string; revision: number }, chapters: number[]) {
    const response = await planRoute.POST(planRequest("POST", plan.id, { revision: plan.revision, chapters }), params({ id: plan.id }));
    expect(response.status).toBe(200);
    await runAudiobookJob(env.handle.db, jobs.at(-1)!, { ai: env.ai, store: env.store });
    return (await response.json()).job;
  }
  const book = async (key: string) => (await env.handle.db.select().from(podcastEpisodes).where(eq(podcastEpisodes.key, key)))[0].document;

  it("joins different chapters into one chip, in the plan's order, each with its own recording", async () => {
    const plan = await draft({ includeVideo: false });
    await generateChapters(plan, [1]);
    const first = await book(plan.id);
    const firstChapter = await chapterEpisode(first);
    const job = await generateChapters(plan, [0]);
    expect(job.episodeKey).toBe(plan.id);
    expect(await env.handle.db.select().from(summaries).where(eq(summaries.kind, "audiobook"))).toHaveLength(1);
    expect(await listedBooks()).toHaveLength(1);
    const merged = await book(plan.id);
    expect(merged.summaryId).toBe(first.summaryId);
    expect(merged.chapters!.map(chapter => chapter.title)).toEqual([plan.plan.chapters[0].title, plan.plan.chapters[1].title]);
    expect(merged.chapters![1].startSegment).toBe(merged.chapters![0].endSegment);
    expect(merged.durationSeconds).toBeGreaterThan(first.durationSeconds!);
    // No joined file: the book has nothing to play itself, and the earlier chapter's recording wasn't touched.
    expect(merged.audioPath).toBeUndefined();
    const base = dayKey("user-alice", day);
    expect(await env.store.head(`${base}/${plan.id}/audio.mp3`)).toBeNull();
    const [one, two] = [await chapterEpisode(merged, 0), await chapterEpisode(merged, 1)];
    expect(two).toEqual({ ...firstChapter, summaryId: merged.summaryId });
    expect(await env.store.head(`${base}/${one.key}/audio.mp3`)).toBeTruthy();
    expect(await env.store.head(`${base}/${two.key}/audio.mp3`)).toBeTruthy();
    expect(one.bookKey).toBe(plan.id);
    expect(one.chapters).toHaveLength(1);
    expect(one.chapters![0].startSeconds).toBe(0);
    const query = `start=${encodeURIComponent(day.start)}&end=${encodeURIComponent(day.end)}`;
    expect((await audioRoute.GET(apiRequest("GET", `/api/v1/daily-podcasts/${two.key}/audio?${query}`, { token: env.tokens.alice }), params({ key: two.key }))).status).toBe(307);
  });

  it("publishes each chapter as it finishes, so a later failure keeps what was made", async () => {
    const plan = await draft({ includeVideo: false });
    await planRoute.POST(planRequest("POST", plan.id, { revision: plan.revision, chapters: [0, 1] }), params({ id: plan.id }));
    const writes = env.ai.writeAudiobookChapter.bind(env.ai);
    let calls = 0;
    vi.spyOn(env.ai, "writeAudiobookChapter").mockImplementation((input, options) => {
      if (++calls === 2) throw new Error("provider down");
      return writes(input, options);
    });
    await expect(runAudiobookJob(env.handle.db, jobs[0], { ai: env.ai, store: env.store })).rejects.toThrow();
    const saved = await book(plan.id);
    expect(saved.chapters).toHaveLength(1);
    expect((await chapterEpisode(saved)).durationSeconds).toBeGreaterThan(0);
    vi.restoreAllMocks();
    await runAudiobookJob(env.handle.db, jobs[0], { ai: env.ai, store: env.store });
    const finished = await book(plan.id);
    expect(finished.chapters).toHaveLength(2);
    expect(finished.chapters!.every(chapter => chapter.versions!.length === 1)).toBe(true);
  });

  it("adds a version when a chapter is generated again, and lets an earlier one be chosen instantly and for free", async () => {
    const plan = await draft({ includeVideo: false });
    await generateChapters(plan, [0, 1]);
    const original = await book(plan.id);
    const originalVersion = original.chapters![0].versionId!;
    const untouched = await chapterEpisode(original, 1);
    const speak = vi.spyOn(env.ai, "speak");
    await generateChapters(plan, [0]);
    const spoken = speak.mock.calls.length;
    expect(spoken).toBeGreaterThan(0);
    const versioned = await book(plan.id);
    expect(versioned.chapters).toHaveLength(2);
    expect(versioned.chapters![0].versions!.map(version => version.id)).toContain(originalVersion);
    expect(versioned.chapters![0].versions).toHaveLength(2);
    expect(versioned.chapters![0].versionId).not.toBe(originalVersion);
    expect(versioned.chapters![1].versions).toHaveLength(1);
    expect(await chapterEpisode(versioned, 1)).toEqual(untouched);

    const select = (version: string, token = env.tokens.alice) => chaptersRoute.PATCH(apiRequest("PATCH", `/api/v1/audiobooks/${plan.id}/chapters`, { token, body: { day, chapter: versioned.chapters![0].bookChapterId, version } }), params({ key: plan.id }));
    expect((await select(originalVersion, env.tokens.bob)).status).toBe(404);
    expect((await select("nope")).status).toBe(404);
    const chosen = await select(originalVersion);
    expect(chosen.status).toBe(200);
    const selected = (await chosen.json()).podcast;
    expect(selected.chapters[0].versionId).toBe(originalVersion);
    expect(selected.chapters[0].versions).toHaveLength(2);
    expect(selected.segments.map((segment: { caption: string }) => segment.caption)).toEqual(original.segments.map(segment => segment.caption));
    expect(speak.mock.calls.length).toBe(spoken);
  });

  it("starts a new book when the chip was deleted, and doesn't bring the old chapters back", async () => {
    const plan = await draft({ includeVideo: false });
    await generateChapters(plan, [0, 1]);
    const first = await book(plan.id);
    const removed = await summaryRoute.DELETE(apiRequest("DELETE", `/api/v1/summaries/${first.summaryId}`, { token: env.tokens.alice }), params({ id: first.summaryId! }));
    expect(removed.status).toBeLessThan(300);
    expect(await env.handle.db.select().from(podcastEpisodes)).toHaveLength(0);
    await generateChapters(plan, [1]);
    const query = `start=${encodeURIComponent(day.start)}&end=${encodeURIComponent(day.end)}`;
    const opened = await episodeRoute.GET(apiRequest("GET", `/api/v1/daily-podcasts/${plan.id}?${query}`, { token: env.tokens.alice }), params({ key: plan.id }));
    expect(opened.status).toBe(200);
    expect((await opened.json()).podcast.chapters.map((chapter: { title: string }) => chapter.title)).toEqual([plan.plan.chapters[1].title]);
    expect(await env.handle.db.select().from(summaries).where(eq(summaries.kind, "audiobook"))).toHaveLength(1);
  });

  it("recovers a book left behind by a chip deleted before recordings went with it", async () => {
    const plan = await draft({ includeVideo: false });
    await generateChapters(plan, [0, 1]);
    const first = await book(plan.id);
    await env.handle.db.delete(summaries).where(eq(summaries.id, first.summaryId!));
    await generateChapters(plan, [0]);
    const query = `start=${encodeURIComponent(day.start)}&end=${encodeURIComponent(day.end)}`;
    const opened = await episodeRoute.GET(apiRequest("GET", `/api/v1/daily-podcasts/${plan.id}?${query}`, { token: env.tokens.alice }), params({ key: plan.id }));
    expect(opened.status).toBe(200);
    const saved = (await opened.json()).podcast;
    expect(saved.chapters).toHaveLength(1);
    expect(saved.chapters[0].versions).toHaveLength(1);
  });

  it("joins a repeated tap to the running generation, but a later one makes a new version", async () => {
    const plan = await draft({ includeVideo: false });
    const send = () => planRoute.POST(planRequest("POST", plan.id, { revision: plan.revision, chapters: [0] }), params({ id: plan.id }));
    const first = (await (await send()).json()).job;
    expect((await (await send()).json()).job.id).toBe(first.id);
    expect(jobs).toHaveLength(1);
    await runAudiobookJob(env.handle.db, jobs[0], { ai: env.ai, store: env.store });
    expect((await (await send()).json()).job.id).not.toBe(first.id);
    expect(jobs).toHaveLength(2);
  });

  it("joins generations that finish together without losing either", async () => {
    const plan = await draft({ includeVideo: false });
    for (const chapters of [[0], [1]]) await planRoute.POST(planRequest("POST", plan.id, { revision: plan.revision, chapters }), params({ id: plan.id }));
    await Promise.all(jobs.map(job => runAudiobookJob(env.handle.db, job, { ai: env.ai, store: env.store })));
    expect((await book(plan.id)).chapters).toHaveLength(2);
    expect(await env.handle.db.select().from(summaries).where(eq(summaries.kind, "audiobook"))).toHaveLength(1);
  });

  it("keeps a chapter's translation and video when the book gains another chapter or a version", async () => {
    env.ai.images = true;
    const plan = await draft();
    await generateChapters(plan, [0]);
    const first = await chapterEpisode(await book(plan.id));
    await runAudiobookVideoJob(env.handle.db, videos.find(item => item.key === first.key)!, { ai: env.ai, store: env.store });
    const translate = await translations.POST(apiRequest("POST", `/api/v1/audiobooks/${first.key}/translations`, { token: env.tokens.alice, body: { day, language: "ja" } }), params({ key: first.key }));
    expect(translate.status).toBe(200);
    await runAudiobookJob(env.handle.db, jobs.at(-1)!, { ai: env.ai, store: env.store });
    const before = (await env.handle.db.select().from(podcastEpisodes).where(eq(podcastEpisodes.key, first.key)))[0].document;
    expect(before.video).toBeTruthy();
    expect(before.translations?.ja).toBeTruthy();
    const drawn = env.ai.calls.drawAudiobookScene.length;
    await generateChapters(plan, [1]);
    const after = (await env.handle.db.select().from(podcastEpisodes).where(eq(podcastEpisodes.key, first.key)))[0].document;
    expect(after).toEqual(before);
    expect(env.ai.calls.drawAudiobookScene.length).toBe(drawn);
    // The new chapter has a video of its own.
    const second = await chapterEpisode(await book(plan.id), 1);
    expect(videos.some(item => item.key === second.key)).toBe(true);
  });

  it("gives chapters separate translations: one can be spoken while another isn't", async () => {
    const plan = await draft({ includeVideo: false });
    await generateChapters(plan, [0, 1]);
    const merged = await book(plan.id);
    const key = merged.chapters![0].versionId!;
    expect((await translations.POST(apiRequest("POST", `/api/v1/audiobooks/${key}/translations`, { token: env.tokens.alice, body: { day, language: "ja" } }), params({ key }))).status).toBe(200);
    await runAudiobookJob(env.handle.db, jobs.at(-1)!, { ai: env.ai, store: env.store });
    expect((await chapterEpisode(merged, 0)).translations?.ja).toBeTruthy();
    expect((await chapterEpisode(merged, 1)).translations).toBeUndefined();
  });

  describe("recordings made before chapters had their own", () => {
    /**
     * Rewrites a generated chapter the way earlier versions stored a selection: its own chip, recording and plan row.
     * Installed by the returned call, since a generation folds in any such recording it finds.
     */
    async function legacy(plan: { id: string; revision: number }, chapter: number, suffix: string) {
      const [root] = await env.handle.db.select().from(audiobookPlans).where(eq(audiobookPlans.id, plan.id));
      await generateChapters(plan, [chapter]);
      const [bookRow] = await env.handle.db.select().from(podcastEpisodes).where(eq(podcastEpisodes.key, plan.id));
      const made = await chapterEpisode(bookRow.document);
      const key = suffix.repeat(64);
      const summaryId = `chip-${suffix}`;
      const document = { ...made, key, summaryId, bookKey: undefined, createdAt: `2030-04-01T00:00:0${suffix.charCodeAt(0) - 97}.000Z`, audioPath: `/api/v1/daily-podcasts/${key}/audio` };
      delete document.bookKey;
      const base = dayKey("user-alice", day);
      const audio = await env.store.get(`${base}/${made.key}/audio.mp3`);
      const [chip] = await env.handle.db.select().from(summaries).where(eq(summaries.id, bookRow.summaryId!));
      await env.handle.db.delete(summaries).where(eq(summaries.id, chip.id));
      return async () => {
        await env.store.put(`${base}/${key}/audio.mp3`, audio);
        await env.handle.db.insert(audiobookPlans).values({ ...root, id: key, confirmed: true, plan: { ...root.plan, chapters: [root.plan.chapters[chapter]] } });
        await env.handle.db.insert(summaries).values({ ...chip, id: summaryId, slug: `slug-${suffix}` });
        await env.handle.db.insert(podcastEpisodes).values({ key, ownerId: "user-alice", dayStart: bookRow.dayStart, dayEnd: bookRow.dayEnd, summaryId, isDefault: true, document });
        return document;
      };
    }

    it("cuts them into chapters on one chip, repeats becoming versions", async () => {
      const plan = await draft({ includeVideo: false });
      const installs = [await legacy(plan, 0, "a"), await legacy(plan, 1, "b"), await legacy(plan, 0, "c")];
      const [first] = await Promise.all(installs.map(install => install()));
      await mergeLegacyAudiobooks(env.handle.db, "user-alice", { ai: env.ai, store: env.store });
      expect((await listedBooks()).map(row => row.key)).toEqual([plan.id]);
      const chips = await env.handle.db.select().from(summaries).where(eq(summaries.kind, "audiobook"));
      expect(chips.map(item => item.id)).toEqual([first.summaryId]);
      const merged = await book(plan.id);
      expect(merged.chapters).toHaveLength(2);
      expect(merged.chapters![0].versions).toHaveLength(2);
      expect(merged.chapters![1].versions).toHaveLength(1);
      expect(merged.audioPath).toBeUndefined();
      const chapter = await chapterEpisode(merged);
      expect(chapter.durationSeconds).toBeGreaterThan(0);
      expect(chapter.segments[0].captionCues!.every(cue => cue.endSeconds <= chapter.durationSeconds!)).toBe(true);
      // Running again changes nothing.
      expect(await mergeLegacyAudiobooks(env.handle.db, "user-alice", { ai: env.ai, store: env.store })).toBe(false);
      expect((await book(plan.id)).audiobook!.revision).toBe(merged.audiobook!.revision);
    });

    it("tells the app when loading the library merged them, so it refreshes its feed", async () => {
      const plan = await draft({ includeVideo: false });
      const installs = [await legacy(plan, 0, "a"), await legacy(plan, 1, "b")];
      await Promise.all(installs.map(install => install()));
      vi.spyOn(await import("@/lib/storage/r2"), "getObjectStore").mockReturnValue(env.store);
      const load = async () => (await planList.GET(apiRequest("GET", "/api/v1/audiobooks/plans", { token: env.tokens.alice }))).json();
      expect((await load()).merged).toBe(true);
      expect(await env.handle.db.select().from(summaries).where(eq(summaries.kind, "audiobook"))).toHaveLength(1);
      expect((await load()).merged).toBe(false);
    });

    it("leaves a plan's single recording alone until more of it is generated, then folds it in", async () => {
      const plan = await draft({ includeVideo: false });
      await (await legacy(plan, 0, "a"))();
      await mergeLegacyAudiobooks(env.handle.db, "user-alice", { ai: env.ai, store: env.store });
      expect((await listedBooks()).map(row => row.key)).toEqual(["a".repeat(64)]);
      await generateChapters(plan, [1]);
      const rows = await listedBooks();
      expect(rows.map(row => row.key)).toEqual([plan.id]);
      expect(rows[0].document.chapters).toHaveLength(2);
      expect(rows[0].summaryId).toBe("chip-a");
    });
  });
});

describe("audiobook translations and video", () => {
  const translate = async (key: string, language = "ja") => {
    const response = await translations.POST(apiRequest("POST", `/api/v1/audiobooks/${key}/translations`, { token: env.tokens.alice, body: { day, language } }), params({ key }));
    expect(response.status).toBe(200);
    return (await response.json()).job;
  };

  it("speaks a chapter in another language with the same speakers and music", async () => {
    env.ai.music = true;
    const podcast = await chapterEpisode((await generate(await draft({ includeVideo: false }))).podcast);
    const composed = env.ai.calls.composeMusic.length;
    const job = await translate(podcast.key);
    expect(job.kind).toBe("translate");
    await runAudiobookJob(env.handle.db, jobs.at(-1)!, { ai: env.ai, store: env.store });
    const [row] = await env.handle.db.select().from(podcastEpisodes).where(eq(podcastEpisodes.key, podcast.key));
    const translated = podcastInLanguage(row.document, "ja");
    expect(translated.language).toBe("ja");
    expect(translated.languages).toEqual(["en", "ja"]);
    expect(translated.speakers).toEqual(podcast.speakers);
    expect(translated.chapters).toHaveLength(1);
    expect(translated.segments.map(segment => segment.music)).toEqual(podcast.segments.map(segment => segment.music));
    expect(env.ai.calls.composeMusic.length).toBe(composed);
    expect(translated.audioPath).toContain("language=ja");
    // The original is untouched.
    expect(podcastInLanguage(row.document).language).toBe("en");
  });

  it("shares a running translation rather than paying twice, and refuses the chapter's own language", async () => {
    const podcast = await chapterEpisode((await generate(await draft({ includeVideo: false }))).podcast);
    const first = await translate(podcast.key);
    expect((await translate(podcast.key)).id).toBe(first.id);
    const same = await translations.POST(apiRequest("POST", `/api/v1/audiobooks/${podcast.key}/translations`, { token: env.tokens.alice, body: { day, language: "en" } }), params({ key: podcast.key }));
    expect(same.status).toBe(422);
  });

  it("illustrates approved scenes first, reuses them and queues a render for each chapter", async () => {
    env.ai.images = true;
    const plan = await draft();
    const drawnPlan = (await (await framesRoute.POST(planRequest("POST", plan.id, { revision: 0 }, env.tokens.alice, "/frames"), params({ id: plan.id }))).json()).plan;
    const reviewed = env.ai.calls.drawAudiobookScene.length;
    const { podcast: book } = await generate(drawnPlan);
    expect(videos).toHaveLength(book.chapters!.length);
    const podcast = await chapterEpisode(book);
    expect(podcast.videoDesign).toBeTruthy();
    const video = videos.find(item => item.key === podcast.key)!;
    await runAudiobookVideoJob(env.handle.db, video, { ai: env.ai, store: env.store });
    expect(env.ai.calls.drawAudiobookScene.length).toBe(reviewed);
    const finished = await chapterEpisode(book);
    expect(finished.videoDesign).toBeUndefined();
    expect(finished.video?.id).toBe(video.id);
    const source = await podcastVideoSource(env.handle.db, "user-alice", day, podcast.key, env.store);
    expect(source.files).toEqual({});
    expect(source.imageSequence!.scenes.length).toBeGreaterThan(0);
    expect(source.imageSequence!.scenes[0].segment).toBe(0);
    expect(env.podcastRenders.map(job => job.videoId)).toContain(video.id);
  });

  it("gives a chapter's translation the same scenes without drawing or label work", async () => {
    env.ai.images = true;
    const podcast = await chapterEpisode((await generate(await draft())).podcast);
    await runAudiobookVideoJob(env.handle.db, videos.find(item => item.key === podcast.key)!, { ai: env.ai, store: env.store });
    const drawn = env.ai.calls.drawAudiobookScene.length;
    await translate(podcast.key);
    await runAudiobookJob(env.handle.db, jobs.at(-1)!, { ai: env.ai, store: env.store });
    const [row] = await env.handle.db.select().from(podcastEpisodes).where(eq(podcastEpisodes.key, podcast.key));
    expect(row.document.translations!.ja.video?.sourceId).toBe(row.document.video!.id);
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
