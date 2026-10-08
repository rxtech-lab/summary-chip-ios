import { createGateway, type GatewayProvider } from "@ai-sdk/gateway";
import type { ModelPricing } from "./provider";
import { wrapLanguageModel, type EmbeddingModel, type Experimental_EvaluationModel, type ImageModel, type LanguageModel, type LanguageModelMiddleware, type SpeechModel } from "ai";

let provider: GatewayProvider | undefined;

/** AI Gateway provider. Accepts `AI_GATEWAY_API_KEY` (SDK default) or `AI_GATEWAY_KEY`; on Vercel, OIDC is used when neither is set. */
function gateway(): GatewayProvider {
  provider ??= createGateway({ apiKey: process.env.AI_GATEWAY_API_KEY?.trim() || process.env.AI_GATEWAY_KEY?.trim() || undefined });
  return provider;
}

/** Default text model (AI Gateway id). Override with `AI_MODEL`. */
export const DEFAULT_TEXT_MODEL = "openai/gpt-5-mini";

export function textModelId(): string {
  return process.env.AI_MODEL?.trim() || DEFAULT_TEXT_MODEL;
}

export function textModel(): LanguageModel {
  return cachedChatModel(textModelId());
}

const EPHEMERAL = { anthropic: { cacheControl: { type: "ephemeral" } } };

/**
 * Anthropic models only cache with explicit breakpoints. Marks the last system message (caches tools + instructions)
 * and the last message (so each tool-loop step reads the previous step's prefix). Two of the four allowed breakpoints.
 */
export const anthropicCacheMiddleware: LanguageModelMiddleware = {
  specificationVersion: "v4",
  transformParams: async ({ params }) => {
    const prompt = [...params.prompt];
    const lastSystem = prompt.findLastIndex((message) => message.role === "system");
    const marks = new Set([lastSystem, prompt.length - 1].filter((index) => index >= 0));
    for (const index of marks) {
      const message = prompt[index];
      prompt[index] = { ...message, providerOptions: { ...message.providerOptions, anthropic: { ...message.providerOptions?.anthropic, ...EPHEMERAL.anthropic } } };
    }
    return { ...params, prompt };
  },
};

/** A Gateway chat model; Anthropic ones get explicit prompt-cache breakpoints. */
function cachedChatModel(id: string): LanguageModel {
  const model = gateway()(id);
  return id.startsWith("anthropic/") ? wrapLanguageModel({ model, middleware: anthropicCacheMiddleware }) : model;
}

/** Provider-independent search, authenticated through the same Gateway as chat. */
export function webSearchTool() {
  return gateway().tools.perplexitySearch({ maxResults: 6, maxTokensPerPage: 1024, maxTokens: 6000 });
}

const PRICING_TTL_MS = 60 * 60 * 1000;
let pricingCache: { at: number; prices: Map<string, ModelPricing> } | undefined;

/** A language model's API list price from the Gateway catalog (cached for an hour), or null when unlisted. */
export async function textModelPricing(id: string): Promise<ModelPricing | null> {
  if (!pricingCache || Date.now() - pricingCache.at > PRICING_TTL_MS) {
    const { models } = await gateway().getAvailableModels();
    const prices = new Map<string, ModelPricing>();
    for (const model of models) {
      const input = Number(model.pricing?.input);
      const output = Number(model.pricing?.output);
      if (!Number.isFinite(input) || !Number.isFinite(output)) continue;
      const cachedInput = Number(model.pricing?.cachedInputTokens);
      const cacheWrite = Number(model.pricing?.cacheCreationInputTokens);
      prices.set(model.id, {
        input,
        output,
        ...(Number.isFinite(cachedInput) && model.pricing?.cachedInputTokens ? { cachedInput } : {}),
        ...(Number.isFinite(cacheWrite) && model.pricing?.cacheCreationInputTokens ? { cacheWrite } : {}),
      });
    }
    pricingCache = { at: Date.now(), prices };
  }
  return pricingCache.prices.get(id) ?? null;
}

/** Default evaluation model that decides whether shared text is really a link (AI Gateway id). */
export const DEFAULT_EVALUATION_MODEL = "typesafe-ai/jev";

/** Evaluation model id (`AI_EVALUATION_MODEL`); `off` disables it, so text that mixes prose and a URL is summarised as text. */
export function evaluationModelId(): string | null {
  const configured = process.env.AI_EVALUATION_MODEL?.trim();
  if (configured && /^(off|none|false)$/i.test(configured)) return null;
  return configured || DEFAULT_EVALUATION_MODEL;
}

export function evaluationModel(id: string): Experimental_EvaluationModel {
  return gateway().evaluationModel(id);
}

/** Default embedding model for natural-language search (AI Gateway id). */
export const DEFAULT_EMBEDDING_MODEL = "openai/text-embedding-3-small";

/** Embedding model id (`AI_EMBEDDING_MODEL`); `off` disables semantic search (keyword search only). */
export function embeddingModelId(): string | null {
  const configured = process.env.AI_EMBEDDING_MODEL?.trim();
  if (configured && /^(off|none|false)$/i.test(configured)) return null;
  return configured || DEFAULT_EMBEDDING_MODEL;
}

export function embeddingModel(id: string): EmbeddingModel {
  return gateway().embeddingModel(id);
}

/** Configured illustration model id (`AI_IMAGE_MODEL`), e.g. `google/gemini-3.1-flash-lite-image`; null disables "illustration". */
export function imageModelId(): string | null {
  return process.env.AI_IMAGE_MODEL?.trim() || null;
}

/**
 * Gemini image models are multimodal *language* models that answer with image file parts; the
 * Gateway refuses them through `generateImage` ("is a language model, not an image model").
 */
export function isLanguageImageModel(id: string): boolean {
  return /(^|\/)gemini-/i.test(id);
}

/** The illustration model as a language model (Gemini-style: call `generateText`, read `result.files`). */
export function imageLanguageModel(id: string): LanguageModel {
  return gateway()(id);
}

/** The illustration model as a dedicated image model (e.g. `openai/gpt-image-2`: call `generateImage`). */
export function dedicatedImageModel(id: string): ImageModel {
  return gateway().imageModel(id);
}

/** Per-attempt budget for the illustration call. Override with `AI_IMAGE_TIMEOUT_MS`. */
export function imageTimeoutMs(): number {
  const configured = Number(process.env.AI_IMAGE_TIMEOUT_MS);
  return Number.isFinite(configured) && configured > 0 ? configured : 60_000;
}

/** Tour narration model (`AI_TOUR_MODEL`): pick a fast one, it writes every scene of a trip tour. Defaults to the text model. */
export function tourModelId(): string {
  return process.env.AI_TOUR_MODEL?.trim() || textModelId();
}

export function tourModel(): LanguageModel {
  return cachedChatModel(tourModelId());
}

/** Default narrator; MAI voices are multilingual, so one voice reads every language. */
export const DEFAULT_TOUR_VOICE = "en-US-Harper";
/** MAI-Voice-2.1-Flash's list price per input character (US$15 per million), when `AI_SPEECH_USD_PER_CHARACTER` isn't set. */
const DEFAULT_SPEECH_USD_PER_CHARACTER = 0.000015;

/** Speech model that reads tours aloud (`AI_SPEECH_MODEL`, an AI Gateway id); null when unset, so tours play as subtitles only. */
export function speechModelId(): string | null {
  return process.env.AI_SPEECH_MODEL?.trim() || null;
}

/** Narrator voice (`AI_TOUR_VOICE`). */
export function tourVoice(): string {
  return process.env.AI_TOUR_VOICE?.trim() || DEFAULT_TOUR_VOICE;
}

export function speechModel(id: string): SpeechModel {
  return gateway().speechModel(id);
}

/** Price per spoken character in USD (`AI_SPEECH_USD_PER_CHARACTER`), used to charge points for narration. */
export function speechUsdPerCharacter(): number {
  const configured = Number(process.env.AI_SPEECH_USD_PER_CHARACTER);
  return Number.isFinite(configured) && configured >= 0 && process.env.AI_SPEECH_USD_PER_CHARACTER?.trim() ? configured : DEFAULT_SPEECH_USD_PER_CHARACTER;
}
