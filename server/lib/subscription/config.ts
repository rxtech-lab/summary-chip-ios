import { ApiError } from "@/lib/http/errors";

export type BillingEnvironment = "sandbox" | "production" | "xcode";

export function subscriptionConfig(environment?: BillingEnvironment) {
  const baseURL = process.env.RX_SUBSCRIPTION_URL?.trim();
  const legacyKey = process.env.RX_SUBSCRIPTION_API_KEY?.trim();
  const selected = environment ?? process.env.RX_SUBSCRIPTION_ENVIRONMENT?.trim() ?? "production";
  const namedKey = process.env[`RX_SUBSCRIPTION_${selected.toUpperCase()}_API_KEY`]?.trim();
  const apiKey = namedKey || legacyKey;
  const deployed = process.env.NODE_ENV === "production" || Boolean(process.env.VERCEL_ENV && process.env.VERCEL_ENV !== "development");
  const configured = ["RX_SUBSCRIPTION_URL", "RX_SUBSCRIPTION_ENVIRONMENT", "RX_SUBSCRIPTION_API_KEY", "RX_SUBSCRIPTION_PUBLISHABLE_KEY",
    ...["SANDBOX", "PRODUCTION", "XCODE"].flatMap(value => [`RX_SUBSCRIPTION_${value}_API_KEY`, `RX_SUBSCRIPTION_${value}_PUBLISHABLE_KEY`])]
    .some(key => Boolean(process.env[key]?.trim()));
  if (!deployed && !configured) return null;
  if (!["sandbox", "production", "xcode"].includes(selected) || !baseURL || !apiKey?.startsWith(`rxs_${selected}_`)) {
    throw new ApiError(503, "SUBSCRIPTION_NOT_CONFIGURED", "Summary usage is not configured. Please try again later.");
  }
  return { baseURL: baseURL.replace(/\/+$/, ""), apiKey, environment: selected as BillingEnvironment };
}

export function storefrontConfig(environment?: BillingEnvironment) {
  const config = subscriptionConfig(environment);
  const publishableKey = config && (process.env[`RX_SUBSCRIPTION_${config.environment.toUpperCase()}_PUBLISHABLE_KEY`]?.trim() || process.env.RX_SUBSCRIPTION_PUBLISHABLE_KEY?.trim());
  if (!config || !publishableKey?.startsWith(`rxs_pk_${config.environment}_`)) {
    throw new ApiError(503, "SUBSCRIPTION_NOT_CONFIGURED", "Top-ups are not configured. Please try again later.");
  }
  return { serverURL: config.baseURL, publishableKey };
}
