import type { LanguageModelUsage } from "ai";
import type { AiProvider, ModelPricing } from "@/lib/ai/provider";
import { ApiError } from "@/lib/http/errors";
import { subscriptionConfig, type BillingEnvironment } from "./config";

/** The balance unit chat spends; the same points top-up packs credit. */
export const CHAT_BALANCE_UNIT = "points";

/**
 * Points charged per US dollar of model API cost (`CHAT_POINTS_PER_USD`), in the unit's smallest
 * denomination. The default prices chat at cost against the 100 points for US$1.99 pack.
 */
export const DEFAULT_CHAT_POINTS_PER_USD = 50;

/** Held before the model runs: the user needs at least this much to start a turn. */
const RESERVE_POINTS = 1;
/** A hold outliving the request (a crashed function) lapses on its own and charges nothing. */
const RESERVE_TTL_SECONDS = 600;

export function chatPointsPerUsd(): number {
  const configured = Number(process.env.CHAT_POINTS_PER_USD);
  return Number.isFinite(configured) && configured > 0 ? configured : DEFAULT_CHAT_POINTS_PER_USD;
}

/** API list price of the tokens a turn used, in USD. */
export function usageCostUsd(usage: LanguageModelUsage, pricing: ModelPricing): number {
  const cacheRead = usage.inputTokenDetails?.cacheReadTokens ?? 0;
  const cacheWrite = usage.inputTokenDetails?.cacheWriteTokens ?? 0;
  const uncached = Math.max(0, (usage.inputTokens ?? 0) - cacheRead - cacheWrite);
  return uncached * pricing.input
    + cacheRead * (pricing.cachedInput ?? pricing.input)
    + cacheWrite * (pricing.cacheWrite ?? pricing.input)
    + (usage.outputTokens ?? 0) * pricing.output;
}

/** Whole points, rounded up so a turn that cost real money is never free. */
export function pointsForCost(usd: number): number {
  if (!Number.isFinite(usd) || usd <= 0) return 0;
  // Trim float noise (e.g. 2.0000000000000004) before rounding up.
  return Math.ceil(Number((usd * chatPointsPerUsd()).toFixed(6)));
}

export interface ChatCharge {
  /** Charges the operation's points and closes the hold; 0 releases it. Never throws. */
  settle(points: number, metadata: Record<string, unknown>): Promise<void>;
}

interface HoldOptions {
  userId: string;
  /** Idempotency key of the hold; the settlement uses `${key}:settle`. */
  key: string;
  description: string;
  metadata: Record<string, unknown>;
  environment?: BillingEnvironment;
  /** Error codes reported for an empty balance and an unreachable billing service. */
  codes: { exhausted: string; exhaustedMessage: string; notConfigured: string; unavailable: string; unavailableMessage: string };
}

/**
 * Holds points before a metered model run so an empty balance is refused up front (402), not after
 * the model has run. Returns null when billing is unconfigured (local development only).
 */
async function holdPoints(options: HoldOptions): Promise<ChatCharge | null> {
  const config = subscriptionConfig(options.environment);
  if (!config) return null;
  const call = (path: string, body: Record<string, unknown>) => fetch(`${config.baseURL}/api/v1/balances${path}`, {
    method: "POST",
    headers: { "x-api-key": config.apiKey, "content-type": "application/json", accept: "application/json" },
    body: JSON.stringify(body),
    cache: "no-store",
    signal: AbortSignal.timeout(10_000),
  });

  let reservationId: string;
  try {
    const response = await call("/reserve", {
      rxlabUserId: options.userId,
      unit: CHAT_BALANCE_UNIT,
      amount: RESERVE_POINTS,
      idempotencyKey: options.key,
      description: options.description,
      expiresInSeconds: RESERVE_TTL_SECONDS,
      metadata: options.metadata,
    });
    const body = await response.json().catch(() => ({}));
    if (response.status === 409 && body.error === "insufficient_balance") {
      throw new ApiError(402, options.codes.exhausted, options.codes.exhaustedMessage);
    }
    if (response.status === 404) throw new ApiError(503, options.codes.notConfigured, "Points billing is not available yet. Please try again later.");
    if (!response.ok || typeof body.reservationId !== "string") throw new Error(`Invalid reservation response (${response.status})`);
    reservationId = body.reservationId;
  } catch (error) {
    if (error instanceof ApiError) throw error;
    console.error("[points] reservation failed", { key: options.key, error });
    throw new ApiError(503, options.codes.unavailable, options.codes.unavailableMessage);
  }

  return {
    async settle(points, metadata) {
      try {
        // Settling above the hold charges the excess from the free balance; what it can't cover comes back as a shortfall.
        const response = await call(`/reservations/${encodeURIComponent(reservationId)}/settle`, {
          amount: Math.max(0, Math.ceil(points)),
          idempotencyKey: `${options.key}:settle`,
          final: true,
          description: options.metadata.model,
          metadata: { ...options.metadata, ...metadata },
        });
        const body = await response.json().catch(() => ({}));
        if (!response.ok) throw new Error(`Settle failed (${response.status}): ${JSON.stringify(body).slice(0, 300)}`);
        if (body.operationShortfallAmount > 0) {
          console.warn("[points] cost exceeded the balance", { userId: options.userId, key: options.key, points, shortfall: body.operationShortfallAmount });
        }
      } catch (error) {
        // The hold lapses after its TTL, so a failed settle under-charges rather than strands points.
        console.error("[points] settlement failed", { userId: options.userId, key: options.key, points, error });
      }
    },
  };
}

/** Holds points for a chat turn; an empty balance is `402 CHAT_POINTS_EXHAUSTED`. */
export function reserveChatPoints(userId: string, turnId: string, model: string, environment?: BillingEnvironment): Promise<ChatCharge | null> {
  return holdPoints({
    userId,
    key: `chat:${turnId}`,
    description: `Chat (${model})`,
    metadata: { turnId, model },
    environment,
    codes: {
      exhausted: "CHAT_POINTS_EXHAUSTED",
      exhaustedMessage: "Chatting uses points and your balance is empty. Top up to keep chatting.",
      notConfigured: "CHAT_BILLING_NOT_CONFIGURED",
      unavailable: "CHAT_BILLING_UNAVAILABLE",
      unavailableMessage: "Your points balance could not be checked. Please try again.",
    },
  });
}

/** Holds points for the document agent writing a summary's source; an empty balance is `402 DOCUMENT_POINTS_EXHAUSTED`. */
export function reserveDocumentPoints(userId: string, summaryId: string, model: string, environment?: BillingEnvironment): Promise<ChatCharge | null> {
  return holdPoints({
    userId,
    key: `document:${summaryId}`,
    description: `Source document (${model})`,
    metadata: { summaryId, model },
    environment,
    codes: {
      exhausted: "DOCUMENT_POINTS_EXHAUSTED",
      exhaustedMessage: "Formatting the source uses points and your balance is empty.",
      notConfigured: "DOCUMENT_BILLING_NOT_CONFIGURED",
      unavailable: "DOCUMENT_BILLING_UNAVAILABLE",
      unavailableMessage: "Your points balance could not be checked.",
    },
  });
}

/**
 * Settles a hold at the text model's API list price for every step's tokens. Unpriced but used
 * tokens cost the held minimum; a run that never reached the model costs nothing.
 */
export async function settleUsage(
  charge: ChatCharge,
  ai: Pick<AiProvider, "chatPricing">,
  steps: LanguageModelUsage[],
  metadata: Record<string, unknown>,
): Promise<void> {
  const inputTokens = steps.reduce((total, usage) => total + (usage.inputTokens ?? 0), 0);
  const outputTokens = steps.reduce((total, usage) => total + (usage.outputTokens ?? 0), 0);
  let costUsd: number | null = null;
  try {
    const pricing = await ai.chatPricing();
    if (pricing) costUsd = steps.reduce((total, usage) => total + usageCostUsd(usage, pricing), 0);
    else console.warn("[points] no API pricing for the text model; charging the minimum");
  } catch (error) {
    console.warn("[points] model pricing lookup failed; charging the minimum", error);
  }
  const points = costUsd === null ? (inputTokens + outputTokens > 0 ? 1 : 0) : pointsForCost(costUsd);
  await charge.settle(points, { ...metadata, steps: steps.length, inputTokens, outputTokens, costUsd });
}

/**
 * Holds points for translating summaries or a source document; an empty balance is
 * `402 TRANSLATION_POINTS_EXHAUSTED`. `key` names the run (one per attempt).
 */
export function reserveTranslationPoints(userId: string, key: string, model: string, metadata: Record<string, unknown>, environment?: BillingEnvironment): Promise<ChatCharge | null> {
  return holdPoints({
    userId,
    key: `translation:${key}`,
    description: `Translation (${model})`,
    metadata: { ...metadata, model },
    environment,
    codes: {
      exhausted: "TRANSLATION_POINTS_EXHAUSTED",
      exhaustedMessage: "Translating uses points and your balance is empty. Top up to read summaries in other languages.",
      notConfigured: "TRANSLATION_BILLING_NOT_CONFIGURED",
      unavailable: "TRANSLATION_BILLING_UNAVAILABLE",
      unavailableMessage: "Your points balance could not be checked. Please try again.",
    },
  });
}
