import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as billingRoute from "@/app/api/v1/billing/route";
import * as chatRoute from "@/app/api/v1/chat/route";
import { pointsForCost, usageCostUsd } from "@/lib/subscription/chat-billing";
import * as summariesRoute from "@/app/api/v1/summaries/route";
import * as summaryRoute from "@/app/api/v1/summaries/[id]/route";
import * as publicRoute from "@/app/api/public/summaries/[slug]/route";
import { subscriptionConfig } from "@/lib/subscription/config";
import { consumeSummaryUsage } from "@/lib/subscription/usage";
import { eq } from "drizzle-orm";
import { summaries, summaryTranslations } from "@/lib/db/schema";
import { apiRequest, params, setupTestEnv, type TestEnv } from "../helpers/setup";

let env: TestEnv;
const source = { type: "text", text: "Solar panels on balconies are becoming popular in cities across Europe." };
beforeEach(async () => {
  env = await setupTestEnv();
  vi.stubEnv("SUMMARY_OG_REMOTE_ASSETS", "false");
  vi.stubEnv("RX_SUBSCRIPTION_URL", "https://subscription.test");
  vi.stubEnv("RX_SUBSCRIPTION_ENVIRONMENT", "sandbox");
  vi.stubEnv("RX_SUBSCRIPTION_API_KEY", "rxs_sandbox_test-secret");
  vi.stubEnv("RX_SUBSCRIPTION_PUBLISHABLE_KEY", "rxs_pk_sandbox_test-public");
  vi.stubEnv("RX_SUBSCRIPTION_SANDBOX_API_KEY", "");
  vi.stubEnv("RX_SUBSCRIPTION_PRODUCTION_API_KEY", "");
  vi.stubEnv("RX_SUBSCRIPTION_XCODE_API_KEY", "");
  vi.stubEnv("RX_SUBSCRIPTION_XCODE_PUBLISHABLE_KEY", "");
  vi.stubEnv("RX_SUBSCRIPTION_XCODE_USER_IDS", "");
});

describe("Xcode billing", () => {
  function enableXcode() {
    vi.stubEnv("RX_SUBSCRIPTION_XCODE_API_KEY", "rxs_xcode_test-secret");
    vi.stubEnv("RX_SUBSCRIPTION_XCODE_PUBLISHABLE_KEY", "rxs_pk_xcode_test-public");
    vi.stubEnv("RX_SUBSCRIPTION_PRODUCTION_API_KEY", "rxs_production_test-secret");
    vi.stubEnv("RX_SUBSCRIPTION_PRODUCTION_PUBLISHABLE_KEY", "rxs_pk_production_test-public");
  }
  function request(method: string, path: string, token = env.tokens.alice) {
    return apiRequest(method, path, { token, headers: { "x-storekit-environment": "xcode" }, ...(method === "POST" ? { body: { source } } : {}) });
  }
  it("routes the local storefront and usage to the matching Xcode keys", async () => {
    enableXcode();
    const response = await billingRoute.GET(request("GET", "/api/v1/billing"));
    expect(response.status).toBe(200);
    expect((await response.json()).publishableKey).toBe("rxs_pk_xcode_test-public");
    const fetch = vi.fn(async (_url: unknown, init?: RequestInit) => {
      expect(new Headers(init?.headers).get("x-api-key")).toBe("rxs_xcode_test-secret");
      expect(JSON.parse(init?.body as string).rxlabUserId).toBe("user-alice");
      return Response.json({ allowed: true });
    });
    vi.stubGlobal("fetch", fetch);
    expect((await summariesRoute.POST(request("POST", "/api/v1/summaries"))).status).toBe(201);
  });
  it("supports authorized testers on a deployed server and keeps ordinary requests in production", async () => {
    enableXcode();
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("RX_SUBSCRIPTION_XCODE_USER_IDS", " user-alice , user-other ");
    const response = await billingRoute.GET(request("GET", "/api/v1/billing"));
    expect(response.status).toBe(200);
    expect((await response.json()).publishableKey).toBe("rxs_pk_xcode_test-public");
    const ordinary = await billingRoute.GET(apiRequest("GET", "/api/v1/billing", { token: env.tokens.alice }));
    expect((await ordinary.json()).publishableKey).toBe("rxs_pk_production_test-public");
  });
  it("refuses non-testers before AI or metering on a deployed server", async () => {
    enableXcode();
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("RX_SUBSCRIPTION_XCODE_USER_IDS", "user-alice");
    const fetch = vi.fn(); vi.stubGlobal("fetch", fetch);
    expect((await billingRoute.GET(request("GET", "/api/v1/billing", env.tokens.bob))).status).toBe(403);
    expect((await summariesRoute.POST(request("POST", "/api/v1/summaries", env.tokens.bob))).status).toBe(403);
    expect(env.ai.calls.summarize).toHaveLength(0);
    expect(fetch).not.toHaveBeenCalled();
  });
  it("also gates a deployment configured entirely for Xcode", async () => {
    enableXcode();
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("RX_SUBSCRIPTION_ENVIRONMENT", "xcode");
    expect((await billingRoute.GET(apiRequest("GET", "/api/v1/billing", { token: env.tokens.alice }))).status).toBe(403);
    vi.stubEnv("RX_SUBSCRIPTION_XCODE_USER_IDS", "user-alice");
    expect((await billingRoute.GET(apiRequest("GET", "/api/v1/billing", { token: env.tokens.alice }))).status).toBe(200);
  });
  it("does not fall back to sandbox or production keys when Xcode keys are missing", async () => {
    expect((await billingRoute.GET(request("GET", "/api/v1/billing"))).status).toBe(503);
    expect((await summariesRoute.POST(request("POST", "/api/v1/summaries"))).status).toBe(503);
    expect(env.ai.calls.summarize).toHaveLength(0);
  });
  it("rejects an Xcode secret passed as the publishable key", async () => {
    enableXcode();
    vi.stubEnv("RX_SUBSCRIPTION_XCODE_PUBLISHABLE_KEY", "rxs_xcode_secret");
    expect((await billingRoute.GET(request("GET", "/api/v1/billing"))).status).toBe(503);
  });
});
afterEach(() => {
  env.teardown(); vi.unstubAllEnvs(); vi.unstubAllGlobals(); vi.restoreAllMocks();
});
function create(token = env.tokens.alice, body: unknown = { source }) {
  return summariesRoute.POST(apiRequest("POST", "/api/v1/summaries", { token, body }));
}

/** Answers summary metering with `usage`; the source document's points hold finds an empty balance. */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function usageService(usage: (body: any, init?: RequestInit) => Response | Promise<Response>) {
  const fetch = vi.fn(async (url: unknown, init?: RequestInit) => {
    const body = JSON.parse(init?.body as string);
    if (new URL(String(url)).pathname === "/api/v1/usage") return usage(body, init);
    return Response.json({ error: "insufficient_balance", available: 0, required: 1 }, { status: 409 });
  });
  vi.stubGlobal("fetch", fetch);
  return fetch;
}

describe("server-authorized summary usage", () => {
  it("accepts the remote free allowance, refuses exhaustion before AI, then accepts a top-up", async () => {
    let freeRemaining = 5; // Fixture policy only.
    let points = 0;
    const fetch = usageService((body, init) => {
      expect(body).toMatchObject({ rxlabUserId: "user-alice", item: "daily_summary_generation", amount: 1 });
      expect(body.idempotencyKey).toBe(`summary:${body.metadata.summaryId}`);
      expect(new Headers(init?.headers).get("x-api-key")).toBe("rxs_sandbox_test-secret");
      if (freeRemaining > 0) { freeRemaining--; return Response.json({ allowed: true }); }
      if (points > 0) { points--; return Response.json({ allowed: true, chargedUnits: 1 }); }
      return Response.json({ allowed: false, reason: "insufficient_balance" }, { status: 402 });
    });
    for (let i = 0; i < 5; i++) expect((await create()).status).toBe(201);
    expect((await create()).status).toBe(402);
    expect(env.ai.calls.summarize).toHaveLength(5);
    points = 2;
    expect((await create()).status).toBe(201);
    expect(points).toBe(1);
    expect(env.ai.calls.summarize).toHaveLength(6);
    const keys = fetch.mock.calls.filter(([url]) => String(url).endsWith("/api/v1/usage")).map(([, init]) => JSON.parse(init?.body as string).idempotencyKey);
    expect(new Set(keys).size).toBe(keys.length);
  });
  it("honors a changed remote policy without a local limit", async () => {
    const answers = [Response.json({ allowed: true }), Response.json({ allowed: false }, { status: 402 })];
    usageService(() => answers.shift()!);
    expect((await create()).status).toBe(201);
    const denied = await create();
    expect(denied.status).toBe(402);
    expect((await denied.json()).error.code).toBe("SUMMARY_ALLOWANCE_EXHAUSTED");
    expect(env.ai.calls.summarize).toHaveLength(1);
  });
  it.each([
    [404, { error: "unknown_usage_item" }, "SUMMARY_USAGE_NOT_CONFIGURED"],
    [500, {}, "SUMMARY_USAGE_UNAVAILABLE"],
    [200, {}, "SUMMARY_USAGE_UNAVAILABLE"],
  ])("fails closed for service status %s", async (status, body, code) => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(Response.json(body, { status })));
    const result = await create();
    expect(result.status).toBe(503);
    expect((await result.json()).error.code).toBe(code);
    expect(env.ai.calls.summarize).toHaveLength(0);
  });
  it("does not meter unauthenticated or invalid requests", async () => {
    const fetch = vi.fn(); vi.stubGlobal("fetch", fetch);
    expect((await create("")).status).toBe(401);
    expect((await create(env.tokens.alice, {})).status).toBe(400);
    expect(fetch).not.toHaveBeenCalled();
  });
  it("reports network failure without starting AI", async () => {
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new Error("offline")));
    expect((await create()).status).toBe(503);
    expect(env.ai.calls.summarize).toHaveLength(0);
  });
  it("rejects incomplete production configuration", () => {
    vi.stubEnv("RX_SUBSCRIPTION_URL", ""); vi.stubEnv("RX_SUBSCRIPTION_API_KEY", "");
    vi.stubEnv("NODE_ENV", "production");
    expect(() => subscriptionConfig()).toThrow();
    vi.stubEnv("NODE_ENV", "test");
    expect(() => subscriptionConfig()).toThrow(); // A publishable key alone is partial config.
    vi.stubEnv("RX_SUBSCRIPTION_ENVIRONMENT", "");
    vi.stubEnv("RX_SUBSCRIPTION_PUBLISHABLE_KEY", "");
    expect(subscriptionConfig()).toBeNull();
  });
  it("reuses the metering idempotency key for the same operation", async () => {
    const fetch = vi.fn().mockImplementation(async () => Response.json({ allowed: true }));
    vi.stubGlobal("fetch", fetch);
    await consumeSummaryUsage("user-alice", "summary-1");
    await consumeSummaryUsage("user-alice", "summary-1");
    expect(fetch.mock.calls.map(([, init]) => JSON.parse(init.body).idempotencyKey)).toEqual(["summary:summary-1", "summary:summary-1"]);
  });
});

describe("storefront configuration", () => {
  it("returns the matching publishable configuration after authentication", async () => {
    const response = await billingRoute.GET(apiRequest("GET", "/api/v1/billing", { token: env.tokens.alice }));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ serverURL: "https://subscription.test", publishableKey: "rxs_pk_sandbox_test-public", usageItem: "daily_summary_generation", balanceUnit: "points" });
    expect(response.headers.get("cache-control")).toContain("no-store");
    expect((await billingRoute.GET(apiRequest("GET", "/api/v1/billing"))).status).toBe(401);
  });
  it("never exposes a secret as a publishable key", async () => {
    vi.stubEnv("RX_SUBSCRIPTION_PUBLISHABLE_KEY", "rxs_sandbox_secret");
    expect((await billingRoute.GET(apiRequest("GET", "/api/v1/billing", { token: env.tokens.alice }))).status).toBe(503);
  });
  it("ignores unsigned sandbox hints and rejects forged Apple proof", async () => {
    vi.stubEnv("RX_SUBSCRIPTION_PRODUCTION_API_KEY", "rxs_production_test-secret");
    vi.stubEnv("RX_SUBSCRIPTION_PRODUCTION_PUBLISHABLE_KEY", "rxs_pk_production_test-public");
    const response = await billingRoute.GET(apiRequest("GET", "/api/v1/billing", {
      token: env.tokens.alice, headers: { "x-billing-environment": "sandbox" },
    }));
    expect((await response.json()).publishableKey).toBe("rxs_pk_production_test-public");
    const forged = await billingRoute.GET(apiRequest("GET", "/api/v1/billing", {
      token: env.tokens.alice, headers: { "x-storekit-app-transaction": "not-signed" },
    }));
    expect(forged.status).toBe(403);
  });
});

describe("chat points", () => {
  function chat(token = env.tokens.alice) {
    return chatRoute.POST(apiRequest("POST", "/api/v1/chat", {
      token, body: { messages: [{ id: "1", role: "user", parts: [{ type: "text", text: "honeybee" }] }] },
    }));
  }
  function service(reserve: () => Response) {
    const fetch = vi.fn(async (url: unknown, init?: RequestInit) => {
      expect(new Headers(init?.headers).get("x-api-key")).toBe("rxs_sandbox_test-secret");
      const path = new URL(String(url)).pathname;
      if (path === "/api/v1/balances/reserve") return reserve();
      if (path === "/api/v1/balances/reservations/res-1/settle") return Response.json({ operationShortfallAmount: 0, status: "closed" });
      throw new Error(`Unexpected ${path}`);
    });
    vi.stubGlobal("fetch", fetch);
    return fetch;
  }
  const bodies = (fetch: ReturnType<typeof service>, path: string) => fetch.mock.calls
    .filter(([url]) => new URL(String(url)).pathname === path)
    .map(([, init]) => JSON.parse(init?.body as string));

  it("holds a point before the model runs, then charges every step's tokens at API pricing", async () => {
    const fetch = service(() => Response.json({ reservationId: "res-1", amount: 1, available: 9 }));
    const response = await chat();
    expect(response.status).toBe(200);
    await response.text();
    const [reserve] = bodies(fetch, "/api/v1/balances/reserve");
    expect(reserve).toMatchObject({ rxlabUserId: "user-alice", unit: "points", amount: 1 });
    await vi.waitFor(() => expect(bodies(fetch, "/api/v1/balances/reservations/res-1/settle")).toHaveLength(1));
    const [settle] = bodies(fetch, "/api/v1/balances/reservations/res-1/settle");
    // Two steps (tool call, answer) of 10 input + 10 output tokens at $0.01/$0.04 = $1.00 → 50 points.
    expect(settle).toMatchObject({
      amount: 50, final: true, description: "mock/chat", idempotencyKey: `${reserve.idempotencyKey}:settle`,
      metadata: { outcome: "finished", steps: 2, inputTokens: 20, outputTokens: 20 },
    });
  });
  it("refuses an empty balance with 402 before the model runs", async () => {
    const fetch = service(() => Response.json({ error: "insufficient_balance", available: 0, required: 1 }, { status: 409 }));
    const response = await chat();
    expect(response.status).toBe(402);
    expect((await response.json()).error.code).toBe("CHAT_POINTS_EXHAUSTED");
    expect(bodies(fetch, "/api/v1/balances/reservations/res-1/settle")).toHaveLength(0);
  });
  it("fails closed when the balance cannot be checked", async () => {
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new Error("offline")));
    const response = await chat();
    expect(response.status).toBe(503);
    expect((await response.json()).error.code).toBe("CHAT_BILLING_UNAVAILABLE");
  });
  it("charges the held minimum when the model has no listed price", async () => {
    env.ai.pricing = null;
    const fetch = service(() => Response.json({ reservationId: "res-1", amount: 1, available: 9 }));
    await (await chat()).text();
    await vi.waitFor(() => expect(bodies(fetch, "/api/v1/balances/reservations/res-1/settle")).toHaveLength(1));
    expect(bodies(fetch, "/api/v1/balances/reservations/res-1/settle")[0].amount).toBe(1);
  });
});

describe("source document points", () => {
  /** By default the summary is past the free allowance and took a point. */
  function service(reserve: () => Response, usage = () => Response.json({ allowed: true, chargedUnits: 1 })) {
    const fetch = vi.fn<(url: unknown, init?: RequestInit) => Promise<Response>>(async (url) => {
      const path = new URL(String(url)).pathname;
      if (path === "/api/v1/usage") return usage();
      if (path === "/api/v1/balances/reserve") return reserve();
      if (path === "/api/v1/balances/reservations/res-doc/settle") return Response.json({ operationShortfallAmount: 0, status: "closed" });
      throw new Error(`Unexpected ${path}`);
    });
    vi.stubGlobal("fetch", fetch);
    return fetch;
  }
  const bodies = (fetch: ReturnType<typeof service>, path: string) => fetch.mock.calls
    .filter(([url]) => new URL(String(url)).pathname === path)
    .map(([, init]) => JSON.parse(init?.body as string));
  const settled = (fetch: ReturnType<typeof service>) => bodies(fetch, "/api/v1/balances/reservations/res-doc/settle");
  const storedMarkdown = async (id: string) => (await env.handle.db.select().from(summaries).where(eq(summaries.id, id)))[0].contentMarkdown;

  it("is included free while the summary comes out of the free allowance", async () => {
    const fetch = service(() => Response.json({ reservationId: "res-doc", amount: 1, available: 9 }), () => Response.json({ allowed: true, chargedUnits: 0 }));
    const summary = await (await create()).json();
    await vi.waitFor(async () => expect(await storedMarkdown(summary.id)).toBe(source.text));
    expect(env.ai.calls.formatMarkdown).toHaveLength(1);
    expect(bodies(fetch, "/api/v1/balances/reserve")).toHaveLength(0);
    expect(settled(fetch)).toHaveLength(0);
  });

  it("past the free allowance, holds points for the document agent after the summary is saved, then charges its tokens", async () => {
    const fetch = service(() => Response.json({ reservationId: "res-doc", amount: 1, available: 9 }));
    const summary = await (await create()).json();
    await vi.waitFor(() => expect(settled(fetch)).toHaveLength(1));
    const [reserve] = bodies(fetch, "/api/v1/balances/reserve");
    expect(reserve).toMatchObject({ rxlabUserId: "user-alice", unit: "points", amount: 1, idempotencyKey: `document:${summary.id}`, metadata: { summaryId: summary.id } });
    // One agent step of 10 input + 10 output tokens at $0.01/$0.04 = $0.50 → 25 points.
    expect(settled(fetch)[0]).toMatchObject({
      amount: 25, final: true, idempotencyKey: `document:${summary.id}:settle`,
      metadata: { outcome: "finished", steps: 1, inputTokens: 10, outputTokens: 10 },
    });
    await vi.waitFor(async () => expect(await storedMarkdown(summary.id)).toBe(source.text));
    expect(env.ai.calls.formatMarkdown).toHaveLength(1);
  });

  it("keeps the plain text without running the agent when the balance is empty", async () => {
    const fetch = service(() => Response.json({ error: "insufficient_balance", available: 0, required: 1 }, { status: 409 }));
    const response = await create();
    expect(response.status).toBe(201);
    const summary = await response.json();
    await vi.waitFor(async () => expect(await storedMarkdown(summary.id)).toBe(source.text));
    expect(env.ai.calls.formatMarkdown).toHaveLength(0);
    expect(settled(fetch)).toHaveLength(0);
  });

  it("releases the hold when the agent fails", async () => {
    env.ai.markdown = () => null;
    const fetch = service(() => Response.json({ reservationId: "res-doc", amount: 1, available: 9 }));
    const summary = await (await create()).json();
    await vi.waitFor(() => expect(settled(fetch)).toHaveLength(1));
    expect(settled(fetch)[0]).toMatchObject({ amount: 0, metadata: { outcome: "failed" } });
    await vi.waitFor(async () => expect(await storedMarkdown(summary.id)).toBe(source.text));
  });

  it("does not hold points for a local file that is not kept", async () => {
    const fetch = service(() => Response.json({ reservationId: "res-doc", amount: 1, available: 9 }));
    const response = await create(env.tokens.alice, { source: { type: "local", kind: "text", text: source.text, filename: "notes.txt" } });
    expect(response.status).toBe(201);
    expect(bodies(fetch, "/api/v1/balances/reserve")).toHaveLength(0);
  });
});

describe("translation points", () => {
  /** Summaries come out of the free allowance (their documents too); translation holds answer with `reserve`. */
  function service(reserve: (body: { rxlabUserId: string; idempotencyKey: string }) => Response) {
    const fetch = vi.fn<(url: unknown, init?: RequestInit) => Promise<Response>>(async (url, init) => {
      const path = new URL(String(url)).pathname;
      if (path === "/api/v1/usage") return Response.json({ allowed: true });
      if (path === "/api/v1/balances/reserve") return reserve(JSON.parse(init?.body as string));
      if (path.startsWith("/api/v1/balances/reservations/")) return Response.json({ operationShortfallAmount: 0, status: "closed" });
      throw new Error(`Unexpected ${path}`);
    });
    vi.stubGlobal("fetch", fetch);
    return fetch;
  }
  const funded = (body: { idempotencyKey: string }) => Response.json({ reservationId: body.idempotencyKey, amount: 1, available: 9 });
  const empty = () => Response.json({ error: "insufficient_balance", available: 0, required: 1 }, { status: 409 });
  const calls = (fetch: ReturnType<typeof service>, match: (path: string) => boolean) => fetch.mock.calls
    .filter(([url]) => match(new URL(String(url)).pathname))
    .map(([url, init]) => ({ path: new URL(String(url)).pathname, body: JSON.parse(init?.body as string) }));
  const reserves = (fetch: ReturnType<typeof service>) => calls(fetch, (path) => path === "/api/v1/balances/reserve").map(({ body }) => body);
  const settles = (fetch: ReturnType<typeof service>) => calls(fetch, (path) => path.endsWith("/settle"))
    .map(({ path, body }) => ({ reservation: decodeURIComponent(path.split("/")[5]), ...body }));

  async function createWithSource() {
    const summary = await (await create()).json();
    await vi.waitFor(async () => {
      const [row] = await env.handle.db.select().from(summaries).where(eq(summaries.id, summary.id));
      expect(row.contentMarkdown).toBeTruthy();
    });
    return summary;
  }
  async function read(id: string, token: string, language: string) {
    const response = await summaryRoute.GET(apiRequest("GET", `/api/v1/summaries/${id}`, { token, headers: { "accept-language": language } }), params({ id }));
    expect(response.status).toBe(200);
    return response.json();
  }

  it("charges the reader for the card and the source document at the model's API price", async () => {
    const fetch = service(funded);
    const created = await createWithSource();
    expect(reserves(fetch)).toHaveLength(0);
    expect((await read(created.id, env.tokens.bob, "ja")).title).toBe(`[ja] ${created.title}`);
    await vi.waitFor(() => expect(settles(fetch)).toHaveLength(2));
    const [card, document] = reserves(fetch);
    expect(card).toMatchObject({ rxlabUserId: "user-bob", unit: "points", amount: 1, metadata: { summaryId: created.id, language: "ja", part: "card" } });
    expect(card.idempotencyKey).toMatch(new RegExp(`^translation:${created.id}:ja:`));
    expect(document).toMatchObject({ rxlabUserId: "user-bob", metadata: { summaryId: created.id, language: "ja", part: "source" } });
    // One call of 10 input + 10 output tokens at $0.01/$0.04 = $0.50 → 25 points each.
    for (const settle of settles(fetch)) expect(settle).toMatchObject({ amount: 25, final: true, metadata: { outcome: "finished" } });
    // A saved translation is free for the next reader.
    await read(created.id, env.tokens.bob, "ja");
    expect(reserves(fetch)).toHaveLength(2);
  });

  it("shows the original without translating when the reader's balance is empty", async () => {
    service(empty);
    const created = await createWithSource();
    const summary = await read(created.id, env.tokens.bob, "ja");
    expect(summary).toMatchObject({ language: "en", title: created.title, translationPending: false });
    expect(env.ai.calls.translateSummary).toHaveLength(0);
    expect(await env.handle.db.select().from(summaryTranslations)).toHaveLength(0);
  });

  it("refuses the owner's display language with 402 when they have no points, without storing it", async () => {
    service(empty);
    const created = await createWithSource();
    const response = await summaryRoute.PATCH(apiRequest("PATCH", `/api/v1/summaries/${created.id}`, {
      token: env.tokens.alice, body: { displayLanguage: "fr" },
    }), params({ id: created.id }));
    expect(response.status).toBe(402);
    expect((await response.json()).error.code).toBe("TRANSLATION_POINTS_EXHAUSTED");
    const [row] = await env.handle.db.select().from(summaries).where(eq(summaries.id, created.id));
    expect(row.displayLanguage).toBeNull();
  });

  it("releases the hold when the translation fails", async () => {
    const fetch = service(funded);
    const created = await createWithSource();
    env.ai.translates = false;
    expect((await read(created.id, env.tokens.bob, "ja")).title).toBe(created.title);
    expect(settles(fetch)).toEqual([expect.objectContaining({ amount: 0, metadata: expect.objectContaining({ outcome: "failed" }) })]);
  });

  it("charges the owner for a visitor who isn't signed in", async () => {
    const fetch = service(funded);
    const created = await createWithSource();
    const response = await publicRoute.GET(apiRequest("GET", `/api/public/summaries/${created.slug}`, { headers: { "accept-language": "de" } }), params({ slug: created.slug }));
    expect((await response.json()).title).toBe(`[de] ${created.title}`);
    expect(reserves(fetch)[0]).toMatchObject({ rxlabUserId: "user-alice", metadata: { part: "card" } });
  });

  it("holds once for a library page and charges only the cards it translated", async () => {
    const fetch = service(funded);
    await createWithSource();
    await createWithSource();
    // Alice reads both of her chips in Korean; no source documents, so only the cards are translated.
    const rows = await env.handle.db.select().from(summaries);
    await env.handle.db.update(summaries).set({ displayLanguage: "ko", contentMarkdown: null });
    const list = await (await summariesRoute.GET(apiRequest("GET", "/api/v1/summaries", { token: env.tokens.alice }))).json();
    expect(list.items.every((item: { translationPending: boolean }) => item.translationPending)).toBe(true);
    await vi.waitFor(() => expect(settles(fetch)).toHaveLength(1));
    const [hold] = reserves(fetch);
    expect(hold).toMatchObject({ rxlabUserId: "user-alice", metadata: { part: "card" } });
    expect(hold.metadata.summaryIds).toHaveLength(rows.length);
    // Two cards of 10 + 10 tokens = $1.00 → 50 points.
    expect(settles(fetch)[0]).toMatchObject({ amount: 50, metadata: { translated: 2, requested: 2, outcome: "finished" } });
  });

  it("lists the originals when the balance is empty", async () => {
    service(empty);
    await createWithSource();
    await env.handle.db.update(summaries).set({ displayLanguage: "ko" });
    const list = await (await summariesRoute.GET(apiRequest("GET", "/api/v1/summaries", { token: env.tokens.alice }))).json();
    expect(list.items[0]).toMatchObject({ translationPending: false, language: "en" });
    expect(env.ai.calls.translateSummary).toHaveLength(0);
  });
});

describe("chat point pricing", () => {
  const usage = (input: number, output: number, cacheRead = 0) => ({
    inputTokens: input, outputTokens: output, totalTokens: input + output,
    inputTokenDetails: { noCacheTokens: input - cacheRead, cacheReadTokens: cacheRead, cacheWriteTokens: 0 },
    outputTokenDetails: { textTokens: output, reasoningTokens: 0 },
  });
  it("prices cached input separately and rounds up to whole points", () => {
    const pricing = { input: 0.25e-6, output: 2e-6, cachedInput: 0.025e-6 };
    // gpt-5-mini-style list prices: 1,000 fresh + 1,000 cached input, 500 output = $0.001275.
    expect(usageCostUsd(usage(2_000, 500, 1_000), pricing)).toBeCloseTo(0.001275, 9);
    expect(pointsForCost(0.001275)).toBe(1);
    expect(pointsForCost(1)).toBe(50);
    expect(pointsForCost(0.02)).toBe(1);
    expect(pointsForCost(0)).toBe(0);
    vi.stubEnv("CHAT_POINTS_PER_USD", "1000");
    expect(pointsForCost(0.001275)).toBe(2);
  });
});
