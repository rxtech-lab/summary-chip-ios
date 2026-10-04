import type { LanguageModelV4, LanguageModelV4CallOptions } from "@ai-sdk/provider";
import { describe, expect, it } from "vitest";
import { findDuplicate, normalizeSourceUrl, sameContentStart, type ChipRecord, type DuplicateTools } from "@/lib/ai/duplicate-agent";

type Call = { toolName: string; input: Record<string, unknown> };

/** Answers each agent step with the next scripted tool calls, recording every prompt it was sent. */
function scriptedModel(steps: Call[][]) {
  const prompts: LanguageModelV4CallOptions["prompt"][] = [];
  const model: LanguageModelV4 = {
    specificationVersion: "v4",
    provider: "mock",
    modelId: "scripted",
    supportedUrls: {},
    async doGenerate(options) {
      prompts.push(options.prompt);
      const calls = steps[prompts.length - 1] ?? [];
      return {
        content: calls.length
          ? calls.map((call, index) => ({ type: "tool-call" as const, toolCallId: `c${prompts.length}-${index}`, toolName: call.toolName, input: JSON.stringify(call.input) }))
          : [{ type: "text" as const, text: "Done." }],
        finishReason: calls.length ? { unified: "tool-calls" as const, raw: "tool_calls" } : { unified: "stop" as const, raw: "stop" },
        usage: { inputTokens: { total: 1, noCache: 1, cacheRead: 0, cacheWrite: 0 }, outputTokens: { total: 1, text: 1, reasoning: 0 } },
        warnings: [],
      };
    },
    async doStream() {
      throw new Error("not streamed");
    },
  };
  return { model, prompts };
}

const chip = (id: string, title: string): ChipRecord => ({
  id, title, summary: `About ${title}.`, sourceUrl: `https://example.com/${id}`, sourceTitle: null, siteName: null, content: `Content of ${title}.`,
});

const INPUT = { title: "Monarch migration", summary: "Monarchs fly south.", sourceUrl: null, sourceTitle: null, siteName: null, text: "Field notes." };

function library(chips: ChipRecord[], candidates = chips): DuplicateTools & { searches: string[] } {
  const searches: string[] = [];
  return {
    searches,
    candidates: candidates.map(({ content, ...listing }) => (void content, listing)),
    async search(query) {
      searches.push(query);
      return chips.map(({ content, ...listing }) => (void content, listing));
    },
    async read(id) {
      return chips.find((item) => item.id === id) ?? null;
    },
  };
}

describe("normalizeSourceUrl", () => {
  it("ignores tracking parameters, fragments, www, trailing slashes and parameter order", () => {
    expect(normalizeSourceUrl("https://www.Example.com/a/b/?utm_source=x&b=2&a=1#top")).toBe("example.com/a/b?a=1&b=2");
    expect(normalizeSourceUrl("http://example.com/a/b?a=1&b=2&fbclid=z")).toBe("example.com/a/b?a=1&b=2");
    expect(normalizeSourceUrl("ftp://example.com/a")).toBeNull();
    expect(normalizeSourceUrl("not a url")).toBeNull();
    expect(normalizeSourceUrl(null)).toBeNull();
  });
});

describe("sameContentStart", () => {
  const notes = "Raw field notes: monarchs left the meadow on 2 October.";
  it("matches texts that agree over the shorter one's opening", () => {
    expect(sameContentStart(notes, `  ${notes}\n\nMore notes later.`)).toBe(true);
    expect(sameContentStart(`${"x".repeat(300)}a`, `${"x".repeat(300)}b`)).toBe(true);
    expect(sameContentStart(notes, notes.replace("2 October", "3 October"))).toBe(false);
  });

  it("ignores openings too short to be distinctive", () => {
    expect(sameContentStart("Notes.", "Notes. And much more.")).toBe(false);
  });
});

describe("duplicate agent", () => {
  it("reads candidates and returns the verdict, showing the incoming chip and candidates", async () => {
    const tools = library([chip("a", "Monarch migration"), chip("b", "Sourdough")]);
    const { model, prompts } = scriptedModel([
      [{ toolName: "readChip", input: { id: "a" } }],
      [{ toolName: "verdict", input: { duplicateOf: "a", reason: "Same notes." } }],
      [{ toolName: "verdict", input: { duplicateOf: null, reason: "unreachable" } }],
    ]);
    expect(await findDuplicate(model, INPUT, tools)).toEqual({ duplicateOf: "a", reason: "Same notes." });
    // Stops as soon as the verdict is in.
    expect(prompts).toHaveLength(2);
    const first = JSON.stringify(prompts[0]);
    expect(first).toContain("Field notes.");
    expect(first).toContain("id: b");
    expect(JSON.stringify(prompts[1])).toContain("Content of Monarch migration.");
  });

  it("accepts chips found by searching, and drops ids it never saw", async () => {
    const tools = library([chip("a", "Monarch migration"), chip("c", "Monarchs again")], []);
    const searched = scriptedModel([
      [{ toolName: "searchChips", input: { query: "monarch" } }],
      [{ toolName: "verdict", input: { duplicateOf: "c", reason: "Same source." } }],
    ]);
    expect(await findDuplicate(searched.model, INPUT, tools)).toEqual({ duplicateOf: "c", reason: "Same source." });
    expect(tools.searches).toEqual(["monarch"]);

    const invented = scriptedModel([[{ toolName: "verdict", input: { duplicateOf: "zzz", reason: "Guess." } }]]);
    expect(await findDuplicate(invented.model, INPUT, library([chip("a", "A")]))).toEqual({ duplicateOf: null, reason: "Guess." });
  });

  it("returns null when the agent stops without a verdict", async () => {
    const { model } = scriptedModel([[]]);
    expect(await findDuplicate(model, INPUT, library([chip("a", "A")]))).toBeNull();
  });
});
