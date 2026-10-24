import { transcribe, type TranscriptionModel } from "ai";
import { transcriptionModel } from "./models";

export async function transcribePodcastAudio(audio: Uint8Array, options?: { abortSignal?: AbortSignal }, model: TranscriptionModel = transcriptionModel()) {
  const result = await transcribe({
    model, audio, maxRetries: 0,
    providerOptions: { mistral: { timestampGranularities: ["segment"] } },
    abortSignal: options?.abortSignal ? AbortSignal.any([options.abortSignal, AbortSignal.timeout(45_000)]) : AbortSignal.timeout(45_000),
  });
  return result.segments;
}
