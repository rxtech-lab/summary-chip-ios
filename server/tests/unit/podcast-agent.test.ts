import type { LanguageModelV4, LanguageModelV4CallOptions } from "@ai-sdk/provider";
import { NoObjectGeneratedError } from "ai";
import { expect, it, vi } from "vitest";
import { writePodcast, type PodcastInput } from "@/lib/ai/podcast-agent";

const chipId = "fa3a7127-8e54-4cf0-a01e-d30f63ea14cb";
const input: PodcastInput = { language: "Chinese", voices: ["en-US-Harper"], speakerNames: ["Harper"],
  chips: [{ id: chipId, title: "Decision models", summary: "Measuring progress", highlights: [] }] };
const script = { title: "Decision models", mood: "focused", speakers: [{ name: "Harper", voice: "en-US-Harper" }],
  segments: [{ speaker: 0, chipId, caption: "欢迎收听今天的播客。" }] };
function scriptedModel(respond: (index: number) => unknown) {
  const calls: LanguageModelV4CallOptions[] = [];
  const model: LanguageModelV4 = {
    specificationVersion: "v4", provider: "mock", modelId: "podcast", supportedUrls: {},
    async doGenerate(options) {
      calls.push(options);
      return { content: [{ type: "text", text: JSON.stringify(respond(calls.length - 1)) }],
        finishReason: { unified: "stop", raw: "stop" },
        usage: { inputTokens: { total: 1, noCache: 1, cacheRead: 0, cacheWrite: 0 }, outputTokens: { total: 1, text: 1, reasoning: 0 } }, warnings: [] };
    },
    async doStream() { throw new Error("not streamed"); },
  };
  return { model, calls };
}

it("recovers from the production extra-character chip ID error and accounts for both calls", async () => {
  const { model, calls } = scriptedModel(index => index === 0
    ? { ...script, segments: [{ ...script.segments[0], chipId: "fa3a71277-8e54-4cf0-a01e-d30f63ea14cb" }] } : script);
  const onUsage = vi.fn();
  expect(await writePodcast(model, input, { onUsage })).toEqual(script);
  expect(calls).toHaveLength(2);
  expect(onUsage).toHaveBeenCalledTimes(2);
  expect(JSON.stringify(calls[1].prompt)).toContain("previous script failed validation");
  const format = calls[0].responseFormat;
  expect(format?.type).toBe("json");
  if (format?.type !== "json") throw new Error("Expected JSON schema");
  expect(format.schema).toMatchObject({ properties: {
    speakers: { minItems: 1, maxItems: 1, items: { properties: { voice: { enum: input.voices } } } },
    segments: { items: { properties: { chipId: { enum: [chipId] }, speaker: { maximum: 0 } } } },
  } });
});

it("returns valid output without a correction call", async () => {
  const { model, calls } = scriptedModel(() => script);
  expect(await writePodcast(model, input)).toEqual(script);
  expect(calls).toHaveLength(1);
});

it("stops after one correction and never accepts invalid references or omitted chips", async () => {
  for (const invalid of [
    { ...script, segments: [{ ...script.segments[0], chipId: "unknown" }] },
    { ...script, speakers: [{ name: "Harper", voice: "unknown" }] },
    { ...script, segments: [{ ...script.segments[0], speaker: 1 }] },
    { ...script, speakers: [{ name: "Wrong name", voice: input.voices[0] }] },
    { ...script, segments: [] },
  ]) {
    const { model, calls } = scriptedModel(() => invalid);
    await expect(writePodcast(model, input)).rejects.toBeInstanceOf(NoObjectGeneratedError);
    expect(calls).toHaveLength(2);
  }
  const { model, calls } = scriptedModel(() => script);
  await expect(writePodcast(model, { ...input, chips: [...input.chips, { ...input.chips[0], id: "another" }] })).rejects.toBeInstanceOf(NoObjectGeneratedError);
  expect(calls).toHaveLength(2);
});

it("does not retry ordinary provider errors or an expired deadline", async () => {
  const failure = new Error("Provider unavailable");
  const { model, calls } = scriptedModel(() => { throw failure; });
  await expect(writePodcast(model, input)).rejects.toThrow("Provider unavailable");
  expect(calls).toHaveLength(1);
  const controller = new AbortController();
  const aborted = scriptedModel(() => { controller.abort(); return {}; });
  await expect(writePodcast(aborted.model, input, { abortSignal: controller.signal })).rejects.toThrow();
  expect(aborted.calls).toHaveLength(1);
});
