import { eq } from "drizzle-orm";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as summariesRoute from "@/app/api/v1/summaries/route";
import * as summaryRoute from "@/app/api/v1/summaries/[id]/route";
import * as versionsRoute from "@/app/api/v1/summaries/[id]/versions/route";
import * as versionRoute from "@/app/api/v1/summaries/[id]/versions/[version]/route";
import * as restoreRoute from "@/app/api/v1/summaries/[id]/versions/[version]/restore/route";
import * as tripsRoute from "@/app/api/v1/trips/route";
import * as tripRoute from "@/app/api/v1/trips/[id]/route";
import * as operationsRoute from "@/app/api/v1/trips/[id]/operations/route";
import type { TripDocument } from "@/lib/contracts/trip";
import { documentVersions } from "@/lib/db/schema";
import { MAX_DOCUMENT_VERSIONS, summaryContent, versionStatements } from "@/lib/services/document-versions";
import { applyChatOperations, type TripJson } from "@/lib/services/trips";
import type { VersionDetailJson, VersionJson } from "@/lib/services/versions";
import { apiRequest, params, setupTestEnv, type TestEnv } from "../helpers/setup";

const { sendPush, apnsConfigured } = vi.hoisted(() => ({ sendPush: vi.fn(), apnsConfigured: vi.fn() }));
vi.mock("@/lib/notifications/apns", () => ({ sendPush, apnsConfigured }));

let env: TestEnv;

beforeEach(async () => {
  env = await setupTestEnv();
  vi.stubEnv("SUMMARY_OG_REMOTE_ASSETS", "false");
  sendPush.mockReset().mockResolvedValue({ status: 200 });
  apnsConfigured.mockReset().mockReturnValue(false);
});

afterEach(() => {
  env.teardown();
  vi.unstubAllEnvs();
});

async function createSummary(token = env.tokens.alice) {
  const response = await summariesRoute.POST(apiRequest("POST", "/api/v1/summaries", {
    token,
    body: { source: { type: "text", text: "Researchers built a quantum widget that entangles gears across the lab." }, followLinks: false },
  }));
  expect(response.status).toBe(201);
  return response.json();
}

function patch(id: string, body: unknown, token = env.tokens.alice) {
  return summaryRoute.PATCH(apiRequest("PATCH", `/api/v1/summaries/${id}`, { token, body }), params({ id }));
}

async function versions(id: string, token = env.tokens.alice, query = ""): Promise<{ items: VersionJson[]; nextCursor: string | null }> {
  const response = await versionsRoute.GET(apiRequest("GET", `/api/v1/summaries/${id}/versions${query}`, { token }), params({ id }));
  expect(response.status).toBe(200);
  return response.json();
}

function version(id: string, number: number | string, token = env.tokens.alice) {
  return versionRoute.GET(apiRequest("GET", `/api/v1/summaries/${id}/versions/${number}`, { token }), params({ id, version: String(number) }));
}

function restore(id: string, number: number, token = env.tokens.alice) {
  return restoreRoute.POST(apiRequest("POST", `/api/v1/summaries/${id}/versions/${number}/restore`, { token }), params({ id, version: String(number) }));
}

function tripDoc(title = "Lisbon long weekend"): Partial<TripDocument> {
  return {
    title,
    startDate: "2026-11-06",
    endDate: "2026-11-09",
    timeZone: "Europe/Lisbon",
    currency: "EUR",
    places: [{ id: "lisbon", name: "Lisbon", kind: "city", coordinate: { lat: 38.7223, lng: -9.1393 }, major: true, address: null, note: null, photos: [], pricing: [] }],
    days: [{ id: "day-1", date: "2026-11-06", title: "Alfama at dusk", highlight: false, moments: [], transportIds: [], route: null, stayId: null }],
  };
}

async function createTrip(): Promise<TripJson> {
  const response = await tripsRoute.POST(apiRequest("POST", "/api/v1/trips", { token: env.tokens.alice, body: { document: tripDoc() } }));
  expect(response.status).toBe(201);
  return (await response.json()).trip;
}

describe("summary versions", () => {
  it("saves a version per text edit, not per sharing change, and restores one as a new version", async () => {
    const chip = await createSummary();
    expect((await versions(chip.id)).items).toMatchObject([{ version: 1, kind: "summary", actor: "owner", title: chip.title, isCurrent: true }]);

    expect((await patch(chip.id, { visibility: "private" })).status).toBe(200);
    expect((await versions(chip.id)).items).toHaveLength(1);

    expect((await patch(chip.id, { title: "Gears, entangled", highlights: ["One", "Two"], tags: ["physics"] })).status).toBe(200);
    const listed = await versions(chip.id);
    expect(listed.items.map((item) => [item.version, item.title, item.isCurrent])).toEqual([[2, "Gears, entangled", true], [1, chip.title, false]]);

    const first: VersionDetailJson = await (await version(chip.id, 1)).json();
    expect(first.content).toEqual({ title: chip.title, summary: chip.summary, highlights: chip.highlights, category: chip.category, tags: chip.tags, keywords: expect.any(Array) });

    const restored = await restore(chip.id, 1);
    expect(restored.status).toBe(200);
    const body = await restored.json();
    expect(body.trip).toBeNull();
    expect(body.summary).toMatchObject({ title: chip.title, highlights: chip.highlights, tags: chip.tags, visibility: "private" });
    expect(body.version).toMatchObject({ version: 3, actor: "restore", restoredFrom: 1, isCurrent: true });

    // Restoring what is already there adds nothing.
    expect((await (await restore(chip.id, 3)).json()).version).toBeNull();
    expect((await versions(chip.id)).items).toHaveLength(3);
  });

  it("is the owner's only, and 404s unknown versions", async () => {
    const chip = await createSummary();
    expect((await versionsRoute.GET(apiRequest("GET", `/api/v1/summaries/${chip.id}/versions`, { token: env.tokens.bob }), params({ id: chip.id }))).status).toBe(403);
    expect((await restore(chip.id, 1, env.tokens.bob)).status).toBe(403);
    expect((await version(chip.id, 9)).status).toBe(404);
    expect((await version(chip.id, "abc")).status).toBe(404);
  });

  it("pages newest first and keeps only the latest versions", async () => {
    const chip = await createSummary();
    const item = { id: chip.id, kind: "summary" as const };
    for (let index = 0; index < MAX_DOCUMENT_VERSIONS + 4; index += 1) {
      await env.handle.db.batch([...versionStatements(env.handle.db, item, summaryContent({ ...chip, title: `Title ${index}` }), { at: new Date() })]);
    }
    const rows = await env.handle.db.select({ version: documentVersions.version }).from(documentVersions).where(eq(documentVersions.summaryId, chip.id));
    expect(rows).toHaveLength(MAX_DOCUMENT_VERSIONS);
    expect(Math.min(...rows.map((row) => row.version))).toBe(6);

    const page = await versions(chip.id, env.tokens.alice, "?limit=2");
    expect(page.items.map((row) => row.version)).toEqual([105, 104]);
    const next = await versions(chip.id, env.tokens.alice, `?limit=2&cursor=${page.nextCursor}`);
    expect(next.items.map((row) => row.version)).toEqual([103, 102]);
  });

  it("goes when the summary is deleted", async () => {
    const chip = await createSummary();
    const deleted = await summaryRoute.DELETE(apiRequest("DELETE", `/api/v1/summaries/${chip.id}`, { token: env.tokens.alice }), params({ id: chip.id }));
    expect(deleted.status).toBe(204);
    expect(await env.handle.db.select().from(documentVersions)).toHaveLength(0);
  });
});

describe("trip versions", () => {
  it("records each save with who made it, skips refused saves, and restores a document", async () => {
    const trip = await createTrip();
    const put = await tripRoute.PUT(apiRequest("PUT", `/api/v1/trips/${trip.id}`, {
      token: env.tokens.alice,
      body: { revision: 0, document: { ...trip.document, title: "Lisbon and Sintra" } },
    }), params({ id: trip.id }));
    expect(put.status).toBe(200);

    // A save over a stale revision is refused and leaves no version.
    const stale = await tripRoute.PUT(apiRequest("PUT", `/api/v1/trips/${trip.id}`, {
      token: env.tokens.alice,
      body: { revision: 0, document: { ...trip.document, title: "Lost edit" } },
    }), params({ id: trip.id }));
    expect(stale.status).toBe(409);

    await applyChatOperations(env.handle.db, "user-alice", trip.id, [{ op: "set_meta", meta: { intro: "Tiles and trams" } }], { keepValid: true });
    const ops = await operationsRoute.POST(apiRequest("POST", `/api/v1/trips/${trip.id}/operations`, {
      token: env.tokens.alice,
      body: { operations: [{ op: "set_meta", meta: { title: "Lisbon, Sintra and Cascais" } }] },
    }), params({ id: trip.id }));
    expect(ops.status).toBe(200);

    const listed = await versions(trip.id);
    expect(listed.items.map((item) => [item.version, item.actor, item.title])).toEqual([
      [4, "owner", "Lisbon, Sintra and Cascais"],
      [3, "chat", "Lisbon and Sintra"],
      [2, "owner", "Lisbon and Sintra"],
      [1, "owner", "Lisbon long weekend"],
    ]);
    const first: VersionDetailJson = await (await version(trip.id, 1)).json();
    expect((first.content as { document: TripDocument }).document).toMatchObject({ title: "Lisbon long weekend", views: [], plans: [] });

    const restored = await (await restore(trip.id, 1)).json();
    expect(restored.summary).toBeNull();
    expect(restored.trip).toMatchObject({ revision: 4, document: { title: "Lisbon long weekend" } });
    expect(restored.trip.document.intro ?? null).toBeNull();
    expect(restored.version).toMatchObject({ version: 5, actor: "restore", restoredFrom: 1, title: "Lisbon long weekend" });

    const fetched = await (await tripRoute.GET(apiRequest("GET", `/api/v1/trips/${trip.id}`, { token: env.tokens.alice }), params({ id: trip.id }))).json();
    expect(fetched.trip ?? fetched).toMatchObject({ revision: 4 });
  });
});
