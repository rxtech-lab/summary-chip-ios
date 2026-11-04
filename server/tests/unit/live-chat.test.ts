import { afterEach, describe, expect, it, vi } from "vitest";
const mocks = vi.hoisted(() => ({ token: vi.fn(), config: vi.fn() }));
vi.mock("@ai-sdk/gateway", () => {
  const realtime = Object.assign(() => ({ getWebSocketConfig: mocks.config }), { getToken: mocks.token });
  return { createGateway: () => ({ experimental_realtime: realtime }) };
});
import { createLiveChatSession, liveChatModel } from "@/lib/ai/live-chat";

afterEach(() => { vi.unstubAllEnvs(); vi.clearAllMocks(); });
describe("live voice session", () => {
  it("defaults to the requested model and rejects unsupported audio protocols", () => {
    vi.stubEnv("AI_LIVE_CHAT_MODEL", "");
    expect(liveChatModel()).toBe("google/gemini-3.8-live");
    vi.stubEnv("AI_LIVE_CHAT_MODEL", "openai/other");
    expect(() => liveChatModel()).toThrow("not supported");
  });
  it("mints short-lived credentials without requiring an explicit Gateway API key", async () => {
    vi.stubEnv("AI_GATEWAY_API_KEY", "");
    vi.stubEnv("AI_LIVE_CHAT_MODEL", "google/gemini-3.8-live");
    mocks.token.mockResolvedValue({ token: "vcst_test", url: "wss://example.test/realtime" });
    mocks.config.mockReturnValue({ url: "wss://example.test/realtime", protocols: ["ai-gateway-auth.vcst_test"] });
    const result = await createLiveChatSession();
    expect(mocks.token).toHaveBeenCalledWith({ model: "google/gemini-3.8-live", expiresAfterSeconds: 60 });
    expect(result.config.inputAudioFormat).toEqual({ type: "audio/pcm", rate: 16000 });
    expect(result.config.outputAudioFormat).toEqual({ type: "audio/pcm", rate: 24000 });
    expect(result.config.turnDetection).toBeUndefined();
    expect(result.config.tools?.map(tool => tool.name)).toEqual(["askChippy"]);
    expect(result).not.toHaveProperty("token");
  });
  it("propagates mint failure instead of returning a server credential", async () => {
    mocks.token.mockRejectedValue(new Error("unavailable"));
    await expect(createLiveChatSession()).rejects.toThrow("unavailable");
    expect(mocks.config).not.toHaveBeenCalled();
  });
});
