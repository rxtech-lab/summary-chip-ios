import { randomUUID } from "node:crypto";
import { eq } from "drizzle-orm";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { createMcpServer } from "@/lib/mcp/server";
import { podcastEpisodes, summaries } from "@/lib/db/schema";
import { createDailyPodcast, dailyPodcastEpisode, dayKey } from "@/lib/services/daily-podcast";
import { createPodcastVersion } from "@/lib/services/podcast-versions";
import type { DailyPodcast } from "@/lib/contracts/daily-podcast";
import * as summaryRoute from "@/app/api/v1/summaries/route";
import { apiRequest, setupTestEnv, type TestEnv } from "../helpers/setup";

let env: TestEnv;
const day = { start: "2030-04-01T00:00:00Z", end: "2030-04-02T00:00:00Z" };
const handles: { client: Client; server: ReturnType<typeof createMcpServer> }[] = [];
beforeEach(async () => { env = await setupTestEnv({ transactional: true }); });
afterEach(async () => { for (const h of handles.splice(0)) { await h.client.close(); await h.server.close(); } vi.restoreAllMocks(); env.teardown(); });
async function client(user = "user-alice", scopes: ("chippy:read" | "chippy:write")[] = ["chippy:read", "chippy:write"]) {
  const server = createMcpServer({ db: env.handle.db, principal: { sub: user, scopes, clientId: "version-test" }, accepted: null });
  const client = new Client({ name: "version-test", version: "1.0" });
  const [a, b] = InMemoryTransport.createLinkedPair();
  await server.connect(b); await client.connect(a); handles.push({ client, server }); return client;
}
async function seed() {
  const response = await summaryRoute.POST(apiRequest("POST", "/api/v1/summaries", { token: env.tokens.alice, body: {
    source: { type: "text", text: "Researchers studied volcanoes and published their findings.", title: "Volcanoes" }, followLinks: false,
  } }));
  const chip = await response.json();
  return createDailyPodcast(env.handle.db, "user-alice", { day, language: "en", chipIds: [chip.id], library: true, regenerate: false, includeVideo: false });
}
async function call(c: Client, name: string, args: Record<string, unknown>) { return c.callTool({ name, arguments: args }); }
const episodeOf = (r: Awaited<ReturnType<typeof call>>) => (r.structuredContent as { episode: DailyPodcast }).episode;
const source = `import React from 'react'; import {AbsoluteFill, useCurrentFrame} from 'remotion'; export const PodcastVideo = () => { const frame = useCurrentFrame(); return <AbsoluteFill style={{backgroundColor:'#ffffff', opacity:Math.min(1,frame/10)}} />; };`;
async function submit(c: Client, p: DailyPodcast) {
  const ref = { day, key: p.key };
  const project = await call(c, "get_podcast_project", ref);
  let revision = (project.structuredContent as { revision: number }).revision;
  const edit = await call(c, "create_podcast_file", { ...ref, revision, path: "src/Video.tsx", content: source });
  revision = (edit.structuredContent as { revision: number }).revision;
  const saved = await call(c, "submit_podcast_video", { ...ref, revision });
  expect(saved.isError, JSON.stringify(saved)).not.toBe(true);
}
it("keeps two video versions and two languages under one library chip", async () => {
  env.ai.video = true;
  const original = await seed(); const c = await client();
  await submit(c, original);
  const translated = await call(c, "translate_podcast", { day, key: original.key, language: "fr" });
  expect(translated.isError, JSON.stringify(translated)).not.toBe(true);
  expect(episodeOf(translated)).toMatchObject({ key: original.key, summaryId: original.summaryId, languages: ["en", "fr"], language: "fr", video: { id: expect.any(String) } });
  const speech = env.ai.calls.speak.length;
  const reread = await call(c, "translate_podcast", { day, key: original.key, language: "fr" });
  expect(episodeOf(reread).key).toBe(original.key);
  expect(env.ai.calls.speak).toHaveLength(speech);
  const storedOriginal = await dailyPodcastEpisode(env.handle.db, "user-alice", day, original.key);
  storedOriginal.video!.published = { videoId: randomUUID(), byteSize: 100, publishedAt: original.createdAt };
  await env.handle.db.update(podcastEpisodes).set({ document: storedOriginal }).where(eq(podcastEpisodes.key, original.key));
  const before = await dailyPodcastEpisode(env.handle.db, "user-alice", day, original.key);
  const created = await call(c, "create_podcast_version", { day, key: original.key });
  expect(created.isError, JSON.stringify(created)).not.toBe(true);
  const next = episodeOf(created);
  expect(next.key).not.toBe(original.key);
  expect(next).toMatchObject({ summaryId: original.summaryId, languages: ["en", "fr"], segments: before.segments });
  expect(next.audioPath).toContain(next.key);
  expect(next.video?.published).toBeUndefined();
  const projects = await call(c, "get_podcast_project", { day, key: next.key });
  expect(projects.structuredContent).toMatchObject({ revision: 0, files: { "src/Video.tsx": source } });
  const edited = await call(c, "edit_podcast_file", { day, key: next.key, revision: 0, path: "src/Video.tsx", oldText: "#ffffff", newText: "#eeeeee" });
  expect(edited.isError).not.toBe(true);
  expect((await call(c, "submit_podcast_video", { day, key: next.key, revision: 1 })).isError).not.toBe(true);
  const refreshed = await call(c, "translate_podcast", { day, key: next.key, language: "fr" });
  expect(refreshed.isError, JSON.stringify(refreshed)).not.toBe(true);
  expect(episodeOf(refreshed)).toMatchObject({ key: next.key, languages: ["en", "fr"], video: { id: expect.any(String) } });
  expect(env.ai.calls.speak).toHaveLength(speech);
  expect(await dailyPodcastEpisode(env.handle.db, "user-alice", day, original.key)).toEqual(before);
  const listed = await call(c, "list_podcasts", { summaryId: original.summaryId });
  expect((listed.structuredContent as { episodes: unknown[] }).episodes).toHaveLength(2);
  expect(await env.handle.db.select().from(summaries).where(eq(summaries.kind, "podcast"))).toHaveLength(1);
  expect((await call(c, "get_podcast", { day, key: next.key, language: "fr" })).isError).not.toBe(true);
  const stored = await dailyPodcastEpisode(env.handle.db, "user-alice", day, next.key);
  expect(stored.translations?.fr.audioPath).toContain(next.key);
  expect(env.store.objects.has(`${dayKey("user-alice", day)}/${next.key}/translations/fr/audio.mp3`)).toBe(true);
});
it("rejects cross-owner and read-only writes without creating versions", async () => {
  const original = await seed();
  for (const c of [await client("user-bob"), await client("user-alice", ["chippy:read"])]) {
    for (const name of ["create_podcast_version", "translate_podcast"]) {
      expect((await call(c, name, { day, key: original.key, language: "fr" })).isError).toBe(true);
    }
  }
  const read = await client("user-alice", ["chippy:read"]);
  expect((await call(read, "get_podcast", { day, key: original.key })).isError).not.toBe(true);
  expect((await call(await client("user-bob"), "list_podcasts", { summaryId: original.summaryId })).isError).toBe(true);
  expect(await env.handle.db.select().from(podcastEpisodes)).toHaveLength(1);
});
it("cleans copied audio and preserves the default when a source copy fails", async () => {
  const original = await seed();
  original.video = { id: randomUUID(), createdAt: original.createdAt, sourceFile: "missing.json" };
  await env.handle.db.update(podcastEpisodes).set({ document: original }).where(eq(podcastEpisodes.key, original.key));
  const paths = [...env.store.objects.keys()].sort();
  await expect(createPodcastVersion(env.handle.db, "user-alice", day, original.key)).rejects.toThrow();
  expect([...env.store.objects.keys()].sort()).toEqual(paths);
  const rows = await env.handle.db.select().from(podcastEpisodes);
  expect(rows).toHaveLength(1); expect(rows[0].isDefault).toBe(true);
});
