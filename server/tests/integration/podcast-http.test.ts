import { writePodcastArticle } from "@/lib/ai/podcast-article";
import type { DailyPodcast } from "@/lib/contracts/daily-podcast";
import { transcribePodcastAudio } from "@/lib/ai/podcast-transcription";
import { alignPodcastCaptions } from "@/lib/services/podcast-captions";
import { generateSpeech } from "ai";
import { joinPodcastAudio } from "@/lib/services/podcast-audio";
import { createGateway } from "@ai-sdk/gateway";
import { describe, expect, it } from "vitest";
import { writePodcast } from "@/lib/ai/podcast-agent";

// Opt-in real SDK/HTTP test; start the committed Postman simulation first.
describe.skipIf(!process.env.PODCAST_SIMULATION_URL)("podcast narration over HTTP", () => {
  it("writes a structured article through the gateway HTTP contract", async () => {
    const gateway = createGateway({ baseURL: process.env.PODCAST_SIMULATION_URL, apiKey: "local-fixture-only" });
    const article = await writePodcastArticle(gateway("fixture/podcast"), {
      title: "Discoveries", language: "en", segments: [{ caption: "A scientific discovery." }, { caption: "A cultural observation." }],
    } as DailyPodcast);
    expect(article.sections.map(s => s.segmentIndex)).toEqual([0, 1]);
    expect(article.description).toContain("discoveries");
  });
  it("requests segment timestamps over HTTP and restores the original text", async () => {
    const gateway = createGateway({ baseURL: process.env.PODCAST_SIMULATION_URL, apiKey: "local-fixture-only" });
    const segments = await transcribePodcastAudio(new Uint8Array([255, 251, 144, 192]), undefined,
      gateway.transcriptionModel("mistral/voxtral-mini-transcribe-3"));
    expect(alignPodcastCaptions("Welcome to RxLab! Here is the news.", segments)).toEqual([
      { text: "Welcome to RxLab", startSeconds: 0.3, endSeconds: 2.1 },
      { text: "Here is the news", startSeconds: 2.8, endSeconds: 4.2 },
    ]);
  });
  it("writes a reviewable script with a camera storyboard through the real HTTP adapter", async () => {
    const gateway = createGateway({ baseURL: process.env.PODCAST_SIMULATION_URL, apiKey: "local-fixture-only" });
    const script = await writePodcast(gateway("fixture/podcast"), {
      language: "English", voices: ["voice-a"], storyboard: true,
      chips: [{ id: "one", title: "Science", summary: "A scientific discovery.", highlights: [] }],
    });
    expect(script.segments[0].camera).toContain("slow push in");
    expect(script.segments[0].caption).toBe("A scientific discovery.");
  });
  it("uses the gateway SDK and validates grounded multi-host output", async () => {
    const gateway = createGateway({ baseURL: process.env.PODCAST_SIMULATION_URL, apiKey: "local-fixture-only" });
    const script = await writePodcast(gateway("fixture/podcast"), {
      language: "English", voices: ["voice-a", "voice-b"], speakerNames: ["小明", "Jane"],
      chips: [
        { id: "one", title: "Science", summary: "A scientific discovery.", highlights: [] },
        { id: "two", title: "Culture", summary: "A cultural observation.", highlights: [] },
      ],
    });
    expect(script.speakers.map((speaker) => speaker.name)).toEqual(["小明", "Jane"]);
    expect(script.segments.map((s) => [s.chipId, s.speaker])).toEqual([["one", 0], ["two", 1]]);
    const speech = await Promise.all(script.segments.map((segment) => generateSpeech({
      model: gateway.speechModel("fixture/speech"), text: segment.caption,
      voice: script.speakers[segment.speaker].voice, outputFormat: "mp3",
    })));
    const recording = joinPodcastAudio(speech.map((result) => result.audio.uint8Array));
    expect(recording.durationSeconds).toBeGreaterThan(0);
    expect(recording.cues[1].startSeconds).toBe(recording.cues[0].endSeconds);
  });
  it("accepts more than 24 grounded turns through the gateway SDK", async () => {
    const gateway = createGateway({ baseURL: process.env.PODCAST_SIMULATION_URL, apiKey: "local-fixture-only" });
    const chips = Array.from({ length: 30 }, (_, index) => ({
      id: `chip-${index}`, title: `Discovery ${index}`, summary: `Finding ${index}.`, highlights: [],
    }));
    const script = await writePodcast(gateway("fixture/podcast"), { language: "English", voices: ["voice-a"], chips });
    expect(script.segments.map((segment) => segment.chipId)).toEqual(chips.map((chip) => chip.id));
  });

});
