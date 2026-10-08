import { eq } from "drizzle-orm";
import sharp from "sharp";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as apiKeysRoute from "@/app/api/v1/api-keys/route";
import * as apiKeyRoute from "@/app/api/v1/api-keys/[id]/route";
import * as mcpRoute from "@/app/api/mcp/route";
import * as importRoute from "@/app/api/v1/summaries/import/route";
import * as tripImageRoute from "@/app/api/public/trip-images/[file]/route";
import type { TripDocument } from "@/lib/contracts/trip";
import { MAX_UPLOAD_BYTES } from "@/lib/contracts/api";
import { apiKeys, summaries, uploads } from "@/lib/db/schema";
import { hashApiKey, MAX_API_KEYS_PER_USER } from "@/lib/services/api-keys";
import { ownerKeyPrefix } from "@/lib/storage/r2";
import { apiRequest, params, setupTestEnv, type TestEnv } from "../helpers/setup";

let env: TestEnv;

beforeEach(async () => {
  env = await setupTestEnv();
});

afterEach(() => {
  env.teardown();
  vi.unstubAllGlobals();
  vi.unstubAllEnvs();
});

async function createKey(name = "Claude Code", token = env.tokens.alice) {
  const response = await apiKeysRoute.POST(apiRequest("POST", "/api/v1/api-keys", { token, body: { name } }));
  expect(response.status).toBe(201);
  return response.json() as Promise<{ key: string; apiKey: { id: string; name: string; hint: string } }>;
}

let rpcId = 0;

function mcpRequest(key: string | undefined, method: string, rpcParams?: unknown) {
  return mcpRoute.POST(apiRequest("POST", "/api/mcp", {
    token: key,
    headers: { accept: "application/json, text/event-stream" },
    body: { jsonrpc: "2.0", id: ++rpcId, method, ...(rpcParams === undefined ? {} : { params: rpcParams }) },
  }));
}

async function callTool(key: string, name: string, args: Record<string, unknown>) {
  const response = await mcpRequest(key, "tools/call", { name, arguments: args });
  expect(response.status).toBe(200);
  const body = await response.json();
  return body.result as { isError?: boolean; content: { type: string; text: string }[]; structuredContent?: Record<string, unknown> };
}

/** What a chip's cover is made of: the designed art and card, their theme and headline. */
async function coverOf(id: string) {
  const [row] = await env.handle.db.select({
    ogImageKey: summaries.ogImageKey, artImageKey: summaries.artImageKey, theme: summaries.theme, ogHeadline: summaries.ogHeadline,
  }).from(summaries).where(eq(summaries.id, id));
  return row;
}

const CHIP = {
  title: "Monarch migration",
  summary: "Monarch butterflies fly thousands of kilometres south every autumn.",
  text: "Raw field notes: monarchs left the meadow on 2 October, heading south-west.",
  keyPoints: ["They fly south"],
  tags: ["Butterflies", "migration"],
  category: "Science",
};

describe("/api/v1/api-keys", () => {
  it("needs the app's OAuth token, not an API key", async () => {
    const { key } = await createKey();
    const response = await apiKeysRoute.GET(apiRequest("GET", "/api/v1/api-keys", { token: key }));
    expect(response.status).toBe(401);
  });

  it("returns the key once and stores only its hash", async () => {
    const created = await createKey("  Claude Code  ");
    expect(created.key).toMatch(/^chippy_[A-Za-z0-9_-]{43}$/);
    expect(created.apiKey).toMatchObject({ name: "Claude Code", toolCallCount: 0, summariesAddedCount: 0, lastUsedAt: null });
    expect(created.apiKey.hint).toBe(`${created.key.slice(0, 11)}…${created.key.slice(-4)}`);

    const [row] = await env.handle.db.select().from(apiKeys);
    expect(row.keyHash).toBe(hashApiKey(created.key));
    expect(JSON.stringify(row)).not.toContain(created.key);

    const list = await (await apiKeysRoute.GET(apiRequest("GET", "/api/v1/api-keys", { token: env.tokens.alice }))).json();
    expect(list.items).toHaveLength(1);
    expect(list.items[0]).toEqual(created.apiKey);
    expect(JSON.stringify(list)).not.toContain(created.key);
  });

  it("validates the name", async () => {
    for (const body of [{ name: " " }, { name: "x".repeat(61) }, { name: "ok", extra: 1 }]) {
      const response = await apiKeysRoute.POST(apiRequest("POST", "/api/v1/api-keys", { token: env.tokens.alice, body }));
      expect(response.status).toBe(400);
    }
  });

  it("renames and revokes only the owner's keys", async () => {
    const { key, apiKey } = await createKey();
    const bobRename = await apiKeyRoute.PATCH(apiRequest("PATCH", `/api/v1/api-keys/${apiKey.id}`, { token: env.tokens.bob, body: { name: "Mine" } }), params({ id: apiKey.id }));
    expect(bobRename.status).toBe(404);
    const bobRevoke = await apiKeyRoute.DELETE(apiRequest("DELETE", `/api/v1/api-keys/${apiKey.id}`, { token: env.tokens.bob }), params({ id: apiKey.id }));
    expect(bobRevoke.status).toBe(404);

    const renamed = await apiKeyRoute.PATCH(apiRequest("PATCH", `/api/v1/api-keys/${apiKey.id}`, { token: env.tokens.alice, body: { name: "Cursor" } }), params({ id: apiKey.id }));
    expect(renamed.status).toBe(200);
    expect((await renamed.json()).name).toBe("Cursor");

    expect((await mcpRequest(key, "tools/list")).status).toBe(200);
    const revoked = await apiKeyRoute.DELETE(apiRequest("DELETE", `/api/v1/api-keys/${apiKey.id}`, { token: env.tokens.alice }), params({ id: apiKey.id }));
    expect(revoked.status).toBe(204);
    const after = await mcpRequest(key, "tools/list");
    expect(after.status).toBe(401);
    expect((await after.json()).error.code).toBe("INVALID_API_KEY");
  });

  it("caps the number of keys", async () => {
    // The first authenticated request creates the user row the keys belong to.
    await apiKeysRoute.GET(apiRequest("GET", "/api/v1/api-keys", { token: env.tokens.alice }));
    await env.handle.db.insert(apiKeys).values(Array.from({ length: MAX_API_KEYS_PER_USER }, (_, index) => ({
      id: `key-${index}`, ownerId: "user-alice", name: `Key ${index}`, keyHash: `hash-${index}`, hint: "chippy_…",
    })));
    const response = await apiKeysRoute.POST(apiRequest("POST", "/api/v1/api-keys", { token: env.tokens.alice, body: { name: "One more" } }));
    expect(response.status).toBe(409);
    expect((await response.json()).error.code).toBe("API_KEY_LIMIT_REACHED");
  });
});

describe("/api/mcp", () => {
  it("rejects requests without a valid API key", async () => {
    const missing = await mcpRequest(undefined, "tools/list");
    expect(missing.status).toBe(401);
    expect(missing.headers.get("www-authenticate")).toContain("Bearer");
    expect((await missing.json()).error.code).toBe("MISSING_API_KEY");
    expect((await mcpRequest("chippy_not-a-real-key", "tools/list")).status).toBe(401);
    // The app's OAuth token is not an API key.
    expect((await mcpRequest(env.tokens.alice, "tools/list")).status).toBe(401);
  });

  it("initializes and lists the tools", async () => {
    const { key } = await createKey();
    const init = await mcpRequest(key, "initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "1" } });
    expect(init.status).toBe(200);
    const initBody = await init.json();
    expect(initBody.result.serverInfo.name).toBe("chippy");
    expect(initBody.result.instructions).toContain("search_summaries");

    const list = await (await mcpRequest(key, "tools/list")).json();
    expect(list.result.tools.map((tool: { name: string }) => tool.name).sort()).toEqual([
      "add_summary", "add_to_trip_from_source", "choose_plan_option", "create_trip", "create_upload", "get_profile", "get_trip", "get_upload", "list_summaries", "list_trips", "search_summaries", "update_place", "update_summary", "update_trip", "upload_trip_image",
    ]);
    expect(initBody.result.instructions).toContain("update_trip");
    const add = list.result.tools.find((tool: { name: string }) => tool.name === "add_summary");
    expect(add.inputSchema.required).toEqual(expect.arrayContaining(["title", "summary", "text"]));
  });

  it("prepares owner-scoped presigned uploads for images, PDFs and other files", async () => {
    const { key, apiKey } = await createKey();
    const signedPut = vi.spyOn(env.store, "signedPut");
    for (const [filename, mimeType, extension] of [
      ["photo.png", "image/png", "png"], ["report.pdf", "application/pdf", "pdf"],
      ["../archive.zip", "application/zip", "bin"],
    ]) {
      const result = await callTool(key, "create_upload", { filename, mimeType, byteSize: 1024 });
      expect(result.isError).toBeFalsy();
      const upload = result.structuredContent as { key: string; expiresAt: string };
      expect(upload.key).toMatch(new RegExp(`^uploads/${ownerKeyPrefix("user-alice")}/[0-9a-f-]{36}\\.${extension}$`));
      expect(result.structuredContent).toMatchObject({
        method: "PUT", uploadUrl: expect.any(String), headers: { "content-type": mimeType }, expiresAt: expect.any(String),
      });
      expect(Date.parse(upload.expiresAt) - Date.now()).toBeGreaterThan(9 * 60 * 1000);
      expect(signedPut).toHaveBeenLastCalledWith(upload.key, mimeType, 1024);
      const [row] = await env.handle.db.select().from(uploads).where(eq(uploads.key, upload.key));
      expect(row).toMatchObject({ ownerId: "user-alice", filename, byteSize: 1024, attachedAt: null });
      // Preparing a PUT must not pretend the bytes have arrived.
      expect(await env.store.head(upload.key)).toBeNull();
      expect(JSON.parse(result.content[0].text)).toEqual(result.structuredContent);
    }
    const [usage] = await env.handle.db.select().from(apiKeys).where(eq(apiKeys.id, apiKey.id));
    expect(usage).toMatchObject({ toolCallCount: 3, summariesAddedCount: 0 });
  });

  it("rejects invalid upload metadata before signing or creating a row", async () => {
    const { key } = await createKey();
    const signedPut = vi.spyOn(env.store, "signedPut");
    for (const invalid of [
      { filename: " " }, { filename: "x".repeat(301) }, { mimeType: "png" },
      { mimeType: "image/png\r\nX-Other: injected" }, { mimeType: "text/plain; charset=utf-8" },
      { byteSize: 0 }, { byteSize: -1 }, { byteSize: 1.5 }, { byteSize: MAX_UPLOAD_BYTES + 1 },
    ]) {
      const result = await callTool(key, "create_upload", { filename: "photo.png", mimeType: "image/png", byteSize: 100, ...invalid });
      expect(result.isError).toBe(true);
    }
    expect(signedPut).not.toHaveBeenCalled();
    expect(await env.handle.db.select().from(uploads)).toHaveLength(0);
  });

  it("verifies completion and ownership before issuing a file download URL", async () => {
    const { key } = await createKey();
    const bytes = new TextEncoder().encode("Trip packing notes");
    const result = await callTool(key, "create_upload", { filename: "notes.txt", mimeType: "text/plain", byteSize: bytes.length });
    const uploadKey = (result.structuredContent as { key: string }).key;
    const signedGet = vi.spyOn(env.store, "signedGet");
    const early = await callTool(key, "get_upload", { key: uploadKey });
    expect(early.isError).toBe(true);
    expect(early.content[0].text).toContain("UPLOAD_INCOMPLETE");
    expect(signedGet).not.toHaveBeenCalled();

    // Represents the client PUT to S3, outside of the MCP transport.
    await env.store.put(uploadKey, { bytes, contentType: "text/plain" });
    const downloaded = await callTool(key, "get_upload", { key: uploadKey });
    expect(downloaded.isError).toBeFalsy();
    expect(downloaded.structuredContent).toMatchObject({
      key: uploadKey, filename: "notes.txt", mimeType: "text/plain", byteSize: bytes.length,
      downloadUrl: expect.stringContaining("https://downloads.invalid/"), expiresAt: expect.any(String),
    });
    expect(signedGet).toHaveBeenCalledWith(uploadKey, { filename: "notes.txt" });
    signedGet.mockClear();
    const bob = await createKey("Bob", env.tokens.bob);
    for (const [caller, badKey, error] of [
      [bob.key, uploadKey, "UPLOAD_FORBIDDEN"],
      [key, uploadKey.replace(/[^/]+$/, `${crypto.randomUUID()}.txt`), "UPLOAD_NOT_FOUND"],
      [key, "og/not-an-upload.png", "UPLOAD_FORBIDDEN"],
    ]) {
      const denied = await callTool(caller, "get_upload", { key: badKey });
      expect(denied.isError).toBe(true);
      expect(denied.content[0].text).toContain(error);
    }
    await env.store.put(uploadKey, { bytes: bytes.slice(1), contentType: "text/plain" });
    expect((await callTool(key, "get_upload", { key: uploadKey })).content[0].text).toContain("UPLOAD_SIZE_MISMATCH");
    const head = vi.spyOn(env.store, "head").mockResolvedValueOnce({ contentType: "text/plain", byteSize: MAX_UPLOAD_BYTES + 1 });
    expect((await callTool(key, "get_upload", { key: uploadKey })).content[0].text).toContain("UPLOAD_TOO_LARGE");
    head.mockRestore();
    expect(signedGet).not.toHaveBeenCalled();
  });

  it("answers GET with 405 (stateless, no server stream)", async () => {
    expect((await mcpRoute.GET()).status).toBe(405);
  });

  it("adds a chip as the key's owner and counts the usage", async () => {
    const { key, apiKey } = await createKey();
    const result = await callTool(key, "add_summary", { ...CHIP, visibility: "private", ttlDays: "never" });
    expect(result.isError).toBeFalsy();
    expect(result.content[0].text).toContain("Added \"Monarch migration\" (private).");
    const summary = (result.structuredContent as { summary: Record<string, unknown> }).summary;
    expect(summary).toMatchObject({
      title: CHIP.title,
      keyPoints: ["They fly south"],
      tags: ["butterflies", "migration"],
      category: "Science",
      visibility: "private",
      isOwner: true,
      hasSourceText: true,
    });

    const [row] = await env.handle.db.select().from(apiKeys).where(eq(apiKeys.id, apiKey.id));
    expect(row).toMatchObject({ toolCallCount: 1, summariesAddedCount: 1 });
    expect(row.lastUsedAt).toBeInstanceOf(Date);

    // Bob's key doesn't see Alice's private chip.
    const bob = await createKey("Bob", env.tokens.bob);
    const bobList = await callTool(bob.key, "list_summaries", {});
    expect(bobList.structuredContent).toMatchObject({ count: 0, items: [], nextCursor: null });
  });

  it("adds chips and trips for free, without metering the allowance or points", async () => {
    vi.stubEnv("SUMMARY_OG_REMOTE_ASSETS", "false");
    vi.stubEnv("RX_SUBSCRIPTION_URL", "https://subscription.test");
    vi.stubEnv("RX_SUBSCRIPTION_ENVIRONMENT", "sandbox");
    vi.stubEnv("RX_SUBSCRIPTION_API_KEY", "rxs_sandbox_test-secret");
    vi.stubEnv("RX_SUBSCRIPTION_PUBLISHABLE_KEY", "rxs_pk_sandbox_test-public");
    // An allowance that is used up: anything metered would be refused.
    const usage = vi.fn(async () => Response.json({ allowed: false }, { status: 402 }));
    vi.stubGlobal("fetch", usage);
    const { key, apiKey } = await createKey();

    const added = await callTool(key, "add_summary", CHIP);
    expect(added.isError).toBeFalsy();
    const trip = await callTool(key, "create_trip", { document: {
      title: "Weekend in Kyoto", startDate: "2027-04-03", endDate: "2027-04-04", timeZone: "Asia/Tokyo", currency: "JPY",
      places: [{ id: "kyoto", name: "Kyoto", kind: "city", coordinate: { lat: 35.0116, lng: 135.7681 } }],
      days: [{ id: "day-1", date: "2027-04-03", title: "Temples" }],
    } });
    expect(trip.isError).toBeFalsy();
    expect(usage).not.toHaveBeenCalled();
    const [row] = await env.handle.db.select().from(apiKeys).where(eq(apiKeys.id, apiKey.id));
    expect(row.summariesAddedCount).toBe(1);

    // The import API is still metered.
    const imported = await importRoute.POST(apiRequest("POST", "/api/v1/summaries/import", {
      token: env.tokens.alice, body: { ...CHIP, highlights: CHIP.keyPoints, keyPoints: undefined, title: "Other", allowDuplicate: true },
    }));
    expect(imported.status).toBe(402);
    expect(usage).toHaveBeenCalledTimes(1);
  });

  it("reports a duplicate as a tool error naming the existing chip", async () => {
    const { key, apiKey } = await createKey();
    await callTool(key, "add_summary", CHIP);
    const result = await callTool(key, "add_summary", { ...CHIP, sourceUrl: undefined });
    expect(result.isError).toBe(true);
    expect(result.content[0].text).toMatch(/^Not added: this chip is already in the library as "Monarch migration" \(https?:\/\/.+\)\. Reason: .+ allowDuplicate: true/);

    const again = await callTool(key, "add_summary", { ...CHIP, allowDuplicate: true });
    expect(again.isError).toBeFalsy();
    const [row] = await env.handle.db.select().from(apiKeys).where(eq(apiKeys.id, apiKey.id));
    expect(row).toMatchObject({ toolCallCount: 3, summariesAddedCount: 2 });
  });

  it("validates arguments with the import API's limits", async () => {
    const { key } = await createKey();
    const tooMany = await callTool(key, "add_summary", { ...CHIP, keyPoints: ["1", "2", "3", "4", "5", "6"] });
    expect(tooMany.isError).toBe(true);
    expect(tooMany.content[0].text).toMatch(/^Invalid keyPoints: /);
    const badTtl = await callTool(key, "add_summary", { ...CHIP, ttlDays: 5 });
    expect(badTtl.isError).toBe(true);
    const missing = await callTool(key, "add_summary", { title: "No text" });
    expect(missing.isError).toBe(true);
  });

  it("updates only the owner's chip, keeping fields it isn't given", async () => {
    const { key } = await createKey();
    const added = await callTool(key, "add_summary", CHIP);
    const id = (added.structuredContent as { summary: { id: string } }).summary.id;

    const result = await callTool(key, "update_summary", {
      summaryId: id, summary: "Monarchs migrate up to 4,000 km to Mexico.", keyPoints: ["Up to 4,000 km", "They winter in Mexico"],
      tags: ["Monarchs"], category: "World", visibility: "private",
    });
    expect(result.isError).toBeFalsy();
    expect(result.content[0].text).toContain("Updated \"Monarch migration\" (private).");
    expect((result.structuredContent as { summary: Record<string, unknown> }).summary).toMatchObject({
      id, title: CHIP.title, summary: "Monarchs migrate up to 4,000 km to Mexico.",
      keyPoints: ["Up to 4,000 km", "They winter in Mexico"], tags: ["monarchs"], category: "World", visibility: "private",
    });
    const listed = await callTool(key, "list_summaries", { tag: "monarchs" });
    expect(listed.structuredContent).toMatchObject({ count: 1, items: [{ id, category: "World" }] });

    const empty = await callTool(key, "update_summary", { summaryId: id });
    expect(empty.isError).toBe(true);
    const tooMany = await callTool(key, "update_summary", { summaryId: id, keyPoints: ["1", "2", "3", "4", "5", "6"] });
    expect(tooMany.content[0].text).toMatch(/^Invalid keyPoints: /);

    const before = await coverOf(id);
    expect(before.ogImageKey).toBeTruthy();
    await callTool(key, "update_summary", { summaryId: id, title: "Monarchs head to Mexico", category: "Science", visibility: "public" });
    // Edits never redesign the cover (going private above only moved it to fresh keys).
    expect({ ...(await coverOf(id)), ogImageKey: undefined, artImageKey: undefined }).toEqual({ ...before, ogImageKey: undefined, artImageKey: undefined });

    const bob = await createKey("Bob", env.tokens.bob);
    const bobUpdate = await callTool(bob.key, "update_summary", { summaryId: id, title: "Mine now" });
    expect(bobUpdate.isError).toBe(true);
  });

  it("lists and searches the library with filters and cursors", async () => {
    const { key } = await createKey();
    await callTool(key, "add_summary", CHIP);
    await callTool(key, "add_summary", { title: "Rust ownership", summary: "Borrowing rules explained.", text: "The borrow checker enforces aliasing rules.", tags: ["rust"], category: "Technology", sourceUrl: "https://github.com/rust-lang/book" });

    const all = await callTool(key, "list_summaries", { limit: 1 });
    expect(all.structuredContent).toMatchObject({ count: 1, items: [{ title: "Rust ownership", source: "github" }] });
    const next = await callTool(key, "list_summaries", { limit: 1, cursor: (all.structuredContent as { nextCursor: string }).nextCursor });
    expect(next.structuredContent).toMatchObject({ count: 1, items: [{ title: "Monarch migration" }], nextCursor: null });

    const tagged = await callTool(key, "list_summaries", { tag: "Rust" });
    expect(tagged.structuredContent).toMatchObject({ count: 1, items: [{ title: "Rust ownership" }] });
    const science = await callTool(key, "list_summaries", { category: "Science", scope: "mine" });
    expect(science.structuredContent).toMatchObject({ count: 1, items: [{ title: "Monarch migration" }] });

    const search = await callTool(key, "search_summaries", { query: "butterflies", limit: 5 });
    expect(search.isError).toBeFalsy();
    expect((search.structuredContent as { items: { title: string }[] }).items[0].title).toBe("Monarch migration");

    const github = await callTool(key, "search_summaries", { query: "borrow checker", source: "github" });
    expect((github.structuredContent as { items: { title: string }[] }).items.map((item) => item.title)).toEqual(["Rust ownership"]);
  });
});

describe("/api/mcp trip tools", () => {
  const TRIP = {
    title: "Hokkaido in winter",
    startDate: "2027-02-01",
    endDate: "2027-02-04",
    timeZone: "Asia/Tokyo",
    currency: "JPY",
    places: [{ id: "sapporo", name: "Sapporo", kind: "city", coordinate: { lat: 43.0618, lng: 141.3545 }, major: true }],
    days: [{ id: "day-1", date: "2027-02-01", title: "Snow festival" }],
  };

  it("creates, reads, lists and edits trips", async () => {
    const { key } = await createKey();
    const created = await callTool(key, "create_trip", { document: TRIP });
    expect(created.isError).toBeFalsy();
    expect(created.content[0].text).toContain("Created trip \"Hokkaido in winter\" (private).");
    const trip = (created.structuredContent as { trip: { id: string; revision: number } }).trip;
    expect(trip.revision).toBe(0);

    const listed = await callTool(key, "list_trips", {});
    expect(listed.structuredContent).toMatchObject({ count: 1, trips: [{ id: trip.id, title: "Hokkaido in winter", dayCount: 1, placeCount: 1 }] });

    const updated = await callTool(key, "update_trip", {
      tripId: trip.id,
      revision: 0,
      operations: [
        { op: "upsert_place", place: { id: "otaru", name: "Otaru", kind: "city", coordinate: { lat: 43.1907, lng: 140.9947 } } },
        { op: "upsert_transport", transport: {
          id: "feb02-otaru", date: "2027-02-02", label: "Sapporo → Otaru", status: "booked", options: [{
            id: "rapid-airport", label: "Rapid Airport", departure: "2027-02-02T09:30", arrival: "2027-02-02T10:02",
            segments: [{ mode: "train", fromPlaceId: "sapporo", toPlaceId: "otaru", fromName: "Sapporo", toName: "Otaru", train: { name: "Rapid Airport", number: "3870M", category: "rapid" } }],
          }],
        } },
        { op: "upsert_day", day: { id: "day-2", date: "2027-02-02", title: "Otaru canal", transportIds: ["feb02-otaru"] } },
      ],
    });
    expect(updated.isError).toBeFalsy();
    expect(updated.content[0].text).toBe("Updated \"Hokkaido in winter\" (revision 1).");

    const read = await callTool(key, "get_trip", { tripId: trip.id });
    const document = (read.structuredContent as { trip: { revision: number; document: { days: { id: string }[]; transports: { options: { segments: { train: { category: string } }[] }[] }[] } } }).trip;
    expect(document.revision).toBe(1);
    expect(document.document.days.map((day) => day.id)).toEqual(["day-1", "day-2"]);
    expect(document.document.transports[0].options[0].segments[0].train.category).toBe("rapid");

    const withView = await callTool(key, "update_trip", {
      tripId: trip.id,
      operations: [{ op: "upsert_view", view: { id: "pass-vs-ic", title: "Pass vs IC", dayId: "day-2", spec: { root: "root", elements: {
        root: { type: "Card", props: { title: "Rail budget" }, children: ["fares"] },
        fares: { type: "BarChart", props: { format: "money", items: [{ label: "Pass", value: 40000 }, { label: "IC", value: 35420 }] } },
      } } } }],
    });
    expect(withView.isError).toBeFalsy();
    expect((withView.structuredContent as { trip: { document: TripDocument } }).trip.document.views).toMatchObject([{ id: "pass-vs-ic", dayId: "day-2" }]);
    const badView = await callTool(key, "update_trip", {
      tripId: trip.id,
      operations: [{ op: "upsert_view", view: { id: "broken", title: "Broken", spec: { root: "root", elements: { root: { type: "Stack", children: ["missing"] } } } } }],
    });
    expect(badView.isError).toBe(true);
    expect(badView.content[0].text).toContain('unknown element "missing"');

    const stale = await callTool(key, "update_trip", { tripId: trip.id, revision: 0, operations: [{ op: "delete", collection: "days", id: "day-2" }] });
    expect(stale.isError).toBe(true);
    expect(stale.content[0].text).toContain("TRIP_REVISION_CONFLICT");

    // Trips are library items too.
    await callTool(key, "add_summary", CHIP);
    const trips = await callTool(key, "list_summaries", { kind: "trip" });
    expect(trips.structuredContent).toMatchObject({ count: 1, items: [{ id: trip.id }] });
  });

  it("keeps the trip's cover when the trip is edited", async () => {
    const { key } = await createKey();
    const tripId = ((await callTool(key, "create_trip", { document: TRIP })).structuredContent as { trip: { id: string } }).trip.id;
    const before = await coverOf(tripId);
    expect(before.ogImageKey).toBeTruthy();

    const renamed = await callTool(key, "update_trip", { tripId, operations: [
      { op: "set_meta", meta: { title: "Hokkaido snow and onsen" } },
      { op: "upsert_day", day: { id: "day-2", date: "2027-02-02", title: "Otaru canal" } },
    ] });
    expect(renamed.isError).toBeFalsy();
    const placed = await callTool(key, "update_place", { tripId, placeId: "sapporo", changes: { description: "Hokkaido's capital." } });
    expect(placed.isError).toBeFalsy();

    const [row] = await env.handle.db.select({ title: summaries.title }).from(summaries).where(eq(summaries.id, tripId));
    expect(row.title).toBe("Hokkaido snow and onsen");
    expect(await coverOf(tripId)).toEqual(before);
  });

  it("lays out alternative routes and records the user's pick", async () => {
    const { key } = await createKey();
    const tripId = ((await callTool(key, "create_trip", { document: TRIP })).structuredContent as { trip: { id: string } }).trip.id;
    const planned = await callTool(key, "update_trip", {
      tripId,
      operations: [
        { op: "upsert_place", place: { id: "otaru", name: "Otaru", kind: "city", coordinate: { lat: 43.1907, lng: 140.9947 } } },
        { op: "upsert_place", place: { id: "jozankei", name: "Jozankei", kind: "city", coordinate: { lat: 42.9673, lng: 141.1617 } } },
        { op: "upsert_plan", plan: { id: "day-2-plan", title: "Day 2", scope: "day", date: "2027-02-02", options: [
          { id: "route-otaru", label: "Route 1 · Otaru canal" },
          { id: "route-onsen", label: "Route 2 · Jozankei onsen", summary: "A night at a hot spring" },
        ] } },
        { op: "upsert_day", day: { id: "day-2-otaru", date: "2027-02-02", title: "Otaru canal", planOptionId: "route-otaru", route: { kind: "side", placeIds: ["sapporo", "otaru"] } } },
        { op: "upsert_day", day: { id: "day-2-onsen", date: "2027-02-02", title: "Jozankei", planOptionId: "route-onsen", route: { kind: "side", placeIds: ["sapporo", "jozankei"] } } },
      ],
    });
    expect(planned.isError).toBeFalsy();

    const chosen = await callTool(key, "choose_plan_option", { tripId, planId: "day-2-plan", optionId: "route-onsen" });
    expect(chosen.isError).toBeFalsy();
    expect(chosen.structuredContent).toEqual({ planSelections: { "day-2-plan": "route-onsen" } });
    const read = (await callTool(key, "get_trip", { tripId })).structuredContent as { trip: { revision: number; planSelections: Record<string, string> } };
    expect(read.trip).toMatchObject({ revision: 1, planSelections: { "day-2-plan": "route-onsen" } });

    const unknown = await callTool(key, "choose_plan_option", { tripId, planId: "day-2-plan", optionId: "route-9" });
    expect(unknown.isError).toBe(true);

    const resolved = await callTool(key, "update_trip", { tripId, operations: [{ op: "resolve_plan", id: "day-2-plan", optionId: "route-onsen" }] });
    const document = (resolved.structuredContent as { trip: { document: TripDocument } }).trip.document;
    expect(document.plans).toEqual([]);
    expect(document.days.map((day) => day.id)).toEqual(["day-1", "day-2-onsen"]);
  });

  it("turns a completed presigned image upload into a lasting trip photo", async () => {
    const { key } = await createKey();
    const tripId = ((await callTool(key, "create_trip", { document: TRIP })).structuredContent as { trip: { id: string } }).trip.id;
    const png = await sharp({ create: { width: 60, height: 30, channels: 3, background: "#3366cc" } }).png().toBuffer();
    const prepared = await callTool(key, "create_upload", { filename: "sapporo.png", mimeType: "image/png", byteSize: png.length });
    const uploadKey = (prepared.structuredContent as { key: string }).key;
    const early = await callTool(key, "upload_trip_image", { tripId, uploadKey });
    expect(early.isError).toBe(true);
    expect(early.content[0].text).toContain("UPLOAD_INCOMPLETE");
    await env.store.put(uploadKey, { bytes: png, contentType: "image/png" });
    const uploaded = await callTool(key, "upload_trip_image", { tripId, uploadKey });
    expect(uploaded.isError).toBeFalsy();
    const image = (uploaded.structuredContent as { image: { url: string; width: number; height: number } }).image;
    expect(image).toMatchObject({ width: 60, height: 30 });
    const file = image.url.split("/api/public/trip-images/")[1];
    const served = await tripImageRoute.GET(apiRequest("GET", `/api/public/trip-images/${file}`), params({ file }));
    expect(served.status).toBe(200);
    expect(served.headers.get("content-type")).toBe("image/jpeg");
    const patched = await callTool(key, "update_place", { tripId, placeId: "sapporo", addPhotos: [{ url: image.url }] });
    expect(patched.structuredContent).toMatchObject({ place: { photos: [{ url: image.url }] } });

    const get = vi.spyOn(env.store, "get");
    const bob = await createKey("Bob", env.tokens.bob);
    const bobTrip = ((await callTool(bob.key, "create_trip", { document: TRIP })).structuredContent as { trip: { id: string } }).trip.id;
    const foreign = await callTool(bob.key, "upload_trip_image", { tripId: bobTrip, uploadKey });
    expect(foreign.content[0].text).toContain("UPLOAD_FORBIDDEN");
    expect(get).not.toHaveBeenCalled();
    expect((await callTool(key, "upload_trip_image", { tripId, uploadKey, data: png.toString("base64") })).isError).toBe(true);
    expect((await callTool(key, "upload_trip_image", { tripId, uploadKey, url: "https://example.com/photo.png" })).isError).toBe(true);

    const invalid = await callTool(key, "create_upload", { filename: "fake.png", mimeType: "image/png", byteSize: 12 });
    const invalidKey = (invalid.structuredContent as { key: string }).key;
    await env.store.put(invalidKey, { bytes: new TextEncoder().encode("not an image"), contentType: "image/png" });
    expect((await callTool(key, "upload_trip_image", { tripId, uploadKey: invalidKey })).content[0].text).toContain("IMAGE_INVALID");
    const large = await callTool(key, "create_upload", { filename: "large.png", mimeType: "image/png", byteSize: 15 * 1024 * 1024 + 1 });
    const largeKey = (large.structuredContent as { key: string }).key;
    expect((await callTool(key, "upload_trip_image", { tripId, uploadKey: largeKey })).content[0].text).toContain("UPLOAD_TOO_LARGE");
  });

  it("uploads photos and patches a place's details", async () => {
    const { key } = await createKey();
    const tripId = ((await callTool(key, "create_trip", { document: TRIP })).structuredContent as { trip: { id: string } }).trip.id;
    // A 3000×1500 PNG comes back as a JPEG of at most 2048 px.
    const png = await sharp({ create: { width: 3000, height: 1500, channels: 3, background: "#3366cc" } }).png().toBuffer();
    const uploaded = await callTool(key, "upload_trip_image", { tripId, data: png.toString("base64") });
    expect(uploaded.isError).toBeFalsy();
    const image = (uploaded.structuredContent as { image: { url: string; width: number; height: number } }).image;
    expect(image).toMatchObject({ width: 2048, height: 1024 });
    const file = image.url.split("/api/public/trip-images/")[1];
    expect(file).toMatch(/^.+-\d+-[0-9a-f]{16}\.jpg$/);
    const served = await tripImageRoute.GET(apiRequest("GET", `/api/public/trip-images/${file}`), { params: Promise.resolve({ file }) });
    expect(served.status).toBe(200);
    expect(served.headers.get("content-type")).toBe("image/jpeg");
    expect((await sharp(new Uint8Array(await served.arrayBuffer())).metadata()).format).toBe("jpeg");
    const guessed = await tripImageRoute.GET(apiRequest("GET", "/api/public/trip-images/x.jpg"), { params: Promise.resolve({ file: "../og/x.png" }) });
    expect(guessed.status).toBe(404);

    // From a URL, through the SSRF-checked fetch.
    vi.stubGlobal("fetch", vi.fn(async () => new Response(new Uint8Array(png), { headers: { "content-type": "image/png" } })));
    const copied = await callTool(key, "upload_trip_image", { tripId, url: "https://example.com/sapporo.png" });
    expect(copied.isError).toBeFalsy();
    vi.stubGlobal("fetch", vi.fn(async () => new Response("<html></html>", { headers: { "content-type": "text/html" } })));
    const notImage = await callTool(key, "upload_trip_image", { tripId, url: "https://example.com/page" });
    expect(notImage.isError).toBe(true);
    expect((await callTool(key, "upload_trip_image", { tripId, data: Buffer.from("not an image").toString("base64") })).isError).toBe(true);
    expect((await callTool(key, "upload_trip_image", { tripId })).isError).toBe(true);
    const bob = await createKey("Bob", env.tokens.bob);
    expect((await callTool(bob.key, "upload_trip_image", { tripId, data: png.toString("base64") })).isError).toBe(true);

    const updated = await callTool(key, "update_place", {
      tripId,
      placeId: "sapporo",
      changes: { description: "Hokkaido's capital, home of the Snow Festival.", hours: "Open all day", pricing: [{ label: "Odori Park", note: "Free entry" }] },
      addPhotos: [{ url: image.url, caption: "Odori Park", credit: "Photo: Chippy" }],
    });
    expect(updated.isError).toBeFalsy();
    expect(updated.structuredContent).toMatchObject({
      revision: 1,
      place: { id: "sapporo", name: "Sapporo", major: true, kind: "city", hours: "Open all day", photos: [{ url: image.url, caption: "Odori Park" }], pricing: [{ label: "Odori Park" }] },
    });
    // Photos are appended once; other fields stay.
    const again = await callTool(key, "update_place", { tripId, placeId: "sapporo", changes: { hours: null }, addPhotos: [{ url: image.url }] });
    expect(again.structuredContent).toMatchObject({ place: { hours: null, description: "Hokkaido's capital, home of the Snow Festival.", photos: [{ url: image.url }] } });
    expect((again.structuredContent as { place: { photos: unknown[] } }).place.photos).toHaveLength(1);
    const unknown = await callTool(key, "update_place", { tripId, placeId: "nowhere", changes: { hours: "x" } });
    expect(unknown.isError).toBe(true);
    expect(unknown.content[0].text).toContain("sapporo");
    const insecure = await callTool(key, "update_place", { tripId, placeId: "sapporo", addPhotos: [{ url: "http://example.com/a.jpg" }] });
    expect(insecure.isError).toBe(true);
  });

  it("adds a shared source to a trip with the trip agent", async () => {
    const { key } = await createKey();
    const created = await callTool(key, "create_trip", { document: TRIP });
    const tripId = (created.structuredContent as { trip: { id: string } }).trip.id;
    const result = await callTool(key, "add_to_trip_from_source", { tripId, text: "Ryokan notes: bring cash for the onsen, check-in after 15:00.", instructions: "Keep it as a note" });
    expect(result.isError).toBeFalsy();
    expect(result.structuredContent).toMatchObject({ operationsApplied: 1, trip: { revision: 1, document: { notes: [{ id: "note-1" }] } } });
    expect(env.ai.calls.updateTrip[0]).toMatchObject({ instructions: "Keep it as a note" });

    const neither = await callTool(key, "add_to_trip_from_source", { tripId });
    expect(neither.isError).toBe(true);
    const bob = await createKey("Bob", env.tokens.bob);
    const foreign = await callTool(bob.key, "get_trip", { tripId });
    expect(foreign.isError).toBe(true);
    expect(foreign.content[0].text).toContain("NOT_FOUND");
  });
});
