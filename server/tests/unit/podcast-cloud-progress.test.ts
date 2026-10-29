import { expect, it, vi } from "vitest";
import { CLOUD_RENDER_RUNNER } from "@/lib/podcast-video/cloud-runner";

it("writes ordered running progress before the validated output is ready", async () => {
  const writes: { status: string; percent?: number; byteSize?: number }[] = [];
  const writeFile = vi.fn(async (_path: string, value: string) => { writes.push(JSON.parse(value)); });
  const renderMedia = vi.fn(async (options: { onProgress: (value: { progress: number }) => void }) => {
    options.onProgress({ progress: 0 });
    options.onProgress({ progress: 0.5 });
    options.onProgress({ progress: 0.2 }); // A regressing callback cannot move the display backwards.
    options.onProgress({ progress: 1 });
  });
  const execFileSync = vi.fn((command: string) => command === "ffprobe" ? Buffer.from(JSON.stringify({
    streams: [{ codec_type: "video", height: 1080, width: 1920 }, { codec_type: "audio" },
      { codec_type: "subtitle", tags: { language: "eng" } }], format: { duration: "10", size: "1234" },
  })) : Buffer.from(""));
  // Run the trusted runner with local doubles, without Chromium, FFmpeg, or a billable sandbox.
  const body = CLOUD_RENDER_RUNNER.replace(/^import .*;$/gm, "");
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
  await new AsyncFunction("bundle", "renderMedia", "selectComposition", "writeFile", "rename", "execFileSync", "process", body)(
    async () => "local-bundle", renderMedia, async () => ({ height: 1080, fps: 30, durationInFrames: 300 }),
    writeFile, async () => {}, execFileSync, { argv: ["node", "render.mjs", "1080", "0", "en"], cwd: () => "/test" },
  );
  expect(writes.filter(value => value.status === "running").map(value => value.percent)).toEqual([1, 5, 50, 95, 97]);
  expect(writes.at(-1)).toEqual({ status: "ready", byteSize: 1234 });
});
