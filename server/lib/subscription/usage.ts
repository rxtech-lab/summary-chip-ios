import { ApiError } from "@/lib/http/errors";
import { subscriptionConfig, type BillingEnvironment } from "./config";

export const SUMMARY_USAGE_ITEM = "daily_summary_generation";

export interface SummaryUsage {
  /** Points taken for this summary; 0 when the free allowance covered it. */
  chargedUnits: number;
}

/**
 * RxSubscription owns the allowance, reset and overage price. No local counters. The free
 * allowance is used first; past it, the summary's overage is taken from the points balance.
 */
export async function consumeSummaryUsage(userId: string, summaryId: string, environment?: BillingEnvironment): Promise<SummaryUsage> {
  const config = subscriptionConfig(environment);
  if (!config) return { chargedUnits: 0 }; // Entirely unconfigured local development only.
  let response: Response;
  try {
    response = await fetch(`${config.baseURL}/api/v1/usage`, {
      method: "POST",
      headers: { "x-api-key": config.apiKey, "content-type": "application/json", accept: "application/json" },
      body: JSON.stringify({ rxlabUserId: userId, item: SUMMARY_USAGE_ITEM, amount: 1, idempotencyKey: `summary:${summaryId}`, metadata: { summaryId } }),
      cache: "no-store",
      signal: AbortSignal.timeout(10_000),
    });
    const body = await response.json();
    if (response.status === 402 || (response.ok && body.allowed === false)) {
      throw new ApiError(402, "SUMMARY_ALLOWANCE_EXHAUSTED", "Your free summaries are used up or you have too few points. Top up or wait for your allowance to reset.");
    }
    if (response.status === 404) throw new ApiError(503, "SUMMARY_USAGE_NOT_CONFIGURED", "Summary usage is not available yet. Please try again later.");
    if (!response.ok || body.allowed !== true) throw new Error("Invalid usage response");
    const charged = Number(body.chargedUnits);
    return { chargedUnits: Number.isFinite(charged) && charged > 0 ? charged : 0 };
  } catch (error) {
    if (error instanceof ApiError) throw error;
    throw new ApiError(503, "SUMMARY_USAGE_UNAVAILABLE", "Your summary allowance could not be checked. Please try again.");
  }
}
