import { readFileSync } from "node:fs";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { eq } from "drizzle-orm";
import * as settingsRoute from "@/app/api/v1/daily-recap/route";
import * as cronRoute from "@/app/api/cron/daily-recaps/route";
import * as summariesRoute from "@/app/api/v1/summaries/route";
import { dailyRecapRuns, dailyRecapSchedules, podcastEpisodes, summaries, users } from "@/lib/db/schema";
import { dailyRecapSettings, dispatchDailyRecaps, nextRecapAt, recapDay, runDailyRecap, saveDailyRecapSettings, setDailyRecapStarterForTests, type DailyRecapJob } from "@/lib/services/daily-recap";
import { createDailyPodcast, dailyPodcastChips, storeContinuousAudio } from "@/lib/services/daily-podcast";
import { podcastDaySchema } from "@/lib/contracts/daily-podcast";
import { joinPodcastAudio } from "@/lib/services/podcast-audio";
import { apiRequest, setupTestEnv, type TestEnv } from "../helpers/setup";

let env: TestEnv;
let jobs: DailyRecapJob[];
const before = new Date("2030-04-02T05:00:00+08:00");
const due = new Date("2030-04-02T07:00:00+08:00");
const input = { enabled: true, timeZone: "Asia/Hong_Kong", language: "en" as const, hour: 7 };
beforeEach(async () => {
  env = await setupTestEnv();
  env.ai.video = true;
  jobs = [];
  setDailyRecapStarterForTests({ start: async job => { jobs.push(job); } });
  await settingsRoute.GET(apiRequest("GET", "/api/v1/daily-recap", { token: env.tokens.alice }));
});
afterEach(() => { setDailyRecapStarterForTests(); vi.restoreAllMocks(); vi.unstubAllEnvs(); env.teardown(); });
async function enable() { await saveDailyRecapSettings(env.handle.db, "user-alice", input, undefined, before); }
async function chip(title = "Battery results") {
  const response = await summariesRoute.POST(apiRequest("POST", "/api/v1/summaries", { token: env.tokens.alice, body: {
    source: { type: "text", text: `Researchers published new results: ${title}.`, title }, followLinks: false,
  } }));
  const body = await response.json();
  expect(response.status).toBe(201);
  await env.handle.db.update(summaries).set({ createdAt: new Date("2030-04-01T12:00:00+08:00") }).where(eq(summaries.id, body.id));
  return body;
}

it("authenticates settings, validates zones, and isolates accounts", async () => {
  expect((await settingsRoute.GET(apiRequest("GET", "/api/v1/daily-recap"))).status).toBe(401);
  expect((await settingsRoute.PUT(apiRequest("PUT", "/api/v1/daily-recap", { token: env.tokens.alice, body: { ...input, timeZone: "invalid" } }))).status).toBe(400);
  expect((await settingsRoute.PUT(apiRequest("PUT", "/api/v1/daily-recap", { token: env.tokens.alice, body: input }))).status).toBe(200);
  const bob = await settingsRoute.GET(apiRequest("GET", "/api/v1/daily-recap", { token: env.tokens.bob }));
  expect((await bob.json()).enabled).toBe(false);
});

it("uses local previous-day boundaries including DST and schedules only future runs", () => {
  expect(recapDay(due, input.timeZone)).toEqual({ date: "2030-04-01", day: { start: "2030-03-31T16:00:00.000Z", end: "2030-04-01T16:00:00.000Z" } });
  for (const [at, hours] of [["2030-03-11T12:00:00Z", 23], ["2030-11-04T12:00:00Z", 25]] as const) {
    const { day } = recapDay(new Date(at), "America/New_York");
    expect(podcastDaySchema.safeParse(day).success).toBe(true);
    expect((Date.parse(day.end) - Date.parse(day.start)) / 3_600_000).toBe(hours);
  }
  expect(nextRecapAt(due, input.timeZone, 7).toISOString()).toBe("2030-04-02T23:00:00.000Z");
});

it("dispatches once per local day, skips empty days, and does no work before the scheduled hour", async () => {
  await enable();
  expect((await dispatchDailyRecaps(env.handle.db, before)).started).toBe(0);
  expect((await dispatchDailyRecaps(env.handle.db, due)).started).toBe(1);
  expect((await dispatchDailyRecaps(env.handle.db, due)).started).toBe(0);
  const writer = vi.spyOn(env.ai, "writePodcast");
  await runDailyRecap(env.handle.db, jobs[0]);
  expect(writer).not.toHaveBeenCalled();
  expect((await dailyRecapSettings(env.handle.db, "user-alice")).lastRun?.status).toBe("skipped");
});

it("creates a short episode and queues its cloud video once even when the workflow step repeats", async () => {
  await enable(); await chip();
  await dispatchDailyRecaps(env.handle.db, due);
  const writer = vi.spyOn(env.ai, "writePodcast");
  await runDailyRecap(env.handle.db, jobs[0]);
  await runDailyRecap(env.handle.db, jobs[0]);
  expect(writer).toHaveBeenCalledTimes(1);
  expect(writer.mock.calls[0][0].recap).toBe(true);
  const [episode] = await env.handle.db.select().from(podcastEpisodes);
  expect(episode.document.durationSeconds).toBeLessThan(180);
  expect(episode.document.maxDurationSeconds).toBe(179);
  expect(env.podcastVideoDesigns).toHaveLength(1);
  await env.runPodcastVideoDesigns();
  expect(env.podcastRenders).toHaveLength(1);
  expect(env.podcastRenders[0].resolution).toBe(1080);
});

it("honors disabling and account deletion before spending points", async () => {
  await enable(); await chip();
  await dispatchDailyRecaps(env.handle.db, due);
  await env.handle.db.update(dailyRecapSchedules).set({ enabled: false });
  const writer = vi.spyOn(env.ai, "writePodcast");
  await runDailyRecap(env.handle.db, jobs[0]);
  expect(writer).not.toHaveBeenCalled();
  await enable();
  await env.handle.db.update(users).set({ deletionScheduledAt: new Date() }).where(eq(users.id, "user-alice"));
  expect((await dispatchDailyRecaps(env.handle.db, due)).started).toBe(0);
});

it("records failures without retrying billable generation or ambiguous workflow starts", async () => {
  await enable(); await chip();
  await dispatchDailyRecaps(env.handle.db, due);
  const writer = vi.spyOn(env.ai, "writePodcast").mockRejectedValue(new Error("provider unavailable"));
  await runDailyRecap(env.handle.db, jobs[0]);
  await runDailyRecap(env.handle.db, jobs[0]);
  expect(writer).toHaveBeenCalledTimes(1);
  expect((await dailyRecapSettings(env.handle.db, "user-alice")).lastRun?.status).toBe("failed");
  const tomorrow = new Date(due.getTime() + 86400000);
  const start = vi.fn(async () => { throw new Error("ambiguous start"); });
  setDailyRecapStarterForTests({ start });
  await dispatchDailyRecaps(env.handle.db, tomorrow);
  await dispatchDailyRecaps(env.handle.db, tomorrow);
  expect(start).toHaveBeenCalledTimes(1);
});

it("rejects an oversized automatic recap script before speech", async () => {
  const automatic = true;
  await chip();
  const original = env.ai.writePodcast.bind(env.ai);
  vi.spyOn(env.ai, "writePodcast").mockImplementation(async input => {
    const script = await original(input);
    script.segments = Array.from({ length: automatic ? 5 : 9 }, () => ({ ...script.segments[0], caption: "long ".repeat(90) }));
    return script;
  });
  await expect(createDailyPodcast(env.handle.db, "user-alice", { day: recapDay(due, input.timeZone).day, language: "en", recap: automatic || undefined, library: false, regenerate: true }))
    .rejects.toMatchObject({ code: "PODCAST_RECAP_TOO_LONG" });
  expect(await env.handle.db.select().from(podcastEpisodes)).toHaveLength(0);
});

it("measures the finished audio and rejects an over-limit recording before storage", async () => {
  const fixture = readFileSync(new URL("../fixtures/podcast/one.mp3", import.meta.url));
  const duration = joinPodcastAudio([fixture]).durationSeconds;
  const podcast = { segments: [{ speaker: 0, chipId: "one", caption: "Short", imagePath: null, icon: "", captionCues: [{ text: "Short", startSeconds: 0, endSeconds: duration }] }] };
  const put = vi.spyOn(env.store, "put");
  await expect(storeContinuousAudio(env.store, "overlong.mp3", "/audio", podcast, [fixture], null, duration - 0.01)).rejects.toMatchObject({ code: "PODCAST_RECAP_TOO_LONG" });
  expect(put).not.toHaveBeenCalled();
  await storeContinuousAudio(env.store, "short.mp3", "/audio", podcast, [fixture], null, duration + 0.01);
  expect(put).toHaveBeenCalledTimes(1);
});

it("refuses unauthenticated cron calls", async () => {
  vi.stubEnv("CRON_SECRET", "recap-test");
  expect((await cronRoute.GET(new Request("https://example.test/api/cron/daily-recaps"))).status).toBe(401);
  expect(await env.handle.db.select().from(dailyRecapRuns)).toHaveLength(0);
});


it.each([true, false])("keeps only ranked stories in recap/manual daily summary sources (automatic=%s)", async (automatic) => {
  const important = await chip("Major discovery");
  const minor = await chip("Minor update");
  const write = env.ai.writePodcast.bind(env.ai);
  const writer = vi.spyOn(env.ai, "writePodcast").mockImplementation(input => write({ ...input, chips: input.chips.filter(chip => chip.id === important.id) }));
  const podcast = await createDailyPodcast(env.handle.db, "user-alice", {
    day: recapDay(due, input.timeZone).day, language: "en", recap: automatic || undefined, includeVideo: true, library: false, regenerate: true,
  });
  expect(podcast.maxDurationSeconds).toBe(automatic ? 179 : undefined);
  expect(writer.mock.calls[0][0]).toMatchObject({ recap: true, maxDurationSeconds: automatic ? 179 : 360 });
  expect(podcast.chipIds).toEqual([important.id]);
  expect(podcast.chipIds).not.toContain(minor.id);
  await env.runPodcastVideoDesigns();
  expect(env.ai.calls.writePodcastVideo[0].chips.map(chip => chip.id)).toEqual([important.id]);
});

it("excludes generated podcast chips and skips a podcast-only day before AI", async () => {
  const podcastChip = await chip();
  await env.handle.db.update(summaries).set({ kind: "podcast" }).where(eq(summaries.id, podcastChip.id));
  const day = recapDay(due, input.timeZone).day;
  expect(await dailyPodcastChips(env.handle.db, "user-alice", day)).toEqual([]);
  await enable();
  await dispatchDailyRecaps(env.handle.db, due);
  const writer = vi.spyOn(env.ai, "writePodcast");
  await runDailyRecap(env.handle.db, jobs[0]);
  expect(writer).not.toHaveBeenCalled();
  expect(env.podcastVideoDesigns).toEqual([]);
  expect((await dailyRecapSettings(env.handle.db, "user-alice")).lastRun?.status).toBe("skipped");
});


it.each([false, true])("saves manual podcasts beyond the approximate script and audio target (library=%s)", async (library) => {
  const source = await chip();
  const write = env.ai.writePodcast.bind(env.ai);
  const writer = vi.spyOn(env.ai, "writePodcast").mockImplementation(async input => {
    const script = await write(input);
    return { ...script, segments: [{ ...script.segments[0], caption: "Complete natural sentence. ".repeat(15) }] };
  });
  const speak = env.ai.speak.bind(env.ai);
  const transcribe = env.ai.transcribePodcast.bind(env.ai);
  let originalAudio!: Uint8Array;
  vi.spyOn(env.ai, "transcribePodcast").mockImplementation(() => transcribe(originalAudio));
  vi.spyOn(env.ai, "speak").mockImplementation(async (...args) => {
    const audio = await speak(...args);
    originalAudio = audio.bytes;
    const long = joinPodcastAudio(Array.from({ length: 400 }, () => audio.bytes));
    return { ...audio, bytes: long.bytes };
  });
  const podcast = await createDailyPodcast(env.handle.db, "user-alice", {
    day: recapDay(due, input.timeZone).day, language: "en", library, regenerate: false, chipIds: [source.id], durationSeconds: 30, includeVideo: false,
  });
  expect(podcast.durationSeconds).toBeGreaterThan(30);
  expect(podcast.maxDurationSeconds).toBeUndefined();
  expect(writer).toHaveBeenCalledTimes(1);
  expect(writer.mock.calls[0][0]).toMatchObject({ maxDurationSeconds: 30, approximateDuration: true });
  expect(await env.handle.db.select().from(podcastEpisodes)).toHaveLength(1);
});
