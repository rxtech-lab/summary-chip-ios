import type { LanguageModelV4, LanguageModelV4CallOptions } from "@ai-sdk/provider";
import { NoObjectGeneratedError } from "ai";
import { expect, it, vi } from "vitest";
import { writePodcast, type PodcastInput } from "@/lib/ai/podcast-agent";

const chipId = "fa3a7127-8e54-4cf0-a01e-d30f63ea14cb";
const input: PodcastInput = { language: "Chinese", voices: ["en-US-Harper"], speakerNames: ["Harper"],
  chips: [{ id: chipId, title: "Decision models", summary: "Measuring progress", highlights: [] }] };
const script = { title: "Decision models", summary: "An overview of decision models and how they measure progress.", mood: "focused", speakers: [{ name: "Harper", voice: "en-US-Harper" }],
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

it("allows a recap to select highlights while keeping chip references valid", async () => {
  const recap = { ...input, recap: true, chips: [...input.chips, { ...input.chips[0], id: "other-story" }] };
  const { model } = scriptedModel(() => ({ ...script, rankedChipIds: [chipId] }));
  expect(await writePodcast(model, recap)).toEqual(script);
});


it.each([[30, 39], [90, 117], [125, 162], [179, 232], [180, 234], [360, 468], [1800, 2340]])("orders highlights by importance within the %s-second budget", async (maxDurationSeconds, words) => {
  const recap = { ...input, recap: true, maxDurationSeconds, chips: [...input.chips, { ...input.chips[0], id: "important" }, { ...input.chips[0], id: "unimportant" }] };
  const low = { ...script.segments[0], caption: "Less important." };
  const first = { ...script.segments[0], chipId: "important", caption: "Major development." };
  const second = { ...first, caption: "Its impact." };
  const { model, calls } = scriptedModel(() => ({ ...script, segments: [low, first, second], rankedChipIds: ["important", chipId] }));
  const result = await writePodcast(model, recap);
  expect(result.segments).toEqual([first, second, low]);
  expect(result).not.toHaveProperty("rankedChipIds");
  expect(JSON.stringify(calls[0].prompt)).toContain("descending importance");
  expect(JSON.stringify(calls[0].prompt)).toContain(`${words} words`);
});

it("rejects duplicate or inconsistent selected-chip rankings", async () => {
  for (const rankedChipIds of [[chipId, chipId], ["missing"], [chipId, "unused"]]) {
    const recap = { ...input, recap: true, chips: [...input.chips, { ...input.chips[0], id: "unused" }] };
    const { model } = scriptedModel(() => ({ ...script, rankedChipIds }));
    await expect(writePodcast(model, recap)).rejects.toBeInstanceOf(NoObjectGeneratedError);
  }
});

it("requires a summary below 200 words and repairs invalid summaries", async () => {
  for (const summary of [undefined, "", Array(200).fill("word").join(" "), "这是一个重要的新闻。".repeat(80)]) {
    const { model, calls } = scriptedModel(index => index === 0 ? { ...script, summary } : script);
    expect((await writePodcast(model, input)).summary).toBe(script.summary);
    expect(calls).toHaveLength(2);
  }
  const summary = Array(199).fill("word").join(" ");
  const { model } = scriptedModel(() => ({ ...script, summary }));
  expect((await writePodcast(model, input)).summary).toBe(summary);
});


it("treats the manual duration as approximate narration guidance", async () => {
  const { model, calls } = scriptedModel(() => ({ ...script, rankedChipIds: [chipId] }));
  await writePodcast(model, { ...input, recap: true, maxDurationSeconds: 30, approximateDuration: true });
  expect(JSON.stringify(calls[0].prompt)).toContain("approximately 30 seconds");
  expect(JSON.stringify(calls[0].prompt)).toContain("not a hard cap");
  expect(JSON.stringify(calls[0].prompt)).not.toContain("at most 39 words");
});
