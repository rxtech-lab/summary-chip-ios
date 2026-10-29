import { describe, expect, it } from "vitest";
import { storyboardInstruction } from "@/lib/ai/provider";
import { planFrames, storyboardFrameHash } from "@/lib/services/podcast-plans";

const shot = { camera: "A battery diagram builds from cells into a pack, then highlights its output.", caption: "Researchers connected the cells.", chipTitle: "Battery research" };

describe("motion storyboard", () => {
  it("uses the final video's art direction and shows four content and animation states", () => {
    const news = storyboardInstruction({ ...shot, style: "news" });
    const crayon = storyboardInstruction({ ...shot, style: "crayon" });
    const update = storyboardInstruction({ ...shot, style: "update" });
    expect(news).toContain("#009B85");
    expect(crayon).toContain("#FBF5E6");
    expect(crayon).toContain("crayon scribble");
    expect(update).toContain("software update keynote");
    for (const prompt of [news, crayon, update]) {
      expect(prompt).toContain("2-by-2 grid");
      expect(prompt).toContain("entrance and initial objects");
      expect(prompt).toContain("short readable headings");
      expect(prompt).toContain(shot.caption);
      expect(prompt).not.toContain("NO text of any kind");
    }
  });

  it("invalidates legacy stills and changes in narration, direction or style", () => {
    const key = storyboardFrameHash(shot.camera, shot.caption, "news");
    expect(storyboardFrameHash(shot.camera, shot.caption, "crayon")).not.toBe(key);
    expect(storyboardFrameHash(shot.camera, "New claim", "news")).not.toBe(key);
    expect(storyboardFrameHash("New movement", shot.caption, "news")).not.toBe(key);
    const frame = { key: "private/frame.png", width: 1280, height: 720 };
    const plan = { script: { title: "Battery", mood: "calm" as const, speakers: [{ name: "Alex", voice: "v" }], segments: [{ ...shot, chipId: "chip", speaker: 0 }] }, input: { videoStyle: "news" as const, day: { start: "2030-01-01T00:00:00Z", end: "2030-01-02T00:00:00Z" }, language: "en" as const, regenerate: true, library: false }, frames: { legacy: frame } };
    expect(planFrames(plan)).toEqual([null]);
    expect(planFrames({ ...plan, frames: { [key]: frame } })).toEqual([frame]);
  });
});
