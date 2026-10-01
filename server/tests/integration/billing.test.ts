import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as billingRoute from "@/app/api/v1/billing/route";
import * as summariesRoute from "@/app/api/v1/summaries/route";
import { subscriptionConfig } from "@/lib/subscription/config";
import { consumeSummaryUsage } from "@/lib/subscription/usage";
import { apiRequest, setupTestEnv, type TestEnv } from "../helpers/setup";

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

describe("server-authorized summary usage", () => {
  it("accepts the remote free allowance, refuses exhaustion before AI, then accepts a top-up", async () => {
    let freeRemaining = 5; // Fixture policy only.
    let points = 0;
    const fetch = vi.fn(async (_url: unknown, init?: RequestInit) => {
      const body = JSON.parse(init?.body as string);
      expect(body).toMatchObject({ rxlabUserId: "user-alice", item: "daily_summary_generation", amount: 1 });
      expect(body.idempotencyKey).toBe(`summary:${body.metadata.summaryId}`);
      expect(new Headers(init?.headers).get("x-api-key")).toBe("rxs_sandbox_test-secret");
      if (freeRemaining > 0) { freeRemaining--; return Response.json({ allowed: true }); }
      if (points > 0) { points--; return Response.json({ allowed: true, chargedUnits: 1 }); }
      return Response.json({ allowed: false, reason: "insufficient_balance" }, { status: 402 });
    });
    vi.stubGlobal("fetch", fetch);
    for (let i = 0; i < 5; i++) expect((await create()).status).toBe(201);
    expect((await create()).status).toBe(402);
    expect(env.ai.calls.summarize).toHaveLength(5);
    points = 2;
    expect((await create()).status).toBe(201);
    expect(points).toBe(1);
    expect(env.ai.calls.summarize).toHaveLength(6);
    const keys = fetch.mock.calls.filter(([, init]) => init?.body).map(([, init]) => JSON.parse(init?.body as string).idempotencyKey);
    expect(new Set(keys).size).toBe(keys.length);
  });
  it("honors a changed remote policy without a local limit", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValueOnce(Response.json({ allowed: true }))
      .mockResolvedValueOnce(Response.json({ allowed: false }, { status: 402 })));
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
