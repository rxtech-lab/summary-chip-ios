import { eq } from "drizzle-orm";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as deletionRoute from "@/app/api/v1/account/deletion/route";
import * as cronRoute from "@/app/api/cron/account-deletion/route";
import * as privacyRoute from "@/app/api/v1/legal/privacy/route";
import * as summariesRoute from "@/app/api/v1/summaries/route";
import * as viewsRoute from "@/app/api/v1/views/route";
import { summaries, summaryViews, users } from "@/lib/db/schema";
import { sweepOverdueAccountDeletions } from "@/lib/services/account-deletion";
import { apiRequest, setupTestEnv, type TestEnv } from "../helpers/setup";

let env: TestEnv;
let idpCalls: { method: string; authorization: string | null }[];
const IDP_DEADLINE = Math.floor(Date.UTC(2026, 9, 8, 12) / 1000);

beforeEach(async () => {
  env = await setupTestEnv();
  idpCalls = [];
  vi.stubEnv("AUTH_ISSUER", "https://auth.test.example");
  vi.stubGlobal("fetch", vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    expect(String(input)).toBe("https://auth.test.example/api/oauth/account-deletion");
    const method = init?.method ?? "GET";
    idpCalls.push({ method, authorization: new Headers(init?.headers).get("authorization") });
    const pending = method === "POST";
    return Response.json({
      deletion_pending: pending,
      deletion_scheduled_at: pending ? IDP_DEADLINE : null,
      deletion_requested_at: pending ? IDP_DEADLINE - 7 * 86400 : null,
    });
  }));
});

afterEach(() => {
  vi.unstubAllGlobals();
  vi.unstubAllEnvs();
  env.teardown();
});

async function createText(token: string, title: string) {
  const response = await summariesRoute.POST(apiRequest("POST", "/api/v1/summaries", {
    token,
    body: { source: { type: "text", text: `${title} is a long enough piece of text to summarise for the test suite.`, title } },
  }));
  expect(response.status).toBe(201);
  return response.json();
}

describe("account deletion", () => {
  it("schedules with the identity provider's deadline, idempotently, and cancels", async () => {
    const empty = await deletionRoute.GET(apiRequest("GET", "/api/v1/account/deletion", { token: env.tokens.alice }));
    expect(await empty.json()).toEqual({ pendingDeletion: false, deletionScheduledAt: null, deletionRequestedAt: null });

    const scheduled = await deletionRoute.POST(apiRequest("POST", "/api/v1/account/deletion", { token: env.tokens.alice }));
    expect(scheduled.status).toBe(200);
    const body = await scheduled.json();
    expect(body).toMatchObject({ pendingDeletion: true, deletionScheduledAt: new Date(IDP_DEADLINE * 1000).toISOString() });
    expect(idpCalls[0]).toEqual({ method: "POST", authorization: `Bearer ${env.tokens.alice}` });

    const again = await deletionRoute.POST(apiRequest("POST", "/api/v1/account/deletion", { token: env.tokens.alice }));
    expect(await again.json()).toEqual(body);

    const cancelled = await deletionRoute.DELETE(apiRequest("DELETE", "/api/v1/account/deletion", { token: env.tokens.alice }));
    expect(await cancelled.json()).toMatchObject({ pendingDeletion: false });
    expect(idpCalls.at(-1)?.method).toBe("DELETE");
  });

  it("reports a missing write:profile scope specifically", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response("insufficient_scope", { status: 403 })));
    const response = await deletionRoute.POST(apiRequest("POST", "/api/v1/account/deletion", { token: env.tokens.alice }));
    expect(response.status).toBe(403);
    expect((await response.json()).error.code).toBe("ACCOUNT_DELETION_SCOPE_REQUIRED");
  });

  it("purges only overdue accounts, including their summaries and views", async () => {
    const mine = await createText(env.tokens.alice, "Alice notes");
    const theirs = await createText(env.tokens.bob, "Bob notes");
    await viewsRoute.POST(apiRequest("POST", "/api/v1/views", { token: env.tokens.alice, body: { slug: theirs.slug } }));
    await viewsRoute.POST(apiRequest("POST", "/api/v1/views", { token: env.tokens.bob, body: { slug: mine.slug } }));
    await deletionRoute.POST(apiRequest("POST", "/api/v1/account/deletion", { token: env.tokens.alice }));
    const db = env.handle.db;

    const early = await sweepOverdueAccountDeletions(db, { store: env.store, now: new Date((IDP_DEADLINE - 60) * 1000) });
    expect(early.deletedAccounts).toBe(0);

    const report = await sweepOverdueAccountDeletions(db, { store: env.store, now: new Date((IDP_DEADLINE + 3600) * 1000) });
    expect(report).toMatchObject({ deletedAccounts: 1, deletedSummaries: 1 });
    expect(await db.select().from(users).where(eq(users.id, "user-alice"))).toHaveLength(0);
    expect(await db.select().from(summaries).where(eq(summaries.id, mine.id))).toHaveLength(0);
    expect(await db.select().from(summaries).where(eq(summaries.id, theirs.id))).toHaveLength(1);
    expect(await db.select().from(summaryViews)).toHaveLength(0);
  });

  it("requires the cron secret", async () => {
    vi.stubEnv("CRON_SECRET", "secret");
    const response = await cronRoute.GET(new Request("http://localhost/api/cron/account-deletion"));
    expect(response.status).toBe(401);
  });
});

describe("legal documents", () => {
  it("serves markdown", async () => {
    const response = privacyRoute.GET();
    expect(response.headers.get("content-type")).toContain("text/markdown");
    expect(await response.text()).toContain("# Privacy Policy");
  });
});
