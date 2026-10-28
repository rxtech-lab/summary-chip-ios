import type { LanguageModelV4, LanguageModelV4CallOptions } from "@ai-sdk/provider";
import sharp from "sharp";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { newPodcastVideoDraft, podcastVideoTurn, type PodcastVideoImageTools } from "@/lib/ai/podcast-video-agent";
import { CutoutError, removeGreenScreen } from "@/lib/podcast-video/cutout";
import { previewPodcastFrames } from "@/lib/podcast-video/frame-preview";
import { isPodcastVideoAsset, podcastVideoAssets, referencedPodcastImages } from "@/lib/podcast-video/images";

/** A green-screen drawing: `background` everywhere, a red rectangle at x 60–140, y 40–100. */
async function greenScreen(background = { r: 0, g: 255, b: 0 }) {
  const width = 200, height = 150;
  const pixels = Buffer.alloc(width * height * 3);
  for (let y = 0; y < height; y += 1) for (let x = 0; x < width; x += 1) {
    const inside = x >= 60 && x < 140 && y >= 40 && y < 100;
    const color = inside ? { r: 220, g: 40, b: 30 } : background;
    pixels.set([color.r, color.g, color.b], (y * width + x) * 3);
  }
  return new Uint8Array(await sharp(pixels, { raw: { width, height, channels: 3 } }).png().toBuffer());
}

describe("removeGreenScreen", () => {
  it("keys out the green and trims the cut-out to its subject", async () => {
    const cutout = await removeGreenScreen(await greenScreen({ r: 20, g: 190, b: 60 }));
    // 80×60 subject plus 8px of transparent padding on each side.
    expect([cutout.width, cutout.height]).toEqual([96, 76]);
    const { data } = await sharp(cutout.png).raw().toBuffer({ resolveWithObject: true });
    const alpha = (x: number, y: number) => data[(y * cutout.width + x) * 4 + 3];
    expect(alpha(0, 0)).toBe(0);
    expect(alpha(48, 38)).toBe(255);
    expect(data[(38 * cutout.width + 48) * 4]).toBe(220);
  });

  it("refuses an image that wasn't drawn on a green screen", async () => {
    await expect(removeGreenScreen(await greenScreen({ r: 250, g: 250, b: 250 }))).rejects.toBeInstanceOf(CutoutError);
  });
});

describe("generated image paths", () => {
  it("keeps only the saved cut-outs a composition uses", () => {
    const files = { "src/Video.tsx": `<Img src={staticFile("gen/turtle.png")} /><Img src={staticFile(segment.image)} />` };
    expect(referencedPodcastImages(files)).toEqual(["gen/turtle.png"]);
    const images = { "gen/turtle.png": { file: "video-assets/run-1/turtle.png", width: 10, height: 8 }, "gen/unused.png": { file: "video-assets/run-1/unused.png", width: 1, height: 1 } };
    expect(podcastVideoAssets(files, images)).toEqual([{ path: "gen/turtle.png", file: "video-assets/run-1/turtle.png", width: 10, height: 8 }]);
    expect(isPodcastVideoAsset({ path: "gen/../x.png", file: "video-assets/run-1/x.png", width: 1, height: 1 })).toBe(false);
    expect(isPodcastVideoAsset({ path: "gen/x.png", file: "../audio.mp3", width: 1, height: 1 })).toBe(false);
  });
});

/** Answers each step with the next scripted tool call, recording every prompt. */
function scriptedModel(steps: { toolName: string; input: unknown }[]) {
  const calls: LanguageModelV4CallOptions[] = [];
  const model: LanguageModelV4 = {
    specificationVersion: "v4", provider: "mock", modelId: "scripted", supportedUrls: {},
    async doGenerate(options) {
      calls.push(options);
      const step = steps[calls.length - 1];
      return {
        content: [{ type: "tool-call" as const, toolCallId: `c${calls.length}`, toolName: step.toolName, input: JSON.stringify(step.input) }],
        finishReason: { unified: "tool-calls" as const, raw: "tool_calls" },
        usage: { inputTokens: { total: 1, noCache: 1, cacheRead: 0, cacheWrite: 0 }, outputTokens: { total: 1, text: 1, reasoning: 0 } },
        warnings: [],
      };
    },
    async doStream() { throw new Error("not streamed"); },
  };
  return { model, calls };
}

const input = { title: "Daily", language: "en", mood: "calm", speakers: ["Alex"], chips: [{ id: "c1", title: "Oceans" }], durationSeconds: 12,
  segments: [{ speaker: 0, chipId: "c1", caption: "Sea turtles cross whole oceans.", startSeconds: 3, endSeconds: 10,
    voiceStartSeconds: 3.2, voiceEndSeconds: 9.5, image: null, icon: "🐢", phrases: [{ text: "Sea turtles cross whole oceans.", startSeconds: 3.2, endSeconds: 9.5 }] }] };
const video = `import { AbsoluteFill, Img, staticFile } from "remotion";
import { usePhrases } from "./podcast";
export const PodcastVideo = () => {
  const { index, progress } = usePhrases();
  return <AbsoluteFill><Img src={staticFile("gen/sea-turtle.png")} style={{ position: "absolute", left: 400, top: 200, width: 320 + progress * 10, objectFit: "contain" }} /><div style={{ position: "absolute", left: 80, top: 80 }}>{index}</div></AbsoluteFill>;
};`;
const storyboard = [{ segmentIndex: 0, sourceQuote: "Sea turtles", visualSubject: "A sea turtle", visualAction: "The turtle swims across an ocean map", phraseActions: [{ phrase: 0, action: "Turtle glides in" }], file: "src/Video.tsx" }];

function imageTools() {
  const saved = new Map<string, Uint8Array>();
  const tools: PodcastVideoImageTools = {
    draw: vi.fn(async () => {
      const png = new Uint8Array(await sharp({ create: { width: 64, height: 48, channels: 4, background: { r: 240, g: 140, b: 40, alpha: 1 } } }).png().toBuffer());
      return { png, width: 64, height: 48 };
    }),
    save: vi.fn(async (path: string, png: Uint8Array) => { saved.set(`stored/${path}`, png); return `stored/${path}`; }),
    read: vi.fn(async (file: string) => saved.get(file)!),
  };
  return { tools, saved };
}

describe("generate_image", () => {
  beforeEach(() => {
    vi.spyOn(console, "warn").mockImplementation(() => {});
    vi.spyOn(console, "info").mockImplementation(() => {});
  });
  afterEach(() => vi.restoreAllMocks());

  it("is only offered with image tools", async () => {
    const without = scriptedModel([{ toolName: "write_file", input: { path: "src/Video.tsx", content: video } }]);
    await podcastVideoTurn(without.model, input, newPodcastVideoDraft());
    expect(without.calls[0].tools?.map((tool) => tool.name)).not.toContain("generate_image");
    expect(JSON.stringify(without.calls[0].prompt[0])).not.toContain("generate_image");
    const { tools } = imageTools();
    const offered = scriptedModel([{ toolName: "write_file", input: { path: "src/Video.tsx", content: video } }]);
    await podcastVideoTurn(offered.model, input, newPodcastVideoDraft(), { images: tools });
    expect(offered.calls[0].tools?.map((tool) => tool.name)).toContain("generate_image");
  });

  it("saves a cut-out, shows it to the agent and accepts a composition that places it", async () => {
    const { tools } = imageTools();
    const { model, calls } = scriptedModel([
      { toolName: "generate_image", input: { name: "sea-turtle", subject: "A green sea turtle swimming, seen from above" } },
      { toolName: "write_file", input: { path: "src/Video.tsx", content: video } },
      { toolName: "submit_video", input: { storyboard } },
    ]);
    let draft = newPodcastVideoDraft();
    for (let turn = 0; turn < 3; turn += 1) draft = JSON.parse(JSON.stringify((await podcastVideoTurn(model, input, draft, { images: tools })).draft));
    expect(tools.draw).toHaveBeenCalledWith("A green sea turtle swimming, seen from above", undefined);
    expect(draft.images).toEqual({ "gen/sea-turtle.png": { file: "stored/gen/sea-turtle.png", width: 64, height: 48, subject: "A green sea turtle swimming, seen from above" } });
    expect(draft.result).toEqual({ "src/Video.tsx": video });
    const result = calls[1].prompt.flatMap((message) => message.role === "tool" ? message.content : [])
      .find((part) => part.type === "tool-result" && part.toolName === "generate_image");
    expect(result).toMatchObject({ output: { type: "content", value: [
      { type: "text", text: expect.stringContaining('"path":"gen/sea-turtle.png"') },
      { type: "file", mediaType: "image/png" },
    ] } });
    // The layout check drew the real image rather than a placeholder.
    expect(tools.read).toHaveBeenCalledWith("stored/gen/sea-turtle.png");
  });

  it("rejects a composition that uses an image it never generated", async () => {
    const { tools } = imageTools();
    const { model } = scriptedModel([
      { toolName: "write_file", input: { path: "src/Video.tsx", content: video } },
      { toolName: "submit_video", input: { storyboard } },
    ]);
    let draft = newPodcastVideoDraft();
    for (let turn = 0; turn < 2; turn += 1) draft = (await podcastVideoTurn(model, input, draft, { images: tools })).draft;
    expect(draft.result).toBeNull();
    expect(JSON.stringify(draft.messages.at(-1))).toContain("is not a generated image");
  });

  it("stops drawing at the per-video limit and reports a failed drawing without saving", async () => {
    const { tools } = imageTools();
    const steps = Array.from({ length: 7 }, (_, index) => ({ toolName: "generate_image", input: { name: `thing-${index}`, subject: "A paper boat" } }));
    const { model } = scriptedModel(steps);
    vi.mocked(tools.draw).mockRejectedValueOnce(new Error("no image"));
    let draft = newPodcastVideoDraft();
    for (let turn = 0; turn < 7; turn += 1) draft = (await podcastVideoTurn(model, input, draft, { images: tools })).draft;
    expect(tools.draw).toHaveBeenCalledTimes(6);
    expect(Object.keys(draft.images ?? {})).toHaveLength(5);
    expect(JSON.stringify(draft.messages.at(-1))).toContain("No images left");
  });
});

describe("frame preview with generated images", () => {
  it("paints a cut-out in place, keeping its aspect ratio", async () => {
    const png = new Uint8Array(await sharp({ create: { width: 64, height: 32, channels: 4, background: { r: 200, g: 30, b: 30, alpha: 1 } } }).png().toBuffer());
    const files = { "src/Video.tsx": `import { AbsoluteFill, Img, staticFile } from "remotion";
export const PodcastVideo = () => <AbsoluteFill style={{ backgroundColor: "#ffffff" }}><Img src={staticFile("gen/box.png")} style={{ position: "absolute", left: 0, top: 0, width: 640 }} /></AbsoluteFill>;` };
    const data = { title: "", language: "en", mood: "calm", durationSeconds: 4, fps: 24, width: 1280, height: 720, speakers: [], segments: [] };
    const settings = { fps: 24, width: 1280, height: 720, durationSeconds: 4, language: "en" };
    const preview = await previewPodcastFrames(files, data, [], [{ seconds: 1, speaking: false }], settings, { png: true, assets: { "gen/box.png": { bytes: png, width: 64, height: 32 } } });
    if ("error" in preview) throw new Error(preview.error);
    // The 960px-wide PNG is a 0.75 scale: the image covers x < 480, y < 240.
    const { data: pixels, info } = await sharp(preview.frames[0].png!).raw().toBuffer({ resolveWithObject: true });
    const at = (x: number, y: number) => [...pixels.subarray((y * info.width + x) * info.channels, (y * info.width + x) * info.channels + 3)];
    expect(at(240, 120)).toEqual([200, 30, 30]);
    expect(at(240, 300)).toEqual([255, 255, 255]);
  });
});
