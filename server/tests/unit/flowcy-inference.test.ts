import { createDecipheriv } from "node:crypto";
import { generateText, stepCountIs, streamText, tool } from "ai";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { z } from "zod";
import { flowcyInference } from "@/lib/ai/flowcy";
import { GatewayAiProvider } from "@/lib/ai/provider";

const fetcher = vi.fn<typeof fetch>();
beforeEach(() => {
  vi.stubEnv("FLOWCY_BASE_URL", "https://flowcy.test");
  vi.stubEnv("FLOWCY_SERVICE_TOKEN", "fixture-service");
  vi.stubGlobal("fetch", fetcher);
});
afterEach(() => { vi.unstubAllGlobals(); vi.unstubAllEnvs(); fetcher.mockReset(); });

describe("inference through Flowcy", () => {
  it("sends the selected model, Chippy tool schemas and messages through the real SDK adapter", async () => {
    fetcher.mockImplementation(async (url, init) => {
      expect(String(url)).toBe("https://flowcy.test/api/v1/chippy/inference/language-model");
      const headers = new Headers(init?.headers);
      expect(headers.get("authorization")).toBe("Bearer fixture-service");
      expect(headers.get("ai-language-model-id")).toBe("provider/selected");
      expect(headers.get("x-flowcy-selected-model")).toBe("true");
      const body = JSON.parse(String(init?.body));
      expect(body.tools[0]).toMatchObject({ name: "getSummary" });
      expect(body.prompt[0]).toMatchObject({ role: "system", content: "Use Chippy." });
      return Response.json({ content: [{ type: "text", text: "Hello from Flowcy" }],
        finishReason: { unified: "stop" }, usage: { inputTokens: { total: 7 }, outputTokens: { total: 3 } }, warnings: [] });
    });
    const ai = new GatewayAiProvider("provider/selected");
    const reply = await generateText({ model: ai.chatModel(), instructions: "Use Chippy.", prompt: "Hello",
      tools: { getSummary: tool({ inputSchema: z.object({ id: z.string() }) }) }, maxRetries: 0 });
    expect(reply.text).toBe("Hello from Flowcy");
    expect(reply.usage.inputTokens).toBe(7);
  });

  it("runs a Chippy tool between streamed Flowcy steps and returns the final text", async () => {
    const usage = { inputTokens: { total: 4 }, outputTokens: { total: 2 } };
    const lookup = vi.fn(async ({ id }: { id: string }) => ({ title: "Saved chip " + id }));
    fetcher.mockImplementation(async (_url, init) => {
      expect(new Headers(init?.headers).get("ai-language-model-streaming")).toBe("true");
      const { prompt } = JSON.parse(String(init?.body));
      const hasToolResult = prompt.some((message: { role: string }) => message.role === "tool");
      if (hasToolResult) expect(JSON.stringify(prompt)).toContain("Saved chip 42");
      const events = hasToolResult ? [
        { type: "text-start", id: "answer" }, { type: "text-delta", id: "answer", delta: "Found it." },
        { type: "text-end", id: "answer" }, { type: "finish", finishReason: { unified: "stop" }, usage },
      ] : [
        { type: "tool-call", toolCallId: "lookup", toolName: "getSummary", input: JSON.stringify({ id: "42" }) },
        { type: "finish", finishReason: { unified: "tool-calls" }, usage },
      ];
      return new Response(events.map(event => "data: " + JSON.stringify(event) + "\n\n").join(""),
        { headers: { "content-type": "text/event-stream" } });
    });
    const reply = streamText({ model: new GatewayAiProvider("provider/selected").chatModel(), prompt: "Find chip 42",
      stopWhen: stepCountIs(2), maxRetries: 0,
      tools: { getSummary: tool({ inputSchema: z.object({ id: z.string() }), execute: lookup }) } });
    expect(await reply.text).toBe("Found it.");
    expect(lookup).toHaveBeenCalledOnce();
    expect(fetcher).toHaveBeenCalledTimes(2);
  });

  it("uploads only ciphertext to presigned storage and forwards a small descriptor to Flowcy", async () => {
    const body = "private attachment".repeat(220_000);
    let encrypted: Buffer | undefined;
    fetcher.mockImplementation(async (url, init) => {
      const path = new URL(String(url));
      if (path.pathname.endsWith("/upload")) {
        expect(JSON.parse(String(init?.body)).bytes).toBe(Buffer.byteLength(body));
        return Response.json({ key: "staged-input", url: "https://storage.test/input", headers: { "content-type": "application/octet-stream" } });
      }
      if (path.host === "storage.test") {
        expect(new Headers(init?.headers).has("authorization")).toBe(false);
        encrypted = Buffer.from(init?.body as Buffer);
        expect(encrypted.includes("private attachment")).toBe(false);
        return new Response(null);
      }
      expect(new Headers(init?.headers).get("x-flowcy-input")).toBe("staged-input");
      const values = JSON.parse(String(init?.body));
      const decipher = createDecipheriv("aes-256-gcm", Buffer.from(values.key, "base64"), Buffer.from(values.iv, "base64"));
      decipher.setAuthTag(Buffer.from(values.tag, "base64"));
      expect(Buffer.concat([decipher.update(encrypted!), decipher.final()]).toString()).toBe(body);
      return new Response("ok");
    });
    expect(await (await flowcyInference("language-model", { method: "POST", body })).text()).toBe("ok");
    expect(fetcher).toHaveBeenCalledTimes(3);
  });
});
