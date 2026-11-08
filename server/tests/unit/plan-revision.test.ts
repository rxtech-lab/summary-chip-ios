import type { LanguageModelV4, LanguageModelV4CallOptions } from "@ai-sdk/provider";
import { afterEach, describe, expect, it, vi } from "vitest";
import { z } from "zod";
import { runPlanRevision } from "@/lib/ai/plan-revision-agent";
import type { PodcastPlanMessage } from "@/lib/contracts/daily-podcast";
import { appendPlanTurn, MAX_PLAN_SNAPSHOTS, planChatHistory } from "@/lib/services/plan-transcript";

type Step = { toolName: string; input: unknown } | { text: string };

/** Answers each step with the next scripted tool call or text. */
function scriptedModel(steps: Step[]) {
  const calls: LanguageModelV4CallOptions[] = [];
  const model: LanguageModelV4 = {
    specificationVersion: "v4", provider: "mock", modelId: "scripted", supportedUrls: {},
    async doGenerate(options) {
      calls.push(options);
      const step = steps[calls.length - 1] ?? { text: "" };
      const call = "toolName" in step;
      return {
        content: call
          ? [{ type: "tool-call" as const, toolCallId: `c${calls.length}`, toolName: step.toolName, input: JSON.stringify(step.input) }]
          : [{ type: "text" as const, text: step.text }],
        finishReason: call ? { unified: "tool-calls" as const, raw: "tool_calls" } : { unified: "stop" as const, raw: "stop" },
        usage: { inputTokens: { total: 1, noCache: 1, cacheRead: 0, cacheWrite: 0 }, outputTokens: { total: 1, text: 1, reasoning: 0 } },
        warnings: [],
      };
    },
    async doStream() { throw new Error("not used"); },
  };
  return { model, calls };
}

const schema = z.object({ title: z.string() });
const run = (steps: Step[]) => runPlanRevision(scriptedModel(steps).model, { instructions: "Plan.", prompt: "{}", schema });

describe("runPlanRevision", () => {
  afterEach(() => { vi.unstubAllEnvs(); vi.unstubAllGlobals(); });

  it("researches before revising and passes source evidence back to the planner", async () => {
    vi.stubEnv("FIRECRAWL_API_KEY", "test-key");
    const fetchMock = vi.fn().mockResolvedValue(new Response(JSON.stringify({
      success: true, data: { web: [{ title: "Source", url: "https://example.com/source", description: "Evidence" }] },
    })));
    vi.stubGlobal("fetch", fetchMock);
    const { model, calls } = scriptedModel([
      { toolName: "searchWeb", input: { query: "research topic" } },
      { toolName: "update_plan", input: { title: "Researched" } },
      { toolName: "show_plan", input: {} },
      { text: "Added sourced context." },
    ]);
    const turn = await runPlanRevision(model, { instructions: "Plan.", prompt: "Research.", schema });
    expect(turn.plan).toEqual({ title: "Researched" });
    expect(fetchMock).toHaveBeenCalledWith("https://api.firecrawl.dev/v2/search", expect.objectContaining({
      body: JSON.stringify({ query: "research topic", limit: 5 }),
    }));
    expect(JSON.stringify(calls[1].prompt)).toContain("https://example.com/source");
  });

  it("returns the revision the agent shows", async () => {
    const turn = await run([{ toolName: "update_plan", input: { title: "Shorter" } }, { toolName: "show_plan", input: {} }, { text: "I shortened it." }]);
    expect(turn).toEqual({ reply: "I shortened it.", plan: { title: "Shorter" } });
  });

  it("answers a question without a new plan", async () => {
    expect(await run([{ text: "It runs about six minutes." }])).toEqual({ reply: "It runs about six minutes.", plan: null });
  });

  it("refuses to show before a revision is saved", async () => {
    const { model, calls } = scriptedModel([{ toolName: "show_plan", input: {} }, { text: "Nothing to change." }]);
    expect(await runPlanRevision(model, { instructions: "Plan.", prompt: "{}", schema })).toEqual({ reply: "Nothing to change.", plan: null });
    expect(JSON.stringify(calls[1].prompt)).toContain("call update_plan");
  });

  it("still returns a saved revision the agent forgot to show", async () => {
    expect((await run([{ toolName: "update_plan", input: { title: "New" } }, { text: "Done." }])).plan).toEqual({ title: "New" });
  });
});

describe("appendPlanTurn", () => {
  const now = "2026-11-08T00:00:00.000Z";
  const shape = (messages: PodcastPlanMessage[]) => messages.map(message => [message.role, message.kind, message.revision, message.plan ?? message.text]);

  it("keeps the reviewed plan above the request and adds the shown plan below it", () => {
    const first = appendPlanTurn([], { current: { v: 0 }, revision: 0, request: "Shorter", reply: "Shortened.", shown: { v: 1 }, now });
    expect(shape(first)).toEqual([
      ["assistant", "plan", 0, { v: 0 }], ["user", "text", 0, "Shorter"], ["assistant", "plan", 1, { v: 1 }], ["assistant", "text", 1, "Shortened."],
    ]);
    // Edited by hand to revision 2, then a question: the shown card is frozen as edited, and no plan is added.
    const second = appendPlanTurn(first, { current: { v: 2 }, revision: 2, request: "How long?", reply: "Six minutes.", shown: null, now });
    expect(shape(second).slice(2)).toEqual([
      ["assistant", "plan", 2, { v: 2 }], ["assistant", "text", 1, "Shortened."], ["user", "text", 2, "How long?"], ["assistant", "text", 2, "Six minutes."],
    ]);
    expect(shape(second)[0]).toEqual(["assistant", "plan", 0, { v: 0 }]);
    expect(planChatHistory(second)).toEqual([
      { role: "user", text: "Shorter" }, { role: "assistant", text: "Shortened." }, { role: "user", text: "How long?" }, { role: "assistant", text: "Six minutes." },
    ]);
  });

  it("drops old snapshots but keeps their place", () => {
    let messages: PodcastPlanMessage[] = [];
    for (let revision = 0; revision < MAX_PLAN_SNAPSHOTS + 3; revision += 1) {
      messages = appendPlanTurn(messages, { current: { v: revision }, revision, request: "Again", reply: "Done.", shown: { v: revision + 1 }, now });
    }
    const plans = messages.filter(message => message.kind === "plan");
    expect(plans.filter(message => message.plan !== undefined)).toHaveLength(MAX_PLAN_SNAPSHOTS);
    expect(plans.at(-1)?.plan).toEqual({ v: MAX_PLAN_SNAPSHOTS + 3 });
  });
});
