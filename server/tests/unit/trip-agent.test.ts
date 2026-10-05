import type { LanguageModelV4, LanguageModelV4CallOptions } from "@ai-sdk/provider";
import { describe, expect, it } from "vitest";
import { runTripAgent } from "@/lib/ai/trip-agent";
import { tripDocumentSchema } from "@/lib/contracts/trip";

/** Answers each agent step with the next scripted `apply_operations` call, recording every prompt and tool list. */
function scriptedModel(steps: Record<string, unknown>[]) {
  const calls: LanguageModelV4CallOptions[] = [];
  const model: LanguageModelV4 = {
    specificationVersion: "v4",
    provider: "mock",
    modelId: "scripted",
    supportedUrls: {},
    async doGenerate(options) {
      calls.push(options);
      const input = steps[calls.length - 1];
      return {
        content: input
          ? [{ type: "tool-call" as const, toolCallId: `c${calls.length}`, toolName: "apply_operations", input: JSON.stringify(input) }]
          : [{ type: "text" as const, text: "Done." }],
        finishReason: input ? { unified: "tool-calls" as const, raw: "tool_calls" } : { unified: "stop" as const, raw: "stop" },
        usage: { inputTokens: { total: 1, noCache: 1, cacheRead: 0, cacheWrite: 0 }, outputTokens: { total: 1, text: 1, reasoning: 0 } },
        warnings: [],
      };
    },
    async doStream() {
      throw new Error("not streamed");
    },
  };
  return { model, calls };
}

const document = tripDocumentSchema.parse({
  title: "Porto",
  startDate: "2026-11-06",
  endDate: "2026-11-08",
  currency: "EUR",
  places: [{ id: "porto", name: "Porto", kind: "city", coordinate: { lat: 41.1579, lng: -8.6291 } }],
  days: [{ id: "day-1", date: "2026-11-06", title: "Ribeira" }],
});
const source = { text: "Hotel Infante Sagres, 6–8 Nov, booking 7781.", title: "Booking", url: "https://example.com/booking", siteName: null };
const hotel = { id: "hotel-infante-sagres", name: "Infante Sagres", placeId: "porto", checkIn: "2026-11-06", checkOut: "2026-11-08", confirmation: "7781", status: "booked" };

describe("runTripAgent", () => {
  it("returns valid operations, dropping malformed ones, and shows the tool the operation schema", async () => {
    const { model, calls } = scriptedModel([{ operations: [{ op: "upsert_hotel", hotel }, { op: "upsert_hotel", hotel: { id: "broken" } }], changeSummary: "Added the hotel." }]);
    const usage: unknown[] = [];
    const result = await runTripAgent(model, { document, source, instructions: "Add my hotel" }, { onUsage: (step) => usage.push(step) });
    expect(result?.changeSummary).toBe("Added the hotel.");
    expect(result?.operations).toEqual([{ op: "upsert_hotel", hotel: expect.objectContaining({ id: "hotel-infante-sagres", status: "booked" }) }]);
    expect(calls).toHaveLength(1);
    expect(usage).toHaveLength(1);
    const tool = calls[0].tools?.find((item) => item.name === "apply_operations");
    expect(JSON.stringify(tool)).toContain("upsert_transport");
    expect(JSON.stringify(tool)).not.toContain("oneOf");
    const prompt = JSON.stringify(calls[0].prompt);
    expect(prompt).toContain("Add my hotel");
    expect(prompt).toContain("booking 7781");
  });

  it("sends a result that breaks the trip back once for a fix", async () => {
    const dangling = { op: "upsert_day", day: { id: "day-2", date: "2026-11-07", title: "Douro", stayId: "nowhere" } };
    const { model, calls } = scriptedModel([
      { operations: [dangling], changeSummary: "x" },
      { operations: [{ op: "upsert_hotel", hotel }, { ...dangling, day: { ...dangling.day, stayId: hotel.id } }], changeSummary: "Added the Douro day." },
    ]);
    const result = await runTripAgent(model, { document, source });
    expect(calls).toHaveLength(2);
    expect(JSON.stringify(calls[1].prompt)).toContain("unknown id");
    expect(result?.operations).toHaveLength(2);
    expect(result?.changeSummary).toBe("Added the Douro day.");
  });

  it("returns null when the agent never applies anything", async () => {
    const { model } = scriptedModel([]);
    expect(await runTripAgent(model, { document, source })).toBeNull();
  });
});
