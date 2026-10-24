import { generateSpeech } from "ai";
import { joinPodcastAudio } from "@/lib/services/podcast-audio";
import { createGateway } from "@ai-sdk/gateway";
import { describe, expect, it } from "vitest";
import { writePodcast } from "@/lib/ai/podcast-agent";

// Opt-in real SDK/HTTP test; start the committed Postman simulation first.
describe.skipIf(!process.env.PODCAST_SIMULATION_URL)("podcast narration over HTTP", () => {
  it("uses the gateway SDK and validates grounded multi-host output", async () => {
    const gateway = createGateway({ baseURL: process.env.PODCAST_SIMULATION_URL, apiKey: "local-fixture-only" });
    const script = await writePodcast(gateway("fixture/podcast"), {
      language: "English", voices: ["voice-a", "voice-b"],
      chips: [
        { id: "one", title: "Science", summary: "A scientific discovery.", highlights: [] },
        { id: "two", title: "Culture", summary: "A cultural observation.", highlights: [] },
      ],
    });
    expect(script.speakers).toHaveLength(2);
    expect(script.segments.map((s) => [s.chipId, s.speaker])).toEqual([["one", 0], ["two", 1]]);
    const speech = await Promise.all(script.segments.map((segment) => generateSpeech({
      model: gateway.speechModel("fixture/speech"), text: segment.caption,
      voice: script.speakers[segment.speaker].voice, outputFormat: "mp3",
    })));
    const recording = joinPodcastAudio(speech.map((result) => result.audio.uint8Array));
    expect(recording.durationSeconds).toBeGreaterThan(0);
    expect(recording.cues[1].startSeconds).toBe(recording.cues[0].endSeconds);
  });
});
