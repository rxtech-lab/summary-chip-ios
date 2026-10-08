import type { LanguageModelV4, LanguageModelV4CallOptions } from "@ai-sdk/provider";
import { describe, expect, it, vi } from "vitest";
import { narrateTour, type TourNarrationInput } from "@/lib/ai/tour-agent";

const input = (count: number): TourNarrationInput => ({
  language: "English",
  trip: { title: "Kyoto" },
  scenes: Array.from({ length: count }, (_, index) => ({ kind: "place", facts: { name: `Place ${index + 1}` } })),
});
const entries = (numbers: number[]) => numbers.map((sceneNumber) => ({
  sceneNumber, title: `Place ${sceneNumber}`, narration: `Story for place ${sceneNumber}.`,
}));
const stories = (count: number) => entries(Array.from({ length: count }, (_, index) => index + 1))
  .map(({ title, narration }) => ({ title, narration, visuals: [] }));

function scriptedModel(respond: (call: LanguageModelV4CallOptions, index: number) => unknown) {
  const calls: LanguageModelV4CallOptions[] = [];
  const model: LanguageModelV4 = {
    specificationVersion: "v4", provider: "mock", modelId: "tour", supportedUrls: {},
    async doGenerate(options) {
      calls.push(options);
      return {
        content: [{ type: "text", text: JSON.stringify(respond(options, calls.length - 1)) }],
        finishReason: { unified: "stop", raw: "stop" },
        usage: { inputTokens: { total: 1, noCache: 1, cacheRead: 0, cacheWrite: 0 }, outputTokens: { total: 1, text: 1, reasoning: 0 } },
        warnings: [],
      };
    },
    async doStream() { throw new Error("not streamed"); },
  };
  return { model, calls };
}

describe("tour narrator", () => {
  it("compiles museum and garden cues from the custom UI while restricting each scene's sources", async () => {
    const tour = input(2);
    tour.places = [{ id: "tokyo", name: "Tokyo", photos: [{ index: 0, caption: "Tokyo Station" }] }];
    tour.imageGroups = [{ id: "aoyama:gallery", title: "Aoyama", photos: [{ index: 0, caption: "Nezu Museum entrance" }, { index: 1, caption: "Nezu Museum's garden paths" }] }];
    tour.scenes[0] = { kind: "day", facts: { date: "2026-10-11", title: "Nezu Museum" }, placeIds: ["tokyo"], imageGroupIds: ["aoyama:gallery"] };
    tour.scenes[1] = { kind: "day", facts: { date: "2026-10-12" }, placeIds: ["tokyo"] };
    const { model, calls } = scriptedModel(() => ({ scenes: [
      { sceneNumber: 1, title: "A quiet garden", landmarks: [{ number: 1, name: "Nezu Museum", nearPlaceId: "tokyo" }], narration: "October 11, 2026. [NAVIGATE_LANDMARK_1][SHOW_IMAGE_1_1]Let's explore the garden paths." },
      { sceneNumber: 2, title: "Another day", narration: "[SHOW_IMAGES_1]A new story in Tokyo." },
    ] }));
    const scenes = await narrateTour(model, tour);
    expect(scenes[0]).toMatchObject({ narration: "October 11, 2026. Let's explore the garden paths.", landmarks: [{ id: "landmark-1", name: "Nezu Museum", nearPlaceId: "tokyo" }], visuals: [
      { textOffset: 18, landmarkId: "landmark-1", photoIndex: null },
      { textOffset: 18, landmarkId: "landmark-1", imageGroupId: "aoyama:gallery", photoIndex: 1 },
    ] });
    expect(scenes[1].visuals).toEqual([]);
    expect(JSON.stringify(calls[0].prompt)).toContain("Nezu Museum's garden paths");
    expect(JSON.stringify(calls[0].prompt)).toContain("[SHOW_IMAGE_1_1]");
  });

  it("compiles inline navigation and photo commands while keeping detailed dated speech clean", async () => {
    const tour = input(1);
    tour.scenes[0].facts = { date: "2026-10-10", route: { stops: ["X", "Y"] } };
    tour.scenes[0].placeIds = ["garden"];
    tour.places = [{ id: "garden", name: "Old garden", photos: [{ index: 0, caption: "The entrance" }, { index: 1, caption: "The winding path" }] }];
    const narration = "October 10, 2026. Today we're traveling from X to Y to explore the old garden. "
      + "Look for the winding path and notice how it invites us to explore the garden's quieter corners. ".repeat(14);
    const script = narration.replace("the old garden", "[NAVIGATE_TO_GARDEN][SHOW_PHOTO_GARDEN_1][NAVIGATE_TO_UNKNOWN][SHOW_PHOTO_GARDEN_3]the old garden");
    const { model, calls } = scriptedModel(() => ({ scenes: [{
      sceneNumber: 1, title: "A garden's stories", narration: script,
    }] }));
    const [scene] = await narrateTour(model, tour);
    expect(narration.length).toBeGreaterThan(1200);
    expect(scene).toEqual({ title: "A garden's stories", narration: narration.trim(), visuals: [
      { textOffset: narration.indexOf("the old garden"), placeId: "garden", photoIndex: null },
      { textOffset: narration.indexOf("the old garden"), placeId: "garden", photoIndex: 1 },
    ] });
    expect(JSON.stringify(calls[0].prompt)).toContain("The winding path");
    expect(JSON.stringify(calls[0].prompt)).toContain("2026-10-10");
    expect(JSON.stringify(calls[0].prompt)).toContain("[NAVIGATE_TO_GARDEN]");
  });

  it("recovers when a ten-scene batch returns only eight, accounting for every attempt", async () => {
    const responses = [entries([1, 2, 3, 4, 5, 6, 7, 8]), entries([1, 2, 3, 4, 5]), entries([6, 7, 8, 9, 10])];
    const { model, calls } = scriptedModel((_, index) => ({ scenes: responses[index] }));
    const usage = vi.fn();
    expect(await narrateTour(model, input(10), { onUsage: usage })).toEqual(stories(10));
    expect(calls).toHaveLength(3);
    expect(usage).toHaveBeenCalledTimes(3);
  });

  it("recovers from an out-of-range scene number even when that entry declares landmarks", async () => {
    const tour = input(2);
    tour.places = [{ id: "tokyo", name: "Tokyo", photos: [] }];
    tour.scenes.forEach((scene) => { scene.placeIds = ["tokyo"]; });
    const { model, calls } = scriptedModel((_, index) => ({ scenes: index === 0
      ? [{ ...entries([99])[0], landmarks: [{ number: 1, name: "Nezu Museum", nearPlaceId: "tokyo" }] }, entries([2])[0]]
      : entries([index]),
    }));
    expect(await narrateTour(model, tour)).toEqual(stories(2));
    expect(calls).toHaveLength(3);
  });

  it("matches narration to its scene even when the model returns the entries out of order", async () => {
    const { model, calls } = scriptedModel(() => ({ scenes: entries([3, 1, 2]) }));
    expect(await narrateTour(model, input(3))).toEqual(stories(3));
    expect(calls).toHaveLength(1);
  });

  it("keeps scene numbering and ordering across concurrent batches and recovery calls", async () => {
    const { model, calls } = scriptedModel((call, index) => {
      const prompt = call.prompt.flatMap((message) => message.role === "user"
        ? message.content.flatMap((part) => part.type === "text" ? [part.text] : []) : []).join("\n");
      const scenes = JSON.parse(prompt.match(/<scenes>\n(.*?)\n<\/scenes>/s)![1]) as { sceneNumber: number }[];
      const numbers = scenes.map((scene) => scene.sceneNumber);
      return { scenes: entries(index === 0 ? numbers.slice(0, 8) : numbers.toReversed()) };
    });
    expect(await narrateTour(model, input(24))).toEqual(stories(24));
    expect(calls).toHaveLength(5);
  });

  it("retries duplicate scene numbers instead of assigning the wrong story to a stop", async () => {
    const responses = [entries([1, 1, 3]), entries([1, 2]), entries([3])];
    const { model, calls } = scriptedModel((_, index) => ({ scenes: responses[index] }));
    expect(await narrateTour(model, input(3))).toEqual(stories(3));
    expect(calls).toHaveLength(3);
  });

  it("stops when even a single-scene response is incomplete", async () => {
    const { model, calls } = scriptedModel(() => ({ scenes: [] }));
    const usage = vi.fn();
    await expect(narrateTour(model, input(1), { onUsage: usage })).rejects.toThrow();
    expect(calls).toHaveLength(1);
    expect(usage).toHaveBeenCalledTimes(1);
  });

  it("does not split a batch when its provider fails", async () => {
    const { model, calls } = scriptedModel(() => { throw new Error("provider unavailable"); });
    await expect(narrateTour(model, input(10))).rejects.toThrow("provider unavailable");
    expect(calls).toHaveLength(1);
  });

  it("does not start recovery calls after cancellation", async () => {
    const controller = new AbortController();
    const { model, calls } = scriptedModel(() => ({ scenes: entries([1, 2, 3, 4, 5, 6, 7, 8]) }));
    await expect(narrateTour(model, input(10), {
      abortSignal: controller.signal,
      onUsage: () => controller.abort(),
    })).rejects.toThrow();
    expect(calls).toHaveLength(1);
  });
});
