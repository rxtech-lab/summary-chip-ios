import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { GET, PUT } from "@/app/api/v1/ai/models/route";
import { GET as getUsage } from "@/app/api/v1/ai/usage/route";
import { accountModelId, withAIAccount } from "@/lib/ai/model-preference";
import { GatewayAiProvider } from "@/lib/ai/provider";
import { apiRequest, setupTestEnv, type TestEnv } from "../helpers/setup";

const path = "/api/v1/ai/models";
let env: TestEnv;
const fetcher = vi.fn<typeof fetch>();
beforeEach(async () => {
  env = await setupTestEnv();
  vi.stubGlobal("fetch", fetcher);
  vi.stubEnv("FLOWCY_BASE_URL", "https://flowcy.test");
});
afterEach(() => { vi.unstubAllEnvs(); vi.unstubAllGlobals(); fetcher.mockReset(); env.teardown(); });

describe("Flowcy account model usage", () => {
  const usagePath = "/api/v1/ai/usage";

  it("reads the signed-in account's rolling allowances without caching or using the service credential", async () => {
    const meters = [{ key: "agent_cost_5h", used: 1250000, limit: 5000000, resetsAt: "2026-11-25T10:26:00.000Z" },
      { key: "agent_cost_7d", used: 3500000, limit: null, resetsAt: null },
      { key: "agent_cost_30d", used: 0, limit: 0, resetsAt: null }];
    fetcher.mockImplementation(async (url, options) => {
      expect(String(url)).toBe("https://flowcy.test/api/v1/agent/usage");
      expect(options).toMatchObject({ cache: "no-store", redirect: "error" });
      const auth = new Headers(options?.headers).get("authorization");
      expect([env.tokens.alice, env.tokens.bob].map(token => "Bearer " + token)).toContain(auth);
      return Response.json({ unit: "micro_usd", meters: auth === "Bearer " + env.tokens.alice ? meters : [] });
    });
    for (const [caller, expected] of [[env.tokens.alice, meters], [env.tokens.bob, []]] as const) {
      const response = await getUsage(apiRequest("GET", usagePath, { token: caller }));
      expect(response.status).toBe(200);
      expect(response.headers.get("cache-control")).toBe("private, no-store");
      expect(await response.json()).toEqual({ unit: "micro_usd", meters: expected });
    }
  });

  it("distinguishes an unavailable or invalid report from zero spending", async () => {
    const request = () => apiRequest("GET", usagePath, { token: env.tokens.alice });
    expect((await getUsage(apiRequest("GET", usagePath))).status).toBe(401);
    expect(fetcher).not.toHaveBeenCalled();
    for (const status of [401, 403, 503]) {
      fetcher.mockResolvedValueOnce(new Response(null, { status }));
      expect((await getUsage(request())).status).toBe(status);
    }
    fetcher.mockRejectedValueOnce(new TypeError("offline"));
    expect((await getUsage(request())).status).toBe(503);
    fetcher.mockResolvedValueOnce(Response.json({ unit: "usd", meters: [] }));
    expect((await getUsage(request())).status).toBe(502);
  });
});

describe("Flowcy model preferences", () => {
  it("lists the live chat catalog, persists an account choice, and clears it for Automatic", async () => {
    const models = [{ modelId: "provider/one", alias: "One" }];
    fetcher.mockImplementation(async (input, init) => {
      expect(String(input)).toBe("https://flowcy.test/api/v1/agent/models?label=chat");
      expect(new Headers(init?.headers).get("authorization")).toMatch(/^Bearer /);
      return Response.json({ models });
    });
    const save = (id: string | null) => PUT(apiRequest("PUT", path, { token: env.tokens.alice, body: { modelId: id } }));
    expect((await save("provider/one")).status).toBe(200);
    expect(await (await GET(apiRequest("GET", path, { token: env.tokens.alice }))).json()).toEqual({ models, selectedModelId: "provider/one" });
    expect(await (await GET(apiRequest("GET", path, { token: env.tokens.bob }))).json()).toEqual({ models, selectedModelId: null });
    expect((await save("disabled")).status).toBe(422);
    const choices = await Promise.all(["user-alice", "user-bob"].map(user => withAIAccount(env.handle.db, user, accountModelId)));
    expect(choices).toEqual(["provider/one", null]);
    const ai = new GatewayAiProvider(choices[0]!);
    expect([ai.chatModelId(), ai.tourModelId(), ai.podcastModelId(), ai.podcastVideoModelId()]).toEqual(Array(4).fill("provider/one"));
    expect((await save(null)).status).toBe(200);
    expect(await withAIAccount(env.handle.db, "user-alice", accountModelId)).toBeNull();
  });

  it("requires sign-in and preserves Flowcy availability errors", async () => {
    expect((await GET(apiRequest("GET", path))).status).toBe(401);
    expect(fetcher).not.toHaveBeenCalled();
    fetcher.mockResolvedValue(new Response(null, { status: 503 }));
    expect((await GET(apiRequest("GET", path, { token: env.tokens.alice }))).status).toBe(503);
    fetcher.mockRejectedValueOnce(new TypeError("offline"));
    expect((await GET(apiRequest("GET", path, { token: env.tokens.alice }))).status).toBe(503);
    fetcher.mockResolvedValueOnce(new Response("invalid data"));
    expect((await GET(apiRequest("GET", path, { token: env.tokens.alice }))).status).toBe(502);
  });
});
