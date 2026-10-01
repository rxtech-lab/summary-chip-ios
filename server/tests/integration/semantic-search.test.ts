import { eq } from "drizzle-orm";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as summariesRoute from "@/app/api/v1/summaries/route";
import * as summaryRoute from "@/app/api/v1/summaries/[id]/route";
import * as cronRoute from "@/app/api/cron/cleanup/route";
import { MOCK_EMBEDDING_MODEL } from "@/lib/ai/mock";
import { summaryEmbeddings } from "@/lib/db/schema";
import { backfillEmbeddings } from "@/lib/services/embeddings";
import { searchForChat } from "@/lib/services/views";
import { apiRequest, params, setupTestEnv, type TestEnv } from "../helpers/setup";

let env: TestEnv;

beforeEach(async () => {
  env = await setupTestEnv();
  // The mock embeds a hashed set of words, which sits far further apart than a real model's vectors.
  vi.stubEnv("SEARCH_MAX_DISTANCE", "0.85");
});

afterEach(() => {
  vi.unstubAllEnvs();
  env.teardown();
});

async function createText(text: string, title: string, token = env.tokens.alice) {
  const response = await summariesRoute.POST(apiRequest("POST", "/api/v1/summaries", { token, body: { source: { type: "text", text, title } } }));
  expect(response.status).toBe(201);
  return response.json() as Promise<{ id: string; slug: string }>;
}

const search = async (q: string, extra = "") => {
  const response = await summariesRoute.GET(apiRequest("GET", `/api/v1/summaries?q=${encodeURIComponent(q)}${extra}`, { token: env.tokens.alice }));
  expect(response.status).toBe(200);
  return response.json() as Promise<{ items: Array<{ id: string }>; nextCursor: string | null }>;
};
const ids = (page: { items: Array<{ id: string }> }) => page.items.map((item) => item.id);

// The mock summary only quotes the first sentence; the second lives in the original text alone,
// which keyword search does not look at but the embedding does.
const BEES = "Honeybees communicate through a waggle dance. Foragers report pollen meadows nectar distance direction sunlight.";
const OCEAN = "Ocean tides follow the moon. Spring tides happen when the sun and moon align.";

describe("semantic search", () => {
  it("embeds summaries on create and finds them by meaning, not only keywords", async () => {
    const bees = await createText(BEES, "Bee dances");
    const ocean = await createText(OCEAN, "Tides");
    const rows = await env.handle.db.select({ id: summaryEmbeddings.summaryId, model: summaryEmbeddings.model }).from(summaryEmbeddings);
    expect(rows.map((row) => row.id).sort()).toEqual([bees.id, ocean.id].sort());
    expect(rows.every((row) => row.model === MOCK_EMBEDDING_MODEL)).toBe(true);

    expect(ids(await search("pollen meadows nectar"))).toEqual([bees.id]);
    // Turning semantic search off falls back to keywords, which miss the original-text-only words.
    vi.spyOn(env.ai, "embeddingModelId").mockReturnValue(null);
    expect(ids(await search("pollen meadows nectar"))).toEqual([]);
    expect(ids(await search("tides"))).toEqual([ocean.id]);
  });

  it("ranks keyword hits first and pages relevance results with an offset cursor", async () => {
    const a = await createText("Moon landings were a Cold War milestone. Astronauts collected lunar rocks.", "Apollo");
    const b = await createText(OCEAN, "Tides");
    const c = await createText("Gardening by the moon is folklore. Planting follows lunar phases.", "Moon gardening");
    const first = await search("moon", "&limit=2");
    expect(first.items).toHaveLength(2);
    expect(first.nextCursor).toEqual(expect.any(String));
    const second = await search("moon", `&limit=2&cursor=${first.nextCursor}`);
    expect(second.nextCursor).toBeNull();
    expect([...ids(first), ...ids(second)].sort()).toEqual([a.id, b.id, c.id].sort());

    const invalid = await summariesRoute.GET(apiRequest("GET", "/api/v1/summaries?q=moon&cursor=bogus", { token: env.tokens.alice }));
    expect(invalid.status).toBe(400);
  });

  it("only returns summaries the caller may see", async () => {
    await createText(BEES, "Bee dances", env.tokens.bob);
    expect(ids(await search("pollen meadows nectar"))).toEqual([]);
  });

  it("re-embeds on rename and backfills missing or outdated embeddings", async () => {
    const bees = await createText(BEES, "Bee dances");
    const patched = await summaryRoute.PATCH(
      apiRequest("PATCH", `/api/v1/summaries/${bees.id}`, { token: env.tokens.alice, body: { title: "Apiary semaphore" } }),
      params({ id: bees.id }),
    );
    expect(patched.status).toBe(200);
    expect(ids(await search("apiary semaphore"))).toEqual([bees.id]);

    await env.handle.db.delete(summaryEmbeddings);
    vi.spyOn(env.ai, "embeddingModelId").mockReturnValue("mock/next-model");
    expect(await backfillEmbeddings(env.handle.db, env.ai)).toEqual({ embedded: 1, failed: 0 });
    const [row] = await env.handle.db.select().from(summaryEmbeddings).where(eq(summaryEmbeddings.summaryId, bees.id));
    expect(row.model).toBe("mock/next-model");
    expect(await backfillEmbeddings(env.handle.db, env.ai)).toEqual({ embedded: 0, failed: 0 });
  });

  it("runs the backfill from the cleanup cron", async () => {
    vi.stubEnv("CRON_SECRET", "cron-secret");
    await createText(BEES, "Bee dances");
    await env.handle.db.delete(summaryEmbeddings);
    const response = await cronRoute.GET(new Request("http://localhost/api/cron/cleanup", { headers: { authorization: "Bearer cron-secret" } }));
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ ok: true, embeddings: { embedded: 1, failed: 0 } });
  });

  it("backs the chat tool with semantic results", async () => {
    const bees = await createText(BEES, "Bee dances");
    await createText(OCEAN, "Tides");
    const result = await searchForChat(env.handle.db, "user-alice", { query: "pollen meadows nectar", scope: "all" }, env.ai);
    expect(result).toMatchObject({ query: "pollen meadows nectar", semantic: true });
    expect(result.results.map((item) => item.id)).toEqual([bees.id]);
    const recent = await searchForChat(env.handle.db, "user-alice", { query: "", scope: "all" }, env.ai);
    expect(recent.semantic).toBe(false);
    expect(recent.results).toHaveLength(2);
  });
});
