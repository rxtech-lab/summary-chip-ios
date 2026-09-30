import { createGateway, type GatewayProvider } from "@ai-sdk/gateway";
import type { ImageModel, LanguageModel } from "ai";

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
  return gateway()(textModelId());
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
