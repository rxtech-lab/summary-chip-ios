import { convertToModelMessages } from "ai";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import * as chat from "@/app/api/v1/chat/route";
import * as uploads from "@/app/api/v1/chat/uploads/route";
import { chatRequestSchema, sanitizeChatMessages } from "@/lib/ai/chat";
import { resolveChatAttachments } from "@/lib/ai/chat-attachments";
import { apiRequest, setupTestEnv, type TestEnv } from "../helpers/setup";

let env: TestEnv;
beforeEach(async () => { env = await setupTestEnv(); });
afterEach(() => env.teardown());

async function stage(filename: string, mimeType: string, bytes: Uint8Array) {
  const response = await uploads.POST(apiRequest("POST", "/api/v1/chat/uploads", {
    token: env.tokens.alice, body: { filename, mimeType, byteSize: bytes.byteLength },
  }));
  expect(response.status).toBe(201);
  const ticket = await response.json();
  expect(ticket).toMatchObject({ key: expect.stringMatching(/^chat-uploads\//), method: "PUT", headers: { "content-type": mimeType } });
  await env.store.put(ticket.key, { bytes, contentType: mimeType });
  return { uploadKey: ticket.key as string, filename };
}

describe("chat attachments", () => {
  it("downloads the owner's encrypted attachment for a local turn and rejects another account", async () => {
    const file = await stage("notes.md", "text/plain", new TextEncoder().encode("private notes"));
    const path = "/api/v1/chat/uploads?key=" + encodeURIComponent(file.uploadKey);
    const read = (token: string) => uploads.GET(apiRequest("GET", path, { token }));
    const response = await read(env.tokens.alice);
    expect(response.headers.get("cache-control")).toContain("no-store");
    expect(await response.text()).toBe("private notes");
    expect((await read(env.tokens.bob)).status).toBe(403);
  });

  it("resolves file-only turns to complete text and model file inputs using the stored filename", async () => {
    const contents = "# Notes\n" + "original ".repeat(1_200);
    const markdown = await stage("notes.md", "text/plain", new TextEncoder().encode(contents));
    const pdf = await stage("paper.pdf", "application/pdf", new Uint8Array([1, 2, 3]));
    const image = await stage("photo.png", "image/png", new Uint8Array([4, 5, 6]));
    const body = chatRequestSchema.parse({ messages: [{ role: "user", parts: [], attachments: [
      { ...markdown, filename: "spoofed.md" }, pdf, image,
    ] }] });
    const messages = await resolveChatAttachments(env.handle.db, "user-alice", sanitizeChatMessages(body.messages));
    const [turn] = await convertToModelMessages(messages);
    expect(turn.content).toMatchObject([
      { type: "text", text: 'Attached file "notes.md":\n' + contents },
      { type: "file", mediaType: "application/pdf", filename: "paper.pdf", data: { type: "url", url: new URL("data:application/pdf;base64,AQID") } },
      { type: "file", mediaType: "image/png", filename: "photo.png", data: { type: "url", url: new URL("data:image/png;base64,BAUG") } },
    ]);
  });

  it("rejects another owner's reference and unavailable new uploads, and permits a follow-up after expiry", async () => {
    const file = await stage("notes.md", "text/plain", new TextEncoder().encode("hello"));
    const first = { role: "user", parts: [], attachments: [file] };
    const send = (token: string, messages: unknown[]) => chat.POST(apiRequest("POST", "/api/v1/chat", { token, body: { messages } }));
    expect((await send(env.tokens.bob, [first])).status).toBe(403);
    await env.store.delete(file.uploadKey);
    expect((await send(env.tokens.alice, [first])).status).toBe(409);
    const response = await send(env.tokens.alice, [
      first, { role: "assistant", parts: [{ type: "text", text: "Read it" }] },
      { role: "user", parts: [{ type: "text", text: "New question" }] },
    ]);
    expect(response.status).toBe(200);
    expect(await response.text()).toContain("[DONE]");
  });

  it("rejects unsupported, oversized and anonymous uploads", async () => {
    const request = (mimeType: string, byteSize: number, token?: string) =>
      uploads.POST(apiRequest("POST", "/api/v1/chat/uploads", { token, body: { filename: "upload", mimeType, byteSize } }));
    expect((await request("application/octet-stream", 1, env.tokens.alice)).status).toBe(400);
    expect((await request("text/plain", 200_001, env.tokens.alice)).status).toBe(400);
    expect((await request("image/png", 25 * 1024 * 1024 + 1, env.tokens.alice)).status).toBe(400);
    expect((await request("application/pdf", 1)).status).toBe(401);
  });
});
