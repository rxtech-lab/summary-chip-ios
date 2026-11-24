import { afterEach, expect, it, vi } from "vitest";
import * as membership from "@/app/api/v1/subscription/route";
import * as appleToken from "@/app/api/v1/subscription/apple/account-token/route";
import * as appleTransactions from "@/app/api/v1/subscription/apple/transactions/route";
import * as library from "@/app/api/v1/summaries/route";
import { FLOWCY_APPLE_PRODUCT_ID } from "@/lib/subscription/flowcy";
import { apiRequest, setupTestEnv, signToken } from "../helpers/setup";

const simulation = process.env.FLOWCY_SUBSCRIPTION_SIMULATION_URL;
afterEach(() => vi.unstubAllEnvs());

it.skipIf(!simulation)("gates library access and fulfills a StoreKit purchase over the RxSubscription HTTP contract", async () => {
  const env = await setupTestEnv();
  try {
    vi.stubEnv("FLOWCY_SUBSCRIPTION_URL", `${simulation}/subscription`);
    vi.stubEnv("FLOWCY_SUBSCRIPTION_PRODUCTION_API_KEY", "rxs_production_fixture");
    const testAccount = await signToken(`storekit-fixture-${crypto.randomUUID()}`);
    const apple = (method: string, body?: unknown) => apiRequest(method, "/api/v1/subscription", {
      token: testAccount, body, headers: { "x-app-platform": "ios", "x-app-version": "2.0" },
    });
    expect(await (await membership.GET(apple("GET"))).json()).toMatchObject({ active: false, productId: FLOWCY_APPLE_PRODUCT_ID });
    expect((await library.GET(apple("GET"))).status).toBe(402);
    expect((await library.GET(apiRequest("GET", "/api/v1/summaries", { token: env.tokens.bob }))).status).toBe(200);
    expect((await appleToken.POST(apple("POST", {}))).status).toBe(200);
    expect((await appleTransactions.POST(apple("POST", { signedTransaction: "invalid-apple-transaction" }))).status).toBe(422);
    expect((await appleTransactions.POST(apple("POST", { signedTransaction: "signed-apple-transaction-fixture" }))).status).toBe(200);
    expect(await (await membership.GET(apple("GET"))).json()).toMatchObject({ active: true, provider: "apple" });
    expect((await library.GET(apple("GET"))).status).toBe(200);
    vi.stubEnv("FLOWCY_SUBSCRIPTION_URL", `${simulation}/subscription/unavailable`);
    expect((await library.GET(apple("GET"))).status).toBe(503);
  } finally {
    env.teardown();
  }
});
