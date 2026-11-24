import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as membership from "@/app/api/v1/subscription/route";
import * as appleToken from "@/app/api/v1/subscription/apple/account-token/route";
import * as appleTransactions from "@/app/api/v1/subscription/apple/transactions/route";
import * as apiKeysRoute from "@/app/api/v1/api-keys/route";
import * as mcpRoute from "@/app/api/mcp/route";
import * as library from "@/app/api/v1/summaries/route";
import * as importSummaryRoute from "@/app/api/v1/summaries/import/route";
import * as regenerateImageRoute from "@/app/api/v1/summaries/[id]/image/route";
import * as chatRoute from "@/app/api/v1/chat/route";
import * as liveVoiceRoute from "@/app/api/v1/chat/live/route";
import * as aiModelsRoute from "@/app/api/v1/ai/models/route";
import * as aiUsageRoute from "@/app/api/v1/ai/usage/route";
import * as dailyRecapRoute from "@/app/api/v1/daily-recap/route";
import * as dailyPodcastsRoute from "@/app/api/v1/daily-podcasts/route";
import * as audiobooksRoute from "@/app/api/v1/audiobooks/route";
import * as papersRoute from "@/app/api/v1/papers/route";
import * as graphsRoute from "@/app/api/v1/graphs/route";
import * as richDocsRoute from "@/app/api/v1/rich-documents/route";
import * as todoListsRoute from "@/app/api/v1/todo-lists/route";
import * as tripsRoute from "@/app/api/v1/trips/route";
import * as tripIngestRoute from "@/app/api/v1/trips/[id]/ingest/route";
import * as resumesRoute from "@/app/api/v1/resumes/route";
import * as resumeProposalsRoute from "@/app/api/v1/resumes/[id]/proposals/route";
import * as deletion from "@/app/api/v1/account/deletion/route";
import { setAiProviderForTests } from "@/lib/ai/provider";
import { FLOWCY_APPLE_PRODUCT_ID, FLOWCY_PLUS_PLAN_ID } from "@/lib/subscription/flowcy";
import { apiRequest, setupTestEnv, type TestEnv } from "../helpers/setup";

const free = { planId: "free", billingProvider: "internal", status: "active", currentPeriodEnd: null };
const plus = { planId: FLOWCY_PLUS_PLAN_ID, billingProvider: "stripe", status: "active", currentPeriodEnd: "2099-02-01T00:00:00Z" };
const token = "0c63980e-0bd3-45c1-bdcf-85211433867e";
const receipt = "signed-apple-transaction-fixture";

describe("Flowcy Plus membership", () => {
  let env: TestEnv;
  beforeEach(async () => {
    env = await setupTestEnv();
    vi.stubEnv("FLOWCY_SUBSCRIPTION_URL", "https://subscription.test");
    vi.stubEnv("FLOWCY_SUBSCRIPTION_PRODUCTION_API_KEY", "rxs_production_fixture");
    vi.stubEnv("FLOWCY_BASE_URL", "https://flowcy.test");
  });
  afterEach(() => {
    vi.unstubAllEnvs();
    vi.unstubAllGlobals();
    env.teardown();
  });

  function request(method = "GET", path = "/api/v1/subscription", body?: unknown, headers: Record<string, string> = {}) {
    return apiRequest(method, path, {
      token: env.tokens.alice, body, headers: { "x-app-version": "2.0", "x-app-platform": "ios", ...headers },
    });
  }

  function upstream() {
    const state = { plans: [] as (typeof plus)[], grants: [] as (typeof plus)[], settled: false, unavailable: false };
    const fetch = vi.fn(async (input: URL | string, init?: RequestInit) => {
      const url = typeof input === "string" ? new URL(input) : input;
      if (url.origin === "https://flowcy.test") {
        return Response.json({ models: [{ modelId: "openai/gpt-5", alias: "GPT-5" }] });
      }
      if (state.unavailable) return new Response("temporarily unavailable", { status: 503 });
      switch (url.pathname) {
        case "/api/v1/entitlements":
          expect(url.searchParams.get("rxlabUserId")).toBe("user-alice");
          return Response.json({ plans: state.plans, defaultPlans: [free], complimentaryPlans: state.grants });
        case "/api/v1/catalog":
          expect(url.searchParams.get("platform")).toBe("ios");
          return Response.json({ plans: [{ id: FLOWCY_PLUS_PLAN_ID, purchaseOptions: [
            { provider: "apple_app_store", productId: FLOWCY_APPLE_PRODUCT_ID, productType: "auto_renewable_subscription" },
          ] }] });
        case "/api/v1/iap/apple/account-token":
          expect(JSON.parse(String(init?.body))).toStrictEqual({ rxlabUserId: "user-alice" });
          return Response.json({ appAccountToken: token });
        case "/api/v1/iap/apple/transactions":
          expect(JSON.parse(String(init?.body))).toStrictEqual({ rxlabUserId: "user-alice", signedTransaction: receipt });
          if (!state.settled) return Response.json({ error: "invalid_transaction" }, { status: 422 });
          state.plans = [{ ...plus, billingProvider: "apple_app_store" }];
          return Response.json({ status: "fulfilled" });
        default:
          throw new Error(`Unexpected subscription call ${url.pathname}`);
      }
    });
    vi.stubGlobal("fetch", fetch);
    return { state, fetch };
  }

  it("allows Free users into the app and non-AI chips with zero AI calls, while blocking AI endpoints", async () => {
    upstream();
    // Trap every AI provider method so any accidental AI call fails the test.
    const trappedAi = new Proxy({} as typeof env.ai, {
      get(_target, prop) {
        throw new Error(`Unexpected AI call "${String(prop)}" for unsubscribed user`);
      },
    });
    setAiProviderForTests(trappedAi);

    expect(await (await membership.GET(request())).json()).toEqual({ active: false, provider: null, productId: FLOWCY_APPLE_PRODUCT_ID });
    expect((await deletion.GET(request("GET", "/api/v1/account/deletion"))).status).toBe(200);
    expect((await membership.GET(apiRequest("GET", "/api/v1/subscription"))).status).toBe(401);

    // Library reads and non-AI chip creation succeed without calling AI.
    expect((await library.GET(request("GET", "/api/v1/summaries"))).status).toBe(200);

    const imported = await importSummaryRoute.POST(request("POST", "/api/v1/summaries/import", {
      title: "Manual Notes",
      summary: "Saved directly without Flowcy AI.",
      text: "Full notes written manually without calling any LLM or embedding model.",
      highlights: ["Zero AI calls"],
      tags: ["notes"],
      category: "Other",
      visibility: "private",
    }));
    expect(imported.status).toBe(201);
    const importedJson = await imported.json();
    const importedId = importedJson.summary?.id ?? importedJson.id;
    expect(importedId).toBeTruthy();

    const paper = await papersRoute.POST(request("POST", "/api/v1/papers", {
      title: "Draft Paper",
      visibility: "private",
    }));
    expect(paper.status).toBe(201);

    const graph = await graphsRoute.POST(request("POST", "/api/v1/graphs", {
      document: {
        title: "Concept Map",
        description: null,
        nodes: [{ id: "n1", label: "Node 1", types: ["Concept"], properties: {} }],
        edges: [],
        queries: [],
      },
      visibility: "private",
    }));
    expect(graph.status).toBe(201);

    const doc = await richDocsRoute.POST(request("POST", "/api/v1/rich-documents", {
      title: "Rich Note",
      markdown: "Hello world.",
      visibility: "private",
    }));
    expect(doc.status).toBe(201);

    const todo = await todoListsRoute.POST(request("POST", "/api/v1/todo-lists", {
      document: {
        title: "Errands",
        description: "Weekend list",
        deadline: "2026-12-31T23:59:59Z",
        items: [{ id: "i1", title: "Buy milk", completed: false, deadline: "2026-12-31T23:59:59Z" }],
      },
      visibility: "private",
    }));
    expect(todo.status).toBe(201);

    const trip = await tripsRoute.POST(request("POST", "/api/v1/trips", {
      document: {
        title: "Kyoto",
        startDate: "2026-05-01",
        endDate: "2026-05-03",
        currency: "JPY",
      },
      visibility: "private",
    }));
    expect(trip.status).toBe(201);
    const tripJson = await trip.json();
    const tripId = tripJson.trip.id;
    expect(tripId).toBeTruthy();

    const resume = await resumesRoute.POST(request("POST", "/api/v1/resumes", {
      title: "Main Resume",
      language: "en",
      idempotencyKey: "resume-create-1",
      document: {
        version: 1,
        candidateName: "Alice",
        links: [],
        sections: [],
      },
    }));
    expect(resume.status).toBe(201);
    const resumeJson = await resume.json();
    const resumeId = resumeJson.familyId;
    expect(resumeId).toBeTruthy();

    // Disabling daily recap is allowed without subscription; enabling is blocked.
    expect((await dailyRecapRoute.PUT(request("PUT", "/api/v1/daily-recap", { enabled: false, timeZone: "UTC", language: "en", hour: 7 }))).status).toBe(200);
    const enableRecap = await dailyRecapRoute.PUT(request("PUT", "/api/v1/daily-recap", { enabled: true, timeZone: "UTC", language: "en", hour: 7 }));
    expect(enableRecap.status).toBe(402);
    expect((await enableRecap.json()).error.code).toBe("FLOWCY_SUBSCRIPTION_REQUIRED");

    // All AI endpoints refuse unsubscribed users with 402 FLOWCY_SUBSCRIPTION_REQUIRED.
    const aiResponses = await Promise.all([
      library.POST(request("POST", "/api/v1/summaries", { source: { type: "text", text: "Summarize this text with AI please." } })),
      chatRoute.POST(request("POST", "/api/v1/chat", { messages: [{ role: "user", content: "Hi" }] })),
      liveVoiceRoute.POST(request("POST", "/api/v1/chat/live", {})),
      aiModelsRoute.GET(request("GET", "/api/v1/ai/models")),
      aiModelsRoute.PUT(request("PUT", "/api/v1/ai/models", { modelId: null })),
      aiUsageRoute.GET(request("GET", "/api/v1/ai/usage")),
      dailyPodcastsRoute.POST(request("POST", "/api/v1/daily-podcasts", { day: { start: "2026-05-01T00:00:00Z", end: "2026-05-02T00:00:00Z" } })),
      audiobooksRoute.POST(request("POST", "/api/v1/audiobooks", { title: "Book", prompt: "Story" })),
      regenerateImageRoute.POST(request("POST", `/api/v1/summaries/${importedId}/image`, { imageStyle: "illustration" }), { params: Promise.resolve({ id: importedId }) }),
      tripIngestRoute.POST(request("POST", `/api/v1/trips/${tripId}/ingest`, { source: { type: "text", text: "Flight JL123" } }), { params: Promise.resolve({ id: tripId }) }),
      resumeProposalsRoute.POST(request("POST", `/api/v1/resumes/${resumeId}/proposals`, { kind: "review", language: "en" }), { params: Promise.resolve({ id: resumeId }) }),
    ]);
    for (const res of aiResponses) {
      expect(res.status).toBe(402);
      expect((await res.json()).error.code).toBe("FLOWCY_SUBSCRIPTION_REQUIRED");
    }

    // MCP allows non-AI chip tools with zero AI calls, while blocking AI MCP tools.
    const apiKeyRes = await apiKeysRoute.POST(request("POST", "/api/v1/api-keys", { name: "Claude Code" }));
    expect(apiKeyRes.status).toBe(201);
    const { key } = await apiKeyRes.json() as { key: string };

    let rpcId = 0;
    async function callMcp(name: string, args: Record<string, unknown>) {
      const response = await mcpRoute.POST(apiRequest("POST", "/api/mcp", {
        token: key,
        headers: { accept: "application/json, text/event-stream" },
        body: { jsonrpc: "2.0", id: ++rpcId, method: "tools/call", params: { name, arguments: args } },
      }));
      expect(response.status).toBe(200);
      return (await response.json()).result as { isError?: boolean; content: { type: string; text: string }[] };
    }

    const listResult = await callMcp("list_summaries", {});
    expect(listResult.isError).toBeFalsy();

    const addResult = await callMcp("add_summary", {
      title: "MCP Manual Chip",
      summary: "Added from local agent without Flowcy Plus.",
      text: "Local notes imported via MCP with zero server AI calls.",
      keyPoints: ["Works without subscription"],
      tags: ["mcp"],
      category: "Other",
    });
    expect(addResult.isError).toBeFalsy();

    for (const [tool, args] of [
      ["add_to_trip_from_source", { tripId, text: "Flight JL123" }],
      ["review_resume", { familyId: resumeId, language: "en", expectedRevisionToken: resumeJson.revisionToken, idempotencyKey: "review-1" }],
      ["create_podcast", { day: { start: "2026-05-01T00:00:00Z", end: "2026-05-02T00:00:00Z" }, language: "en", library: true, chipIds: [importedId] }],
    ] as const) {
      const result = await callMcp(tool, args);
      expect(result.isError).toBe(true);
      expect(result.content.map(item => item.text).join(" ")).toMatch(/Flowcy Plus/i);
    }
  });

  it("admits paid and complimentary Plus for AI endpoints and stops expired or past-due access", async () => {
    const { state } = upstream();
    state.plans = [plus];
    expect(await (await membership.GET(request())).json()).toEqual({ active: true, provider: "flowcy", productId: null });
    expect((await aiModelsRoute.GET(request("GET", "/api/v1/ai/models"))).status).toBe(200);
    state.plans = [{ ...plus, status: "past_due" }, { ...plus, currentPeriodEnd: "2001-01-01T00:00:00Z" }];
    expect((await aiModelsRoute.GET(request("GET", "/api/v1/ai/models"))).status).toBe(402);
    expect((await library.GET(request("GET", "/api/v1/summaries"))).status).toBe(200);
    state.grants = [{ ...plus, billingProvider: "complimentary" }];
    expect((await aiModelsRoute.GET(request("GET", "/api/v1/ai/models"))).status).toBe(200);
  });

  it("links only to the authenticated account and grants AI access after upstream fulfillment", async () => {
    const { state } = upstream();
    expect(await (await appleToken.POST(request("POST", "/api/v1/subscription/apple/account-token", {}))).json()).toEqual({ appAccountToken: token });
    expect((await appleTransactions.POST(request("POST", "/api/v1/subscription/apple/transactions", { rxlabUserId: "user-bob", signedTransaction: receipt }))).status).toBe(400);
    expect((await appleTransactions.POST(request("POST", "/api/v1/subscription/apple/transactions", { signedTransaction: receipt }))).status).toBe(422);
    expect((await aiModelsRoute.GET(request("GET", "/api/v1/ai/models"))).status).toBe(402);
    state.settled = true;
    for (let retry = 0; retry < 2; retry++) {
      expect(await (await appleTransactions.POST(request("POST", "/api/v1/subscription/apple/transactions", { signedTransaction: receipt }))).json()).toEqual({ accepted: true });
    }
    expect(await (await membership.GET(request())).json()).toEqual({ active: true, provider: "apple", productId: null });
    expect((await aiModelsRoute.GET(request("GET", "/api/v1/ai/models"))).status).toBe(200);
    expect((await appleToken.POST(request("POST", "/api/v1/subscription/apple/account-token", {}))).status).toBe(409);
  });

  it("fails closed on AI routes during an outage while keeping library readable, and cannot select Xcode on a deployed server", async () => {
    const { state, fetch } = upstream();
    state.unavailable = true;
    expect((await membership.GET(request())).status).toBe(503);
    expect((await aiModelsRoute.GET(request("GET", "/api/v1/ai/models"))).status).toBe(503);
    expect((await library.GET(request("GET", "/api/v1/summaries"))).status).toBe(200);
    expect((await aiModelsRoute.GET(request("GET", "/api/v1/ai/models", undefined, { "x-storekit-app-transaction": "unverified" }))).status).toBe(403);
    vi.stubEnv("VERCEL_ENV", "production");
    vi.stubEnv("FLOWCY_SUBSCRIPTION_XCODE_API_KEY", "rxs_xcode_fixture");
    await membership.GET(request("GET", "/api/v1/subscription", undefined, { "x-storekit-environment": "xcode" }));
    expect(fetch.mock.lastCall?.[1]?.headers).toMatchObject({ "x-api-key": "rxs_production_fixture" });
    vi.stubEnv("FLOWCY_SUBSCRIPTION_PRODUCTION_API_KEY", "");
    expect((await aiModelsRoute.GET(request("GET", "/api/v1/ai/models"))).status).toBe(503);
  });
});
