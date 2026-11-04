import { describe, expect, it, vi } from "vitest";
import { tool } from "ai";
import { z } from "zod";
const mocks = vi.hoisted(() => ({ execute: vi.fn(), prepare: vi.fn() }));
vi.mock("@/lib/ai/chat", () => ({ prepareChat: mocks.prepare, chatRequestSchema: z.object({ messages: z.array(z.unknown()) }) }));
vi.mock("@/lib/http/handler", () => ({ withApiAuth: (_: Request, run: (context: { principal: { sub: string }; db: object }) => Promise<Response>) => run({ principal: { sub: "owner" }, db: {} }) }));
import { POST } from "@/app/api/v1/chat/live/tool/route";
function request(name: string, input: unknown) {
  return new Request("https://example.test/api/v1/chat/live/tool", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ context: { messages: [] }, callId: "call-1", name, input }) });
}
describe("direct voice tools", () => {
  it("validates arguments and executes with authenticated context", async () => {
    mocks.execute.mockResolvedValue({ found: true });
    mocks.prepare.mockResolvedValue({ tools: { search: tool({ inputSchema: z.object({ query: z.string() }), execute: mocks.execute }) } });
    const response = await POST(request("search", { query: "chips" }));
    expect(await response.json()).toEqual({ output: { found: true } });
    expect(mocks.prepare).toHaveBeenCalledWith({}, "owner", { messages: [] });
    expect(mocks.execute).toHaveBeenCalledWith({ query: "chips" }, expect.objectContaining({ toolCallId: "call-1" }));
    const wrapped = await POST(request("search", { argumentsJson: JSON.stringify({ query: "voice" }) }));
    expect(await wrapped.json()).toEqual({ output: { found: true } });
    expect(mocks.execute).toHaveBeenLastCalledWith({ query: "voice" }, expect.anything());
    await expect(POST(request("search", { argumentsJson: "{" }))).rejects.toThrow("valid JSON object");
    await expect(POST(request("search", { argumentsJson: '{"query":3}' }))).rejects.toThrow("Invalid tool arguments");
    mocks.execute.mockClear();
    await expect(POST(request("search", { query: 3 }))).rejects.toThrow("Invalid tool arguments");
    expect(mocks.execute).not.toHaveBeenCalled();
  });
  it("rejects unavailable and inherited tool names", async () => {
    mocks.prepare.mockResolvedValue({ tools: {} });
    await expect(POST(request("deleteAnything", {}))).rejects.toThrow("not available");
    await expect(POST(request("toString", {}))).rejects.toThrow("not available");
  });
});

import { liveToolDefinitions, voiceToolCatalog } from "@/lib/ai/live-tools";
import { createGateway } from "@ai-sdk/gateway";
it("excludes provider-managed search from voice function declarations", async () => {
  const original = { searchWeb: createGateway().tools.perplexitySearch({}) };
  const definitions = await liveToolDefinitions(original);
  expect(definitions).toEqual([]);
  const voice = voiceToolCatalog(original);
  expect(voice.searchWeb.execute).toBeTypeOf("function");
  expect((await liveToolDefinitions(voice))[0].description).toContain("Google");
  expect(original.searchWeb.execute).toBeUndefined();
  expect(voiceToolCatalog({})).toEqual({});
});
it("keeps nested schemas in descriptions and exposes a shallow Live contract", async () => {
  const definitions = await liveToolDefinitions({ edit: tool({ description: "Edit graph", inputSchema: z.object({ changes: z.array(z.union([z.string(), z.number()])) }) }) });
  expect(definitions[0].name).toBe("edit");
  expect(definitions[0].description).toContain('"changes"');
  expect(definitions[0].parameters).toEqual({ type: "object", properties: { argumentsJson: { type: "string", description: "JSON-encoded tool arguments." } }, required: ["argumentsJson"], additionalProperties: false });
});
