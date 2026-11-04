import { describe, expect, it, vi } from "vitest";
import { z } from "zod";

const mocks = vi.hoisted(() => ({ session: vi.fn(), settle: vi.fn(), prepare: vi.fn() }));
vi.mock("@/lib/ai/chat", () => ({
  prepareChat: mocks.prepare,
  chatRequestSchema: z.object({ messages: z.array(z.unknown()) }),
  sanitizeChatMessages: (messages: unknown) => messages,
}));
vi.mock("@/lib/http/handler", () => ({
  withApiAuth: (_: Request, run: (context: { principal: { sub: string }; db: object }) => Promise<Response>) => run({ principal: { sub: "owner" }, db: {} }),
}));
vi.mock("@/lib/subscription/chat-billing", () => ({ reserveChatPoints: async () => ({ settle: mocks.settle }) }));
vi.mock("@/lib/subscription/environment", () => ({ billingEnvironment: async () => "test" }));
vi.mock("@/lib/ai/live-chat", async importOriginal => ({
  ...await importOriginal<typeof import("@/lib/ai/live-chat")>(),
  createLiveChatSession: mocks.session,
}));
import { POST } from "@/app/api/v1/chat/live/route";
import { liveToolNarrationInstructions, liveVoiceLanguageInstructions } from "@/lib/ai/live-chat";

describe("contextual voice session", () => {
  it("includes spoken action announcements when overriding the default instructions", async () => {
    mocks.prepare.mockResolvedValue({ instructions: "Focused document context", tools: {} });
    mocks.session.mockResolvedValue({ url: "wss://example.test" });
    const response = await POST(new Request("https://example.test/api/v1/chat/live", {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ messages: [{ role: "user", content: "Find astronomy chips" }] }),
    }));
    expect(response.status).toBe(200);
    const config = mocks.session.mock.calls[0][0];
    expect(config.instructions).toContain("Focused document context");
    expect(config.instructions).toContain(liveToolNarrationInstructions);
    expect(config.instructions).toContain(liveVoiceLanguageInstructions);
    expect(config.instructions).toContain("Find astronomy chips");
    expect(config.instructions).toContain("Do not call updateGraph for these display requests");
    expect(mocks.settle).toHaveBeenCalledWith(0, { surface: "live-voice-token" });
  });
});
