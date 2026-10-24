import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { joinPodcastAudio } from "@/lib/services/podcast-audio";

const fixture = (name: string) => readFileSync(new URL(`../fixtures/podcast/${name}.mp3`, import.meta.url));
describe("continuous podcast MP3", () => {
  it("remuxes constant and variable bitrate recordings with exact contiguous caption cues", () => {
    const one = joinPodcastAudio([fixture("one")]);
    const two = joinPodcastAudio([fixture("two")]);
    const result = joinPodcastAudio([fixture("one"), fixture("two")]);
    expect(result.durationSeconds).toBeCloseTo(one.durationSeconds + two.durationSeconds, 8);
    expect(result.cues).toEqual([{ startSeconds: 0, endSeconds: one.durationSeconds },
      { startSeconds: one.durationSeconds, endSeconds: result.durationSeconds }]);
    // Re-reading the output must yield all audio frames, rather than treating the first turn as the whole file.
    expect(joinPodcastAudio([result.bytes]).durationSeconds).toBeCloseTo(result.durationSeconds, 8);
    expect(result.durationSeconds).toBeGreaterThan(0.9);
  });
  it("rejects corrupt or incompatible audio instead of publishing a partial recording", () => {
    expect(() => joinPodcastAudio([new Uint8Array([1, 2, 3])])).toThrow();
    expect(() => joinPodcastAudio([fixture("one").subarray(0, 90)])).toThrow();
    const stereo = new Uint8Array(417);
    stereo.set([0xff, 0xfb, 0x90, 0]);
    expect(() => joinPodcastAudio([fixture("one"), stereo])).toThrow(/channel/);
  });
});
