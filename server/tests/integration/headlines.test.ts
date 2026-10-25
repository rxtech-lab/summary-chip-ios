import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { eq } from "drizzle-orm";
import * as summariesRoute from "@/app/api/v1/summaries/route";
import * as route from "@/app/api/v1/summaries/headlines/route";
import { headlineRankings, summaries, users } from "@/lib/db/schema";
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
