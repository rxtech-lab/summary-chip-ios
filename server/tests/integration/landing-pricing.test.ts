import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { formatTopUpPrice, getPricingTopUps } from "@/lib/subscription/pricing";

// Run with the local Postman simulation; ordinary test runs don't contact billing.
const simulation = process.env.PRICING_SIMULATION_URL;
describe.skipIf(!simulation)("landing pricing over HTTP", () => {
  beforeEach(() => {
    vi.stubEnv("RX_SUBSCRIPTION_URL", `${simulation}/catalog`);
    vi.stubEnv("RX_SUBSCRIPTION_PRODUCTION_API_KEY", "rxs_production_pricing-fixture");
    vi.stubEnv("RX_SUBSCRIPTION_ENVIRONMENT", "sandbox");
    vi.stubEnv("RX_SUBSCRIPTION_API_KEY", "rxs_sandbox_must-not-be-used");
  });
  afterEach(() => { vi.unstubAllEnvs(); });

  it("reads production web pricing even when app billing defaults to sandbox", async () => {
    const packs = await getPricingTopUps();
    expect(packs).toHaveLength(1);
    expect(packs![0]).toMatchObject({ amount: 100, priceAmountCents: 199, currency: "usd" });
    expect(formatTopUpPrice(packs![0])).toBe("USD\u00a01.99");
    expect(JSON.stringify(packs)).not.toContain("rxs_");
  });
  it.each(["outage", "malformed"])("returns unavailable for %s instead of fabricated prices", async mode => {
    vi.stubEnv("RX_SUBSCRIPTION_URL", `${simulation}/${mode}`);
    expect(await getPricingTopUps()).toBeNull();
  });
  it("distinguishes an empty catalog from an outage", async () => {
    vi.stubEnv("RX_SUBSCRIPTION_URL", `${simulation}/empty`);
    expect(await getPricingTopUps()).toEqual([]);
  });
  it("does not use sandbox credentials when production is missing", async () => {
    vi.stubEnv("RX_SUBSCRIPTION_PRODUCTION_API_KEY", "");
    expect(await getPricingTopUps()).toBeNull();
  });
});
