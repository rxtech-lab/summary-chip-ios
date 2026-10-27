import { afterEach, describe, expect, it, vi } from "vitest";
import { podcastVoices } from "@/lib/ai/models";

afterEach(() => vi.unstubAllEnvs());

describe("podcast voices", () => {
  it.each(["microsoft/mai-voice-2.1", "microsoft/mai-voice-2.1-flash"])("provides four distinct hosts for %s without configuration", model => {
    vi.stubEnv("AI_PODCAST_VOICES", " , ");
    vi.stubEnv("AI_TOUR_VOICE", "en-US-Ethan");
    const voices = podcastVoices(model);
    expect(voices[0]).toBe("en-US-Ethan");
    expect(voices).toHaveLength(4);
    expect(new Set(voices).size).toBe(4);
  });

  it("honors explicit provider voices, removes duplicates and caps at four", () => {
    vi.stubEnv("AI_PODCAST_VOICES", " one, two, one, ,three,four,five ");
    expect(podcastVoices("custom/speech")).toEqual(["one", "two", "three", "four"]);
    vi.stubEnv("AI_PODCAST_VOICES", "only");
    expect(podcastVoices("microsoft/mai-voice-2.1-flash")).toEqual(["only"]);
  });

  it("does not send MAI voices to another provider", () => {
    vi.stubEnv("AI_PODCAST_VOICES", "");
    vi.stubEnv("AI_TOUR_VOICE", "custom-narrator");
    expect(podcastVoices("custom/speech")).toEqual(["custom-narrator"]);
  });
});
