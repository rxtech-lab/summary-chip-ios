import { chatInstructions, chatTools } from "@/lib/ai/chat";
import { editorsPicksInputSchema, listEditorsPicksForChat } from "@/lib/services/views";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { eq, sql } from "drizzle-orm";
import { readFileSync } from "node:fs";
import * as summariesRoute from "@/app/api/v1/summaries/route";
import * as route from "@/app/api/v1/summaries/headlines/route";
import { editorialScores, headlineRankings, podcastEpisodes, pushDevices, summaries, users } from "@/lib/db/schema";
import type { DailyPodcast } from "@/lib/contracts/daily-podcast";
import { getHeadlines, headlineWeight, rerankHeadlines } from "@/lib/services/headlines";
import { apiRequest, setupTestEnv, type TestEnv } from "../helpers/setup";

let env: TestEnv;
const now = new Date("2026-10-25T12:00:00Z");
beforeEach(async () => {
  env = await setupTestEnv();
  await env.handle.db.insert(users).values([{ id: "user-alice" }, { id: "user-bob" }]);
});
afterEach(() => env.teardown());
async function chip(id: string, kind: "summary" | "podcast" | "trip" = "summary", ownerId = "user-alice", ageHours = 0) {
  await env.handle.db.insert(summaries).values({ id, slug: id, ownerId, kind,
    sourceType: "text", title: id, summary: "Substantive news", highlights: [], category: "Other", tags: [], keywords: [],
    language: "en", theme: { colors: [], mode: "light", emoji: "", accent: "" }, visibility: "private",
    createdAt: new Date(now.getTime() - ageHours * 3600000), updatedAt: now });
}

describe("editorial headlines", () => {
  it("reranks automatically after creating a summary", async () => {
    const response = await summariesRoute.POST(apiRequest("POST", "/api/v1/summaries", {
      token: env.tokens.alice, body: { source: { type: "text", text: "Researchers discover a useful new battery chemistry." }, followLinks: false },
    }));
    expect(response.status).toBe(201);
    const created = await response.json();
    await vi.waitFor(async () => {
      const result = await getHeadlines(env.handle.db, "user-alice");
      expect(result.highlighted).toMatchObject({ id: created.id, score: 75 });
    });
  });
  it("requires authentication", async () => {
    expect((await route.GET(apiRequest("GET", "/api/v1/summaries/headlines"))).status).toBe(401);
  });
  it("returns an empty library without scheduling a rank", async () => {
    expect(await getHeadlines(env.handle.db, "user-alice", now)).toMatchObject({ pending: false, items: [], highlighted: null });
  });
  it("ranks only the owner's summary and podcast chips by score and recency", async () => {
    await chip("older", "summary", "user-alice", 24);
    await chip("fresh", "podcast");
    await chip("excluded", "trip");
    await chip("other-account", "summary", "user-bob");
    await rerankHeadlines(env.handle.db, "user-alice", async (chips) => {
      expect(chips.map((chip) => chip.id).sort()).toEqual(["fresh", "older"]);
      return { older: 100, fresh: 80 };
    });
    const response = await route.GET(apiRequest("GET", "/api/v1/summaries/headlines", { token: env.tokens.alice }));
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toContain("no-store");
    expect((await response.json()).items.map((item: { id: string }) => item.id).sort()).toEqual(["fresh", "older"]);
    const result = await getHeadlines(env.handle.db, "user-alice", now);
    expect(result.items.map((item) => [item.id, item.score])).toEqual([["fresh", 80], ["older", 100]]);
    expect(result.highlighted?.id).toBe("fresh");
    expect(headlineWeight(100, new Date(now.getTime() - 86400000), now)).toBe(50);
  });
  it("backfills stored decisions from legacy ranking scores with owner and kind checks", async () => {
    await chip("legacy");
    await chip("legacy-low");
    await chip("wrong-owner", "summary", "user-bob");
    await chip("wrong-kind", "trip");
    await env.handle.db.insert(headlineRankings).values({ ownerId: "user-alice", revision: "legacy", startedAt: now,
      scores: { legacy: 80, "legacy-low": 79, "wrong-owner": 100, "wrong-kind": 100, deleted: 100 } });
    const migration = readFileSync("drizzle/0041_editorial_scores.sql", "utf8");
    await env.handle.db.run(sql.raw(migration.slice(migration.indexOf("INSERT INTO editorial_scores"))));
    expect((await getHeadlines(env.handle.db, "user-alice", now)).editorPickIDs).toEqual(["legacy"]);
    expect(await env.handle.db.select().from(editorialScores)).toHaveLength(2);
  });
  it("backfills the lower threshold without changing scores or ranking timestamps", async () => {
    for (const [id, score] of [["below", 69], ["boundary", 70], ["above", 79], ["existing", 80]] as const) {
      await chip(id);
      await env.handle.db.insert(editorialScores).values({ summaryId: id, ownerId: "user-alice",
        score, isEditorsPick: score >= 80, rankedAt: now });
    }
    await env.handle.db.run(sql.raw(readFileSync("drizzle/0042_editorial_threshold_70.sql", "utf8")));
    expect((await getHeadlines(env.handle.db, "user-alice", now)).editorPickIDs.sort()).toEqual(["above", "boundary", "existing"]);
    const rows = await env.handle.db.select().from(editorialScores);
    expect(rows.every((row) => row.rankedAt.getTime() === now.getTime())).toBe(true);
    expect(rows.map((row) => row.score).sort()).toEqual([69, 70, 79, 80]);
  });
  it("persists multiple picks on each day and excludes low scores and other accounts", async () => {
    await chip("today-summary");
    await chip("today-podcast", "podcast");
    await chip("yesterday-a", "summary", "user-alice", 24);
    await chip("yesterday-b", "podcast", "user-alice", 24);
    await chip("below-cutoff");
    await chip("bob-pick", "summary", "user-bob");
    await rerankHeadlines(env.handle.db, "user-bob", async () => ({ "bob-pick": 100 }));
    await rerankHeadlines(env.handle.db, "user-alice", async (chips) =>
      Object.fromEntries(chips.map((chip) => [chip.id, chip.id === "below-cutoff" ? 69 : 70])));
    const response = await route.GET(apiRequest("GET", "/api/v1/summaries/headlines", { token: env.tokens.alice }));
    const result = await response.json();
    expect(result.editorPickIDs.sort()).toEqual(["today-podcast", "today-summary", "yesterday-a", "yesterday-b"]);
    expect(await env.handle.db.select().from(editorialScores).where(eq(editorialScores.ownerId, "user-alice"))).toHaveLength(5);
    // Persisted picks remain visible while the next ranking is pending.
    await chip("unranked");
    const pending = await getHeadlines(env.handle.db, "user-alice", now);
    expect(pending.pending).toBe(true);
    expect(pending.editorPickIDs.sort()).toEqual(result.editorPickIDs.sort());
  });
  it("retains old picks outside the evaluation window and cascades chip deletion", async () => {
    await chip("historic", "summary", "user-alice", 100);
    await rerankHeadlines(env.handle.db, "user-alice", async () => ({ historic: 95 }));
    for (let index = 0; index < 50; index++) await chip(`recent-${index}`);
    await rerankHeadlines(env.handle.db, "user-alice", async (chips) =>
      Object.fromEntries(chips.map((chip) => [chip.id, 40])));
    const result = await getHeadlines(env.handle.db, "user-alice", now);
    expect(result.items.some((item) => item.id === "historic")).toBe(false);
    expect(result.editorPickIDs).toEqual(["historic"]);
    await env.handle.db.delete(summaries).where(eq(summaries.id, "historic"));
    expect((await getHeadlines(env.handle.db, "user-alice", now)).editorPickIDs).toEqual([]);
    expect(await env.handle.db.select().from(editorialScores).where(eq(editorialScores.summaryId, "historic"))).toEqual([]);
  });
  it("filters saved picks before pagination, combines facets, and isolates accounts", async () => {
    await chip("old-pick", "summary", "user-alice", 100);
    await rerankHeadlines(env.handle.db, "user-alice", async () => ({ "old-pick": 90 }));
    for (let index = 0; index < 21; index++) await chip(`non-pick-${index}`);
    await chip("podcast-pick", "podcast");
    await chip("bob-pick", "summary", "user-bob");
    await chip("trip", "trip");
    await rerankHeadlines(env.handle.db, "user-bob", async () => ({ "bob-pick": 100 }));
    await rerankHeadlines(env.handle.db, "user-alice", async (chips) =>
      Object.fromEntries(chips.map((chip) => [chip.id, chip.id.endsWith("pick") ? 70 : 69])));
    const list = async (query: string) => {
      const response = await summariesRoute.GET(apiRequest("GET", `/api/v1/summaries?${query}`, { token: env.tokens.alice }));
      expect(response.status).toBe(200);
      return response.json();
    };
    const first = await list("editorsPick=true&limit=1");
    expect(first.items.map((item: { id: string }) => item.id)).toEqual(["podcast-pick"]);
    expect(first.nextCursor).toBeTruthy();
    const second = await list(`editorsPick=true&limit=1&cursor=${encodeURIComponent(first.nextCursor)}`);
    expect(second.items.map((item: { id: string }) => item.id)).toEqual(["old-pick"]);
    expect(second.nextCursor).toBeNull();
    const podcast = await list("editorsPick=true&kind=podcast&visibility=private&category=Other");
    expect(podcast.items.map((item: { id: string }) => item.id)).toEqual(["podcast-pick"]);
    expect((await list("editorsPick=true&scope=viewed")).items).toEqual([]);
    expect((await list("editorsPick=true&kind=trip")).items).toEqual([]);
    const all: { id: string; isEditorsPick: boolean }[] = (await list("editorsPick=false&limit=50")).items;
    expect(all).toHaveLength(24);
    // The unfiltered list marks the same picks, so the app badges cards without waiting on Headlines.
    expect(all.filter((item) => item.isEditorsPick).map((item) => item.id).sort()).toEqual(["old-pick", "podcast-pick"]);
    const invalid = await summariesRoute.GET(apiRequest("GET", "/api/v1/summaries?editorsPick=invalid", { token: env.tokens.alice }));
    expect(invalid.status).toBe(400);
  });
  it("never picks a podcast about one chip, and stacks it on that chip", async () => {
    await chip("source");
    await chip("other");
    await chip("solo", "podcast");
    await chip("multi", "podcast");
    const episode = async (key: string, summaryId: string, chipIds: string[], deleted = false) =>
      env.handle.db.insert(podcastEpisodes).values({ key, ownerId: "user-alice", dayStart: 0, dayEnd: 1, summaryId, deleted,
        document: { key, summaryId, chipIds, createdAt: now.toISOString() } as unknown as DailyPodcast });
    await episode("solo-1", "solo", ["source"]);
    await episode("solo-2", "solo", ["source"]);
    // A deleted version about other chips no longer counts.
    await episode("solo-old", "solo", ["source", "other"], true);
    await episode("multi-1", "multi", ["source", "other"]);
    await rerankHeadlines(env.handle.db, "user-alice", async (chips) => {
      expect(chips.map((chip) => chip.id).sort()).toEqual(["multi", "other", "source"]);
      return Object.fromEntries(chips.map((chip) => [chip.id, 90]));
    });
    // A pick stored before the podcast became solo is hidden too.
    await env.handle.db.insert(editorialScores).values({ summaryId: "solo", ownerId: "user-alice", score: 90, isEditorsPick: true, rankedAt: now });
    expect((await getHeadlines(env.handle.db, "user-alice", now)).editorPickIDs.sort()).toEqual(["multi", "other", "source"]);
    const response = await summariesRoute.GET(apiRequest("GET", "/api/v1/summaries?limit=50", { token: env.tokens.alice }));
    const items: { id: string; podcastSourceId: string | null; stackedPodcastId: string | null }[] = (await response.json()).items;
    const byId = Object.fromEntries(items.map((item) => [item.id, item]));
    expect(byId.solo).toMatchObject({ podcastSourceId: "source", stackedPodcastId: null });
    expect(byId.multi).toMatchObject({ podcastSourceId: null, stackedPodcastId: null });
    expect(byId.source).toMatchObject({ podcastSourceId: null, stackedPodcastId: "solo" });
    expect(byId.other).toMatchObject({ stackedPodcastId: null });
    expect(items.filter((item) => (item as { isEditorsPick?: boolean }).isEditorsPick).map((item) => item.id).sort())
      .toEqual(["multi", "other", "source"]);
    const picks = await summariesRoute.GET(apiRequest("GET", "/api/v1/summaries?editorsPick=true", { token: env.tokens.alice }));
    expect((await picks.json()).items.map((item: { id: string }) => item.id)).not.toContain("solo");
  });
  it("updates stored pick decisions when a chip is rescored", async () => {
    await chip("first");
    await rerankHeadlines(env.handle.db, "user-alice", async () => ({ first: 90 }));
    expect((await getHeadlines(env.handle.db, "user-alice", now)).editorPickIDs).toEqual(["first"]);
    await rerankHeadlines(env.handle.db, "user-alice", async () => ({ first: 69 }));
    expect((await getHeadlines(env.handle.db, "user-alice", now)).editorPickIDs).toEqual([]);
    expect(await env.handle.db.select().from(editorialScores)).toMatchObject([{ score: 69, isEditorsPick: false }]);
  });
  it("prevents a slower earlier evaluation from replacing newer stored decisions", async () => {
    await chip("first");
    await rerankHeadlines(env.handle.db, "user-alice", async () => {
      await new Promise((resolve) => setTimeout(resolve, 5));
      await rerankHeadlines(env.handle.db, "user-alice", async () => ({ first: 20 }));
      return { first: 100 };
    });
    const result = await getHeadlines(env.handle.db, "user-alice", now);
    expect(result.editorPickIDs).toEqual([]);
    expect(result.items[0].score).toBe(20);
  });
  it("limits evaluation to the latest 50 chips", async () => {
    for (let index = 0; index < 52; index++) await chip(`c${index}`, "summary", "user-alice", index);
    await rerankHeadlines(env.handle.db, "user-alice", async (chips) => {
      expect(chips).toHaveLength(50);
      expect(chips.some((chip) => chip.id === "c51")).toBe(false);
      return Object.fromEntries(chips.map((chip) => [chip.id, 50]));
    });
    expect((await getHeadlines(env.handle.db, "user-alice", now)).items).toHaveLength(50);
  });
  it("invalidates rankings after additions and deletions, and reranks the entire window", async () => {
    await chip("first");
    await rerankHeadlines(env.handle.db, "user-alice", async () => ({ first: 90 }));
    await chip("second", "podcast");
    expect(await getHeadlines(env.handle.db, "user-alice", now)).toMatchObject({ pending: true, highlighted: null });
    await rerankHeadlines(env.handle.db, "user-alice", async () => ({ first: 20, second: 100 }));
    expect((await getHeadlines(env.handle.db, "user-alice", now)).highlighted?.id).toBe("second");
    await env.handle.db.delete(summaries).where(eq(summaries.id, "second"));
    expect((await getHeadlines(env.handle.db, "user-alice", now)).highlighted).toBeNull();
  });
  it("rejects a stale model result when a chip arrives during evaluation", async () => {
    await chip("first");
    await rerankHeadlines(env.handle.db, "user-alice", async () => {
      await chip("newer");
      return { first: 90 };
    });
    expect(await env.handle.db.select().from(headlineRankings)).toHaveLength(0);
  });
  it("keeps the last completed snapshot on scorer failure and rejects invalid scores", async () => {
    await chip("first");
    await rerankHeadlines(env.handle.db, "user-alice", async () => ({ first: 90 }));
    await expect(rerankHeadlines(env.handle.db, "user-alice", async () => { throw new Error("timeout"); })).rejects.toThrow("timeout");
    await expect(rerankHeadlines(env.handle.db, "user-alice", async () => ({ first: 101 }))).rejects.toThrow("Invalid".toLowerCase());
    expect((await getHeadlines(env.handle.db, "user-alice", now)).highlighted?.score).toBe(90);
  });
});


describe("Editor’s Picks by calendar date", () => {
  async function pick(id: string, at: string, kind: "summary" | "podcast" | "trip" = "summary", owner = "user-alice", score = 70) {
    await chip(id, kind, owner);
    await env.handle.db.update(summaries).set({ createdAt: new Date(at) }).where(eq(summaries.id, id));
    await env.handle.db.insert(editorialScores).values({ summaryId: id, ownerId: owner, score,
      isEditorsPick: score >= 70, rankedAt: now });
  }
  it("uses local creation-day bounds and keyset paging, including old picks and private podcasts", async () => {
    await pick("before", "2026-09-30T15:59:59.999Z");
    await pick("start", "2026-09-30T16:00:00Z");
    await pick("podcast", "2026-10-01T15:59:59.999Z", "podcast");
    await pick("end", "2026-10-01T16:00:00Z");
    await pick("low", "2026-10-01T10:00:00Z", "summary", "user-alice", 69);
    await pick("trip", "2026-10-01T10:00:00Z", "trip");
    await pick("bob", "2026-10-01T10:00:00Z", "summary", "user-bob");
    const query = { date: "2026-10-01", timeZone: "Asia/Hong_Kong", limit: 1 };
    const first = await listEditorsPicksForChat(env.handle.db, "user-alice", query);
    expect(first).toMatchObject({ date: "2026-10-01", timeZone: "Asia/Hong_Kong", dateBasis: "createdAt" });
    expect(first.results.map((item) => item.id)).toEqual(["podcast"]);
    expect(first.results[0]).toMatchObject({ kind: "podcast", score: 70, title: "podcast" });
    const second = await listEditorsPicksForChat(env.handle.db, "user-alice", { ...query, cursor: first.nextCursor! });
    expect(second.results.map((item) => item.id)).toEqual(["start"]);
    expect(second.nextCursor).toBeNull();
  });
  it("resolves today and yesterday from the caller's device, with UTC fallback", async () => {
    await env.handle.db.insert(pushDevices).values({ installationId: "alice", ownerId: "user-alice", token: "a",
      environment: "sandbox", platform: "ios", timeZone: "Asia/Hong_Kong" });
    await pick("local-today", "2026-10-25T17:00:00Z");
    await pick("local-yesterday", "2026-10-24T17:00:00Z");
    const at = new Date("2026-10-25T18:00:00Z");
    const today = await listEditorsPicksForChat(env.handle.db, "user-alice", {}, at);
    expect(today.date).toBe("2026-10-26");
    expect(today.results.map((item) => item.id)).toEqual(["local-today"]);
    const yesterday = await listEditorsPicksForChat(env.handle.db, "user-alice", { date: "yesterday" }, at);
    expect(yesterday.date).toBe("2026-10-25");
    expect(yesterday.results.map((item) => item.id)).toEqual(["local-yesterday"]);
    expect(await listEditorsPicksForChat(env.handle.db, "user-bob", {}, at)).toMatchObject({ date: "2026-10-25", timeZone: "UTC", results: [], nextCursor: null });
  });
  it("includes the full 25-hour daylight saving day without including the next midnight", async () => {
    await pick("start", "2026-11-01T04:00:00Z");
    await pick("late", "2026-11-02T04:59:59.999Z");
    await pick("end", "2026-11-02T05:00:00Z");
    const result = await listEditorsPicksForChat(env.handle.db, "user-alice", { date: "2026-11-01", timeZone: "America/New_York" });
    expect(result.results.map((item) => item.id)).toEqual(["late", "start"]);
  });
  it("validates dates/zones and makes the dedicated tool available to chat", async () => {
    expect(editorsPicksInputSchema.safeParse({ date: "2026-02-30" }).success).toBe(false);
    expect(editorsPicksInputSchema.safeParse({ timeZone: "Invalid/Zone" }).success).toBe(false);
    const tool = chatTools(env.handle.db, "user-alice").listEditorsPicks;
    const result = await tool.execute!({ date: "2026-10-25", limit: 20 }, { toolCallId: "pick-test", messages: [], context: {} });
    expect(result).toMatchObject({ date: "2026-10-25", results: [], nextCursor: null });
    expect(chatInstructions()).toContain("use listEditorsPicks, never semantic search");
  });
});
