import { AsyncLocalStorage } from "node:async_hooks";
import { z } from "zod";
import { ApiError } from "@/lib/http/errors";
import type { SubscriptionEnvironment } from "./environment";

export const FLOWCY_PLUS_PLAN_ID = "8efd0160-848f-448f-968f-ec2129566829";
export const FLOWCY_APPLE_PRODUCT_ID = "com.rxlab.chippy.flowcy.plus.monthly";

const plan = z.object({
  planId: z.string(),
  billingProvider: z.string(),
  status: z.string(),
  currentPeriodEnd: z.iso.datetime({ offset: true }).nullable(),
});
const entitlements = z.object({
  plans: z.array(plan),
  complimentaryPlans: z.array(plan).default([]),
});
const catalog = z.object({
  plans: z.array(z.object({
    id: z.string(),
    purchaseOptions: z.array(z.object({
      provider: z.string(),
      productId: z.string().optional(),
      productType: z.string().optional(),
    })),
  })),
});
const accountToken = z.object({ appAccountToken: z.uuid() });

export type FlowcyAccess = { active: boolean; provider: "apple" | "flowcy" | null };

interface FlowcyRequestContext {
  userId: string;
  environment: SubscriptionEnvironment;
  access?: Promise<FlowcyAccess>;
}

const requests = new AsyncLocalStorage<FlowcyRequestContext>();

/**
 * Runs a request with its verified StoreKit environment and memoizes Flowcy Plus access checks
 * within the request so repeated AI checks do not hit the subscription service multiple times.
 */
export function withFlowcyRequest<T>(
  userId: string,
  environment: SubscriptionEnvironment,
  run: () => T,
  initialAccess?: FlowcyAccess,
): T {
  return requests.run(
    { userId, environment, access: initialAccess ? Promise.resolve(initialAccess) : undefined },
    run,
  );
}

/** Backwards-compatible helper for callers that already verified active membership. */
export function withFlowcyMember<T>(userId: string, environment: SubscriptionEnvironment, run: () => T): T {
  return withFlowcyRequest(userId, environment, run, { active: true, provider: "flowcy" });
}

export function currentSubscriptionEnvironment(userId: string) {
  const ctx = requests.getStore();
  return ctx?.userId === userId ? ctx.environment : undefined;
}

function apiKey(environment: SubscriptionEnvironment) {
  return process.env[`FLOWCY_SUBSCRIPTION_${environment.toUpperCase()}_API_KEY`]?.trim();
}

function localAccess() {
  return !isDeployed() && !apiKey("production") && !apiKey("sandbox") && !apiKey("xcode");
}

function sandboxAllowed(userId: string) {
  if (!isDeployed() || process.env.VERCEL_ENV === "preview") return true;
  return (process.env.FLOWCY_SUBSCRIPTION_SANDBOX_USER_IDS ?? "").split(",").some(id => id.trim() !== "" && id.trim() === userId);
}

export function isDeployed() {
  return process.env.NODE_ENV === "production" || Boolean(process.env.VERCEL_ENV && process.env.VERCEL_ENV !== "development");
}

function unavailable() {
  return new ApiError(503, "FLOWCY_SUBSCRIPTION_UNAVAILABLE", "Flowcy Plus access could not be checked. Please try again.");
}

async function billingRequest<T>(environment: SubscriptionEnvironment, path: string, schema: z.ZodType<T>, body?: object) {
  const key = apiKey(environment);
  if (!key?.startsWith(`rxs_${environment}_`)) throw unavailable();
  try {
    const base = new URL(process.env.FLOWCY_SUBSCRIPTION_URL?.trim() || "https://subscription.rxlab.app");
    if (base.protocol !== "https:" && (isDeployed() || base.protocol !== "http:" || !["localhost", "127.0.0.1"].includes(base.hostname))) {
      throw new Error("Invalid subscription server origin");
    }
    base.pathname = `${base.pathname.replace(/\/+$/, "")}/api/v1/`;
    const response = await fetch(new URL(path, base), {
      method: body ? "POST" : "GET",
      headers: { "x-api-key": key, accept: "application/json", ...(body && { "content-type": "application/json" }) },
      body: body && JSON.stringify(body),
      cache: "no-store",
      redirect: "error",
      signal: AbortSignal.timeout(10_000),
    });
    if (!response.ok) {
      if (path === "iap/apple/transactions" && [400, 403, 409, 422].includes(response.status)) {
        throw new ApiError(422, "FLOWCY_APPLE_PURCHASE_REJECTED", "This App Store purchase could not be linked. Make sure you are signed in to the RxLab account used for the purchase.");
      }
      throw unavailable();
    }
    return schema.parse(await response.json());
  } catch (error) {
    if (error instanceof ApiError) throw error;
    throw unavailable();
  }
}

export async function flowcyAccess(userId: string, environment: SubscriptionEnvironment = "production"): Promise<FlowcyAccess> {
  if (localAccess()) return { active: true, provider: "flowcy" as const };
  const path = `entitlements?${new URLSearchParams({ rxlabUserId: userId })}`;
  if (environment === "sandbox" && apiKey("production")) {
    const production = await flowcyAccess(userId);
    if (production.active) return production;
  }
  if (environment === "sandbox" && (!apiKey("sandbox") || !sandboxAllowed(userId))) return { active: false, provider: null };
  const data = await billingRequest(environment, path, entitlements);
  // The service resolves live entitlements, including grace periods and complimentary grants.
  // Its auto-enrolled Free plan is returned separately in defaultPlans.
  const plus = [...data.plans, ...data.complimentaryPlans].find(entry =>
    entry.planId === FLOWCY_PLUS_PLAN_ID &&
    ["active", "trialing"].includes(entry.status) &&
    (!entry.currentPeriodEnd || Date.parse(entry.currentPeriodEnd) > Date.now()));
  const provider = plus ? (plus.billingProvider === "apple_app_store" ? "apple" : "flowcy") : null;
  return { active: Boolean(plus), provider };
}

function resolveFlowcyAccess(userId: string, environment?: SubscriptionEnvironment): Promise<FlowcyAccess> {
  const ctx = requests.getStore();
  if (ctx?.userId === userId && (environment === undefined || environment === ctx.environment)) {
    if (!ctx.access) {
      ctx.access = flowcyAccess(userId, ctx.environment);
      ctx.access.catch(() => {});
    }
    return ctx.access;
  }
  return flowcyAccess(userId, environment ?? "production");
}

/**
 * Checks whether the user currently has Flowcy Plus AI access without failing non-AI operations
 * when the subscription service is unreachable (fails closed to `false`).
 */
export async function hasFlowcyAccess(userId: string, environment?: SubscriptionEnvironment): Promise<boolean> {
  try {
    return (await resolveFlowcyAccess(userId, environment)).active;
  } catch (error) {
    if (error instanceof ApiError && error.code === "FLOWCY_SUBSCRIPTION_UNAVAILABLE") return false;
    throw error;
  }
}

export async function requireFlowcyAccess(userId: string, environment?: SubscriptionEnvironment): Promise<FlowcyAccess> {
  const access = await resolveFlowcyAccess(userId, environment);
  if (!access.active) {
    throw new ApiError(402, "FLOWCY_SUBSCRIPTION_REQUIRED", "Flowcy Plus is required for AI features in Chippy. Open Chippy to subscribe or check your access.");
  }
  return access;
}

export async function appleProductId(userId: string, environment: SubscriptionEnvironment) {
  if (!apiKey(environment) || (environment === "sandbox" && !sandboxAllowed(userId))) return null;
  const result = await billingRequest(environment, "catalog?platform=ios", catalog);
  const product = result.plans.find((entry) => entry.id === FLOWCY_PLUS_PLAN_ID)?.purchaseOptions
    .find((entry) => entry.provider === "apple_app_store" && entry.productType === "auto_renewable_subscription");
  return product?.productId === FLOWCY_APPLE_PRODUCT_ID ? product.productId : null;
}

export async function appleAccountToken(userId: string, environment: SubscriptionEnvironment) {
  if ((await flowcyAccess(userId, environment)).active) {
    throw new ApiError(409, "FLOWCY_SUBSCRIPTION_ALREADY_ACTIVE", "This account already has Flowcy Plus.");
  }
  if (!(await appleProductId(userId, environment))) {
    throw new ApiError(503, "FLOWCY_APPLE_PURCHASE_UNAVAILABLE", "Flowcy Plus is currently unavailable in the App Store.");
  }
  return billingRequest(environment, "iap/apple/account-token", accountToken, { rxlabUserId: userId });
}

export async function submitAppleTransaction(userId: string, environment: SubscriptionEnvironment, signedTransaction: string) {
  if (environment === "sandbox" && !sandboxAllowed(userId)) {
    throw new ApiError(403, "FLOWCY_APPLE_SANDBOX_NOT_AVAILABLE", "This RxLab account is not enabled for App Store sandbox purchases.");
  }
  await billingRequest(environment, "iap/apple/transactions", z.record(z.string(), z.unknown()), {
    rxlabUserId: userId, signedTransaction,
  });
}
