import type { LanguageModelV4, LanguageModelV4CallOptions } from "@ai-sdk/provider";
import { describe, expect, it } from "vitest";
import { briefTripDay, tripBriefingInput } from "@/lib/ai/trip-briefing-agent";
import { tripDocumentSchema } from "@/lib/contracts/trip";

const document = tripDocumentSchema.parse({
  title: "Kyoto", startDate: "2030-04-01", endDate: "2030-04-02", timeZone: "Asia/Tokyo",
  days: [
    { id: "tomorrow", date: "2030-04-01", title: "Temple walk", tip: "Pack the rail pass", moments: [{ slot: "morning", time: "10:00", text: "Outdoor temple walk" }] },
    { id: "later", date: "2030-04-02", title: "LATER-DAY-NOT-FOR-THIS-BRIEFING" },
  ],
  transports: [{ id: "train", date: "2030-04-01", label: "Train to Kyoto", selectedOptionId: "selected", options: [
    { id: "unused", label: "UNSELECTED-OPTION", departure: "2030-04-01T08:00" },
    { id: "selected", label: "Train", departure: "2030-04-01T09:00", warning: "Arrive 15 minutes early", segments: [
      { mode: "flight", fromName: "Hong Kong", toName: "Kyoto", flight: { flightNumber: "CX520", gate: "12", seat: "SECRET-SEAT", bookingRef: "SECRET-BOOKING" } },
    ] },
  ] }],
  hotels: [{ id: "hotel", name: "Kyoto hotel", checkIn: "2030-04-01", checkOut: "2030-04-02", checkInTime: "15:00", confirmation: "SECRET-HOTEL" }],
  notes: [{ id: "note", title: "Private", text: "PRIVATE-TRIP-NOTE" }],
});
const forecast = { place: "Kyoto", forecast: {
  date: "2030-04-01", code: 61, high: 18, low: 9, precipitationChance: 70, precipitation: 5, windMax: 15, gustsMax: 30, uvIndexMax: 4, sunrise: null, sunset: null,
} };

function modelReturning(body: string, calls: LanguageModelV4CallOptions[]): LanguageModelV4 {
  return {
    specificationVersion: "v4", provider: "mock", modelId: "trip-briefing", supportedUrls: {},
    async doGenerate(options) {
      calls.push(options);
      return {
        content: [{ type: "text", text: JSON.stringify({ body }) }], finishReason: { unified: "stop", raw: "stop" },
        usage: { inputTokens: { total: 1, noCache: 1, cacheRead: 0, cacheWrite: 0 }, outputTokens: { total: 1, text: 1, reasoning: 0 } }, warnings: [],
      };
    },
    async doStream() { throw new Error("not streamed"); },
  };
}

describe("combined trip briefing agent", () => {
  it("receives only tomorrow's chosen itinerary, preparation notes and forecast without booking secrets", () => {
    const input = tripBriefingInput(document, "2030-04-01", "zh-Hant", [forecast]);
    const text = JSON.stringify(input);
    expect(text).not.toMatch(/SECRET|UNSELECTED|LATER-DAY|PRIVATE-TRIP-NOTE/);
    expect(input).toMatchObject({ language: "zh-Hant", date: "2030-04-01", days: [{ tip: "Pack the rail pass" }], transports: [{ departure: "2030-04-01T09:00", warning: "Arrive 15 minutes early" }], weather: [{ condition: "rain", low: 9, high: 18, precipitationChance: 70 }] });
    expect(input.hotels[0].checkInTime).toBe("15:00");
  });

  it("writes one structured, short briefing with no tools and gives weather its own context budget", async () => {
    const calls: LanguageModelV4CallOptions[] = [];
    const input = tripBriefingInput(document, "2030-04-01", "en", [forecast]);
    input.days[0].tip = "x".repeat(60_000);
    const body = "09:00 train to Kyoto, then a temple walk. Rain, 9–18°C; pack an umbrella and rail pass.";
    expect(await briefTripDay(modelReturning(body, calls), input)).toBe(body);
    expect(calls).toHaveLength(1);
    expect(calls[0].tools ?? []).toHaveLength(0);
    const prompt = JSON.stringify(calls[0].prompt);
    expect(prompt).toContain("2030-04-01T09:00");
    expect(prompt).toContain("precipitationChance");
    expect(prompt).toContain("rain");
    expect(prompt).toContain("untrusted data");
    expect(prompt.length).toBeLessThan(45_000);
  });

  it("rejects empty or oversized model output", async () => {
    const input = tripBriefingInput(document, "2030-04-01", "en", []);
    await expect(briefTripDay(modelReturning(" ", []), input)).rejects.toThrow();
    await expect(briefTripDay(modelReturning("x".repeat(141), []), input)).rejects.toThrow();
  });
});
