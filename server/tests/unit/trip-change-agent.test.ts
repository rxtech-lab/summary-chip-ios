import type { LanguageModelV4, LanguageModelV4CallOptions } from "@ai-sdk/provider";
import { describe, expect, it } from "vitest";
import { summarizeTripChanges, tripChanges } from "@/lib/ai/trip-change-agent";
import { tripDocumentSchema } from "@/lib/contracts/trip";

const before = tripDocumentSchema.parse({ title: "Kyoto", startDate: "2026-11-06", endDate: "2026-11-08" });

describe("trip change agent", () => {
  it("returns a bounded structured notification with no editing tools and redacts booking secrets", async () => {
    const calls: LanguageModelV4CallOptions[] = [];
    const model: LanguageModelV4 = {
      specificationVersion: "v4", provider: "mock", modelId: "notification-agent", supportedUrls: {},
      async doGenerate(options) {
        calls.push(options);
        return {
          content: [{ type: "text", text: JSON.stringify({ body: "Booked the Kyoto hotel for 6–8 November." }) }],
          finishReason: { unified: "stop", raw: "stop" },
          usage: { inputTokens: { total: 1, noCache: 1, cacheRead: 0, cacheWrite: 0 }, outputTokens: { total: 1, text: 1, reasoning: 0 } },
          warnings: [],
        };
      },
      async doStream() { throw new Error("not streamed"); },
    };
    const body = await summarizeTripChanges(model, { language: "en", changes: [
      { section: "hotels", id: "hotel", before: null, after: { name: "Kyoto hotel", checkIn: "2026-11-06", checkOut: "2026-11-08", confirmation: "SECRET-123", bookingRef: "SECRET-456" } },
      { section: "notes", before: null, after: "x".repeat(60_000) },
      { section: "title", before: "Kyoto", after: "Kyoto weekend" },
    ] });
    expect(body).toBe("Booked the Kyoto hotel for 6–8 November.");
    expect(calls).toHaveLength(1);
    expect(calls[0].tools ?? []).toHaveLength(0);
    const prompt = JSON.stringify(calls[0].prompt);
    expect(prompt).not.toContain("SECRET");
    expect(prompt).toContain("Kyoto weekend");
    expect(prompt).toContain("2026-11-06");
    expect(prompt.length).toBeLessThan(55_000);
  });

  it("detects record deletion and updates by stable id without treating reordering as a change", () => {
    const original = { ...before, notes: [{ id: "a", title: "First", text: "Original" }, { id: "b", title: "Second", text: "Unchanged" }] };
    expect(tripChanges(original, { ...original, notes: [...original.notes].reverse() })).toEqual([]);
    const changes = tripChanges(original, { ...original, notes: [{ ...original.notes[0], text: "Final" }] });
    expect(changes).toEqual([
      { section: "notes", id: "a", before: original.notes[0], after: { ...original.notes[0], text: "Final" } },
      { section: "notes", id: "b", before: original.notes[1], after: null },
    ]);
  });
});
