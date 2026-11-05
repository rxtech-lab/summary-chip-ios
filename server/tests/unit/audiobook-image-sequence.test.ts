import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { chapterMetadata, IMAGE_SEQUENCE_RUNNER, imageSequenceManifest, zoompanFilter } from "@/lib/podcast-video/image-sequence";

const segment = (startSeconds: number) => ({ speaker: 0, chipId: "c", caption: "x", imagePath: null, icon: "", startSeconds });

describe("audiobook image sequence", () => {
  it("cuts scenes at whole frames from the running total, so the picture can't drift from the voice", () => {
    const manifest = imageSequenceManifest({ durationSeconds: 10.04, segments: [segment(0.5), segment(3.333), segment(7.777)] },
      [{ file: "a.png", segment: 0, motion: "zoom-in" }, { file: "b.png", segment: 1, motion: "pan-left" }, { file: "a.png", segment: 2, motion: "zoom-out" }], 720);
    expect(manifest.clips.map(clip => clip.frames)).toEqual([80, 107, 54]);
    expect(manifest.clips.reduce((sum, clip) => sum + clip.frames, 0)).toBe(Math.round(10.04 * 24));
    // A repeated image is fetched once.
    expect(manifest.images).toHaveLength(2);
    expect(manifest.width).toBe(1280);
  });

  it("drops scenes with no time on screen rather than asking FFmpeg for zero frames", () => {
    const manifest = imageSequenceManifest({ durationSeconds: 5, segments: [segment(0), segment(0)] },
      [{ file: "a.png", segment: 0, motion: "zoom-in" }, { file: "b.png", segment: 1, motion: "zoom-in" }], 1080);
    expect(manifest.clips).toHaveLength(1);
    expect(manifest.images).toEqual([{ file: "b.png", path: manifest.clips[0].image }]);
  });

  it("budgets the bitrate so a long book stays under the upload limit", () => {
    const short = imageSequenceManifest({ durationSeconds: 600, segments: [] }, [], 1080);
    const long = imageSequenceManifest({ durationSeconds: 4 * 3600, segments: [] }, [], 1080);
    expect(short.videoKbps).toBe(2500);
    expect((long.videoKbps + long.audioKbps) * 1000 / 8 * 4 * 3600).toBeLessThan(1024 ** 3);
  });

  it("escapes chapter titles for FFmpeg's metadata format", () => {
    const text = chapterMetadata({ title: "A = B", chapters: [{ title: "One; two #3", startSegment: 0, endSegment: 1, startSeconds: 1.5, endSeconds: 2 }] });
    expect(text).toContain("title=A \\= B");
    expect(text).toContain("START=1500");
    expect(text).toContain("title=One\\; two \\#3");
  });

  // Runs the real runner with real FFmpeg, offline: only the download step differs from the sandbox (file:// instead of https).
  it("renders a playable MP4 with audio, selectable captions and chapter markers", () => {
    const directory = mkdtempSync(join(tmpdir(), "audiobook-render-"));
    try {
      const run = (args: string[]) => execFileSync("ffmpeg", ["-v", "error", "-y", ...args], { cwd: directory });
      run(["-f", "lavfi", "-i", "color=c=teal:size=1536x864", "-frames:v", "1", "a-source.png"]);
      run(["-f", "lavfi", "-i", "color=c=orange:size=1536x864", "-frames:v", "1", "b-source.png"]);
      run(["-f", "lavfi", "-i", "sine=frequency=330:duration=6", "-c:a", "libmp3lame", "-b:a", "128k", "source.mp3"]);
      const manifest = imageSequenceManifest({ durationSeconds: 6, segments: [segment(0), segment(3)] },
        [{ file: "a", segment: 0, motion: "zoom-in" }, { file: "b", segment: 1, motion: "pan-right" }], 720);
      const sources: Record<string, string> = { a: "a-source.png", b: "b-source.png" };
      const downloads = [{ path: "podcast.mp3", url: `file://${join(directory, "source.mp3")}` },
        ...manifest.images.map(image => ({ path: image.path, url: `file://${join(directory, sources[image.file])}` }))];
      writeFileSync(join(directory, "manifest.json"), JSON.stringify({ ...manifest, images: undefined, downloads, language: "zh-Hans" }));
      writeFileSync(join(directory, "captions.srt"), "1\n00:00:00,500 --> 00:00:02,000\n故事从这里开始\n");
      writeFileSync(join(directory, "chapters.txt"), chapterMetadata({ title: "Book", chapters: [{ title: "One", startSegment: 0, endSegment: 1, startSeconds: 0, endSeconds: 3 }, { title: "Two", startSegment: 1, endSegment: 2, startSeconds: 3, endSeconds: 6 }] }));
      writeFileSync(join(directory, "render.mjs"), IMAGE_SEQUENCE_RUNNER);
      execFileSync("node", ["render.mjs"], { cwd: directory, stdio: "pipe" });
      const info = JSON.parse(execFileSync("ffprobe", ["-v", "error", "-show_streams", "-show_format", "-show_chapters", "-of", "json", "render.mp4"], { cwd: directory }).toString());
      const video = info.streams.find((stream: { codec_type: string }) => stream.codec_type === "video");
      expect([video.width, video.height]).toEqual([1280, 720]);
      expect(info.streams.some((stream: { codec_type: string }) => stream.codec_type === "audio")).toBe(true);
      expect(info.streams.some((stream: { codec_type: string; tags?: { language?: string } }) => stream.codec_type === "subtitle" && stream.tags?.language === "zho")).toBe(true);
      expect(info.chapters.map((chapter: { tags: { title: string } }) => chapter.tags.title)).toEqual(["One", "Two"]);
      expect(Math.abs(Number(info.format.duration) - 6)).toBeLessThan(0.5);
    } finally { rmSync(directory, { recursive: true, force: true }); }
  }, 120_000);

  it("builds a filter for every motion", () => {
    for (const motion of ["zoom-in", "zoom-out", "pan-left", "pan-right", "pan-up", "pan-down"] as const) {
      expect(zoompanFilter(motion, 240, 1920, 1080)).toContain("zoompan=");
    }
  });
});
