import type { BackgroundJob } from "@/lib/contracts/background-jobs";

/** Do not expose SDK messages: they can contain credentials, prompts or provider response bodies. */
export function podcastVideoError(error: unknown): NonNullable<BackgroundJob["error"]> {
  const cause = error as { name?: string; statusCode?: number; cause?: { name?: string } } | undefined;
  if (cause?.name === "AI_ToolChoiceViolationError" || cause?.name === "PodcastVideoNoToolError") {
    return { code: "PODCAST_VIDEO_NO_TOOL", message: "The video model returned without saving a file or submitting a script. Please retry video design." };
  }
  if (cause?.name === "TimeoutError" || cause?.name === "AbortError" || cause?.cause?.name === "TimeoutError") {
    return { code: "PODCAST_VIDEO_TIMEOUT", message: "The video model did not finish a script-writing turn within 4 minutes. Please try again." };
  }
  if (cause?.statusCode === 401 || cause?.statusCode === 403) {
    return { code: "PODCAST_VIDEO_AUTH", message: `The video provider refused access (HTTP ${cause.statusCode}). Check the server's model credentials and permissions.` };
  }
  if (cause?.statusCode === 429) return { code: "PODCAST_VIDEO_RATE_LIMIT", message: "The video provider's rate or usage limit was reached (HTTP 429). Please try again later." };
  if (cause?.statusCode && cause.statusCode >= 400) {
    return { code: "PODCAST_VIDEO_PROVIDER", message: `The video provider rejected the request (HTTP ${cause.statusCode}). Check the server logs and model configuration.` };
  }
  return { code: "PODCAST_VIDEO_FAILED", message: "The video model request failed. Check the server logs for details, then retry video design." };
}
