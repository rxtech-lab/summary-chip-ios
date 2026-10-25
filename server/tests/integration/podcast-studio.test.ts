import type { AiProvider } from "@/lib/ai/provider";
import { createGateway } from "@ai-sdk/gateway";
import { generateSpeech } from "ai";
import { randomUUID } from "node:crypto";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { createMcpServer } from "@/lib/mcp/server";
import { PODCAST_TOOL_NAMES } from "@/lib/mcp/podcast";
import { podcastEpisodes, users } from "@/lib/db/schema";
import { podcastVideoSource } from "@/lib/services/podcast-video";
import { editPodcastFiles } from "@/lib/services/podcast-studio";
import { setupTestEnv, type TestEnv } from "../helpers/setup";

let env: TestEnv;
const day = { start: "2030-04-01T00:00:00Z", end: "2030-04-02T00:00:00Z" };
let key: string;
const handles: { client: Client; server: ReturnType<typeof createMcpServer> }[] = [];
const source = `import React from 'react'; import {AbsoluteFill, useCurrentFrame} from 'remotion';
export const PodcastVideo = () => { const frame = useCurrentFrame(); return <AbsoluteFill style={{backgroundColor: '#ffffff', opacity: Math.min(1, frame / 10)}} />; };`;
beforeEach(async () => {
  env = await setupTestEnv({ transactional: true });
  key = randomUUID();
  await env.handle.db.insert(users).values([{ id: "alice" }, { id: "bob" }]).onConflictDoNothing();
  await env.handle.db.insert(podcastEpisodes).values({ key, ownerId: "alice", dayStart: Date.parse(day.start), dayEnd: Date.parse(day.end), document: {
    key, day, title: "Studio", language: "en", mood: "calm", createdAt: new Date().toISOString(), speakers: [{ name: "Host", voice: "alloy" }], chipIds: [], segments: [], durationSeconds: 3,
  } });
});
afterEach(async () => { for (const h of handles.splice(0)) { await h.client.close(); await h.server.close(); } env.teardown(); vi.restoreAllMocks(); });
async function client(user = "alice", scopes: ("chippy:read" | "chippy:write")[] = ["chippy:read", "chippy:write"]) {
  const server = createMcpServer({ db: env.handle.db, principal: { sub: user, scopes, clientId: "studio-test" }, accepted: null });
  const client = new Client({ name: "studio-test", version: "1.0" });
  const [a, b] = InMemoryTransport.createLinkedPair();
  await server.connect(b); await client.connect(a); handles.push({ server, client }); return client;
}
async function call(c: Client, name: string, args: Record<string, unknown> = {}) { return c.callTool({ name, arguments: { day, key, ...args } }); }
it("advertises tools and denies writing without the OAuth write scope", async () => {
  const c = await client("alice", ["chippy:read"]);
  const tools = await c.listTools();
  expect(tools.tools.map(t => t.name)).toEqual(expect.arrayContaining([...PODCAST_TOOL_NAMES]));
  for (const name of PODCAST_TOOL_NAMES.filter(n => !["list_podcasts", "render_podcast_frame"].includes(n))) {
    expect(tools.tools.find(t => t.name === name)?._meta?.securitySchemes).toEqual([{ type: "oauth2", scopes: ["chippy:write"] }]);
  }
  const denied = await call(c, "get_podcast_project");
  expect(denied.isError).toBe(true); expect(denied._meta).toHaveProperty("mcp/www_authenticate");
  const missing = await call(c, "render_podcast_frame", { revision: 0, seconds: 0 });
  expect(missing.isError).toBe(true);
});
it("isolates projects and generated assets by episode owner", async () => {
  const c = await client("bob");
  for (const [name, args] of [["get_podcast_project", {}], ["generate_podcast_speech", { text: "Hello", voice: "alloy" }], ["generate_podcast_music", { prompt: "Soft piano" }]] as const) {
    const result = await call(c, name, args); expect(result.isError).toBe(true); expect(JSON.stringify(result)).toContain("NOT_FOUND");
  }
});
it("creates, edits and deletes draft files without losing changes or allowing protected paths", async () => {
  const c = await client();
  expect((await call(c, "get_podcast_project")).structuredContent).toMatchObject({ revision: 0, files: {} });
  expect((await call(c, "create_podcast_file", { revision: 0, path: "src/Video.tsx", content: source })).structuredContent).toMatchObject({ revision: 1 });
  expect((await call(c, "create_podcast_file", { revision: 0, path: "src/Other.ts", content: "export {}" })).isError).toBe(true);
  expect((await call(c, "edit_podcast_file", { revision: 1, path: "src/Video.tsx", oldText: "#ffffff", newText: "#eeeeee" })).structuredContent).toMatchObject({ revision: 2 });
  expect((await call(c, "edit_podcast_file", { revision: 2, path: "src/Video.tsx", oldText: "missing", newText: "" })).isError).toBe(true);
  expect((await call(c, "delete_podcast_file", { revision: 2, path: "src/Video.tsx" })).structuredContent).toMatchObject({ revision: 3, paths: [] });
  for (const path of ["../secret.ts", "src/../secret.ts", "src/podcast.ts", "src/index.ts", "src/phrases.json"]) {
    expect(() => editPodcastFiles({}, { type: "create", path, content: "" })).toThrow();
  }
});
it("returns an actual PNG and submits immutable source for the device", async () => {
  const c = await client();
  await call(c, "get_podcast_project");
  await call(c, "create_podcast_file", { revision: 0, path: "src/Video.tsx", content: source });
  const preview = await call(c, "render_podcast_frame", { revision: 1, seconds: 1 });
  expect(preview.isError, JSON.stringify(preview)).not.toBe(true);
  const image = (preview.content as { type: string; data?: string }[]).find(c => c.type === "image");
  expect(Buffer.from(image!.data!, "base64").subarray(1, 4).toString()).toBe("PNG");
  expect((await call(c, "render_podcast_frame", { revision: 1, seconds: 3 })).isError).toBe(true);
  const saved = await call(c, "submit_podcast_video", { revision: 1 });
  expect(saved.isError, JSON.stringify(saved)).not.toBe(true);
  expect(saved.structuredContent).toMatchObject({ saved: true, revision: 2 });
  const video = await podcastVideoSource(env.handle.db, "alice", day, key);
  expect(video.files["src/Video.tsx"]).toBe(source);
  expect((await call(c, "submit_podcast_video", { revision: 1 })).isError).toBe(true);
}, 30000);
it("allows only one concurrent edit at a revision", async () => {
  const c = await client(); await call(c, "get_podcast_project");
  const results = await Promise.all(["One", "Two"].map(name => call(c, "create_podcast_file", { revision: 0, path: `src/${name}.ts`, content: "export {};" })));
  expect(results.filter(r => !r.isError)).toHaveLength(1);
  expect(results.filter(r => r.isError)).toHaveLength(1);
});
it("refuses invalid submissions without changing the saved video", async () => {
  const c = await client(); await call(c, "get_podcast_project");
  await call(c, "create_podcast_file", { revision: 0, path: "src/Video.tsx", content: "export const PodcastVideo = () => missingName;" });
  expect((await call(c, "submit_podcast_video", { revision: 1 })).isError).toBe(true);
  await expect(podcastVideoSource(env.handle.db, "alice", day, key)).rejects.toMatchObject({ code: "PODCAST_VIDEO_MISSING" });
});
it("generates standalone private assets and surfaces disabled/failed providers", async () => {
  const c = await client();
  const speech = await call(c, "generate_podcast_speech", { text: "Hello", voice: "alloy" });
  expect(speech.isError, JSON.stringify(speech)).not.toBe(true);
  expect(speech.structuredContent).toMatchObject({ mimeType: "audio/mpeg", byteSize: expect.any(Number), downloadUrl: expect.any(String), expiresAt: expect.any(String) });
  env.ai.music = true;
  const music = await call(c, "generate_podcast_music", { prompt: "Gentle instrumental piano" });
  expect(music.isError, JSON.stringify(music)).not.toBe(true);
  vi.spyOn(env.ai, "speak").mockRejectedValue(new Error("Upstream failed"));
  expect((await call(c, "generate_podcast_speech", { text: "Hello", voice: "alloy" })).isError).toBe(true);
  vi.spyOn(env.ai, "musicModelId").mockReturnValue(null);
  expect(JSON.stringify(await call(c, "generate_podcast_music", { prompt: "Piano" }))).toContain("PODCAST_ASSET_UNAVAILABLE");
});

it.skipIf(!process.env.PODCAST_SIMULATION_URL)("generates speech through the real SDK and Postman HTTP fixture", async () => {
  const gateway = createGateway({ baseURL: process.env.PODCAST_SIMULATION_URL, apiKey: "local-fixture-only" });
  vi.spyOn(env.ai as AiProvider, "speak").mockImplementation(async (text, voice) => {
    const result = await generateSpeech({ model: gateway.speechModel("fixture/speech"), text, voice, outputFormat: "mp3" });
    return { bytes: result.audio.uint8Array, mediaType: "audio/mpeg" };
  });
  const result = await call(await client(), "generate_podcast_speech", { text: "Fixture narration", voice: "alloy" });
  expect(result.isError, JSON.stringify(result)).not.toBe(true);
  expect(result.structuredContent).toMatchObject({ byteSize: 1668, mimeType: "audio/mpeg" });
});
it("creates a playable library podcast and opens its project", async () => {
  const c = await client();
  const chip = await c.callTool({ name: "add_summary", arguments: { title: "Research", summary: "Researchers studied a new material.", text: "Researchers studied a new material and published results.", visibility: "private" } });
  expect(chip.isError, JSON.stringify(chip)).not.toBe(true);
  const payload = chip.structuredContent as { summary: { id: string } };
  const created = await c.callTool({ name: "create_podcast", arguments: { day, language: "en", chipIds: [payload.summary.id], library: true, includeVideo: false } });
  expect(created.isError, JSON.stringify(created)).not.toBe(true);
  const episode = (created.structuredContent as { episode: { key: string; audioPath: string } }).episode;
  expect(episode.audioPath).toBeTruthy();
  expect((await call(c, "get_podcast_project", { key: episode.key })).isError).not.toBe(true);
});
