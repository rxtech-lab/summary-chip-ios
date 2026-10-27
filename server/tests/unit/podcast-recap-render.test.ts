import { expect, it, vi } from "vitest";
import { CLOUD_RENDER_RUNNER } from "@/lib/podcast-video/cloud-runner";

// Execute the trusted runner with deterministic Remotion/FFprobe stand-ins, without a sandbox.
async function run(compositionSeconds: number, mp4Seconds: number, limit: number, language = "en", trackLanguage = "eng") {
  const code = CLOUD_RENDER_RUNNER.replace(/^import .*;$/gm, "");
  const statuses: { status: string }[] = [];
  const renderMedia = vi.fn(async () => {});
  const process = { argv: ["node", "render.mjs", "1080", String(limit), language], cwd: () => "/renderer", exitCode: 0 };
  const commands: string[][] = [];
  const execute = new (Object.getPrototypeOf(async function () {}).constructor)(
    "bundle", "renderMedia", "selectComposition", "writeFile", "rename", "execFileSync", "process", code);
  await execute(async () => "/bundle", renderMedia, async () => ({ durationInFrames: compositionSeconds * 30, fps: 30, height: 1080 }),
    async (_path: string, data: string) => statuses.push(JSON.parse(data)), async () => {},
    (command: string, args: string[]) => { commands.push([command, ...args]); return command === "ffprobe" ? Buffer.from(JSON.stringify({ streams: [
      { codec_type: "video", width: 1920, height: 1080 }, { codec_type: "audio" }, { codec_type: "subtitle", tags: { language: trackLanguage } },
    ], format: { duration: mp4Seconds, size: 1000 } })) : Buffer.alloc(0); }, process);
  return { commands, renderMedia, status: statuses.at(-1)?.status, exitCode: process.exitCode };
}
it("rejects a recap composition over the cap before starting rendering", async () => {
  const result = await run(180, 180, 179);
  expect(result.renderMedia).not.toHaveBeenCalled();
  expect(result.status).toBe("failed");
});
it("rejects an MP4 over the cap even when the composition is shorter", async () => {
  const result = await run(178, 180, 179);
  expect(result.renderMedia).toHaveBeenCalledOnce();
  expect(result.status).toBe("failed");
});
it("accepts a measured short recap and preserves uncapped ordinary podcasts", async () => {
  expect((await run(178, 178.1, 179)).status).toBe("ready");
  expect((await run(300, 300, 0)).status).toBe("ready");
});

it("enforces the six-minute manual daily summary limit for composition and final MP4", async () => {
  expect((await run(359, 359.5, 360)).status).toBe("ready");
  expect((await run(361, 361, 360)).renderMedia).not.toHaveBeenCalled();
  expect((await run(359, 360.1, 360)).status).toBe("failed");
});

it.each([
  ["en", "eng"], ["zh-Hans", "zho"], ["zh-Hant", "zho"], ["ja", "jpn"],
  ["ko", "kor"], ["es", "spa"], ["fr", "fra"], ["de", "deu"],
])("labels the embedded captions for %s", async (language, code) => {
  const result = await run(10, 10, 0, language, code);
  expect(result.status).toBe("ready");
  const mux = result.commands.find(args => args.includes("mov_text"))!;
  expect(mux[mux.indexOf("-metadata:s:s:0") + 1]).toBe(`language=${code}`);
});
it("rejects a subtitle track that lost its selected language", async () => {
  expect((await run(10, 10, 0, "zh-Hant", "und")).status).toBe("failed");
});
