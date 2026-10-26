import { z } from "zod";
import { subscriptionConfig } from "./config";

const topUpSchema = z.object({
  id: z.string().min(1),
  name: z.string().min(1),
  description: z.string().nullish(),
  unit: z.string().nullable(),
  amount: z.number().int().positive(),
  priceAmountCents: z.number().int().nonnegative(),
  currency: z.string().regex(/^[a-zA-Z]{3}$/),
});
const catalogSchema = z.object({ topups: z.array(topUpSchema) });
export type PricingTopUp = z.infer<typeof topUpSchema>;

/** Anonymous marketing read: never creates a billing user or exposes the API key. */
export async function getPricingTopUps(): Promise<PricingTopUp[] | null> {
  try {
    // Public marketing must never advertise sandbox or Xcode prices.
    const config = subscriptionConfig("production");
    if (!config) return null;
    const response = await fetch(`${config.baseURL}/api/v1/catalog?platform=web`, {
      headers: { "x-api-key": config.apiKey, accept: "application/json" },
      cache: "no-store",
      signal: AbortSignal.timeout(5_000),
    });
    if (!response.ok) return null;
    const catalog = catalogSchema.parse(await response.json());
    return catalog.topups.filter(pack => pack.unit === "points");
  } catch {
    // A billing outage must not take the landing page down or invent a price.
    return null;
  }
}

export function formatTopUpPrice(pack: PricingTopUp): string {
  // RxSubscription defines priceAmountCents as hundredths, for every currency.
  return new Intl.NumberFormat("en-US", {
    style: "currency", currency: pack.currency, currencyDisplay: "code",
  }).format(pack.priceAmountCents / 100);
}
