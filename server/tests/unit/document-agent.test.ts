import type { LanguageModelV4, LanguageModelV4CallOptions } from "@ai-sdk/provider";
import { describe, expect, it } from "vitest";
import { sourceLinks, splitIntoParts, stripFence, writeDocument, type DocumentSource } from "@/lib/ai/document-agent";
import { simplifyHtml } from "@/lib/extract/html";
import { isSourceMarkdownPending } from "@/lib/services/serialize";

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

const toolOutputs = (prompt: LanguageModelV4CallOptions["prompt"]) =>
  JSON.stringify(prompt.filter((message) => message.role === "tool"));

describe("simplifyHtml", () => {
  it("keeps structure, absolute links and images, and drops chrome and attributes", () => {
    const html = simplifyHtml(`
      <div class="wrap"><nav><a href="/home">Home</a></nav>
        <h2 id="x" style="color:red">Intro</h2>
        <p>Read <a href="/docs?a=1&b=2" onclick="evil()">the docs</a>.<script>alert(1)</script></p>
        <figure><picture><source srcset="/big.webp"><img data-src="/img/cat.png" src="data:image/gif;base64,AAA" alt="A cat"></picture>
        <figcaption>The cat</figcaption></figure>
        <p><a href="javascript:void(0)">bad</a></p><p> </p>
        <pre><code class="language-ts">if (x) {
    let y = 1;
}</code></pre>
      </div>`, "https://blog.example.com/posts/1");
    expect(html).toContain("<h2>Intro</h2>");
    expect(html).toContain('<a href="https://blog.example.com/docs?a=1&b=2">the docs</a>');
    expect(html).toMatch(/<img (?=[^>]*src="https:\/\/blog\.example\.com\/img\/cat\.png")(?=[^>]*alt="A cat")[^>]*>/);
    expect(html).toContain("<figcaption>The cat</figcaption>");
    expect(html).toContain('<code class="language-ts">if (x) {\n    let y = 1;\n}</code></pre>');
    expect(html!.split("\n").slice(0, 3)).toEqual(["<h2>Intro</h2>", '<p>Read <a href="https://blog.example.com/docs?a=1&b=2">the docs</a>.</p>', expect.stringMatching(/^<figure><img /)]);
    expect(html).not.toMatch(/nav|Home|script|alert|style=|onclick|class="wrap"|<div|javascript:|<picture|data:image/);
  });
});

describe("document agent", () => {
  const source = (content: string, format: DocumentSource["format"] = "html"): DocumentSource => ({
    content, format, title: "Widgets", siteName: "Widget Weekly", sourceUrl: "https://news.example.com/widgets", imageUrl: null,
  });

  it("splits at line boundaries and hard-splits only overlong lines", () => {
    expect(splitIntoParts("aaaa\nbbbb\ncccc", 9)).toEqual(["aaaa\nbbbb", "cccc"]);
    expect(splitIntoParts("x".repeat(20), 8)).toEqual(["xxxxxxxx", "xxxxxxxx", "xxxx"]);
  });

  it("collects the links and images a document must keep", () => {
    expect(sourceLinks('<a href="https://a.com/x?a=1&amp;b=2">a</a><img src="https://a.com/i.png"><a href="mailto:x@y.z">m</a>', "html"))
      .toEqual(["https://a.com/x?a=1&b=2", "https://a.com/i.png"]);
    expect(sourceLinks("see https://a.com/page.", "text")).toEqual(["https://a.com/page"]);
  });

  it("strips a fence around a whole section but keeps code blocks inside it", () => {
    expect(stripFence("```markdown\n# Title\n\nBody\n```")).toBe("# Title\n\nBody");
    const markdown = "# Title\n\n```js\nlet x = 1;\n```\n\nMore";
    expect(stripFence(markdown)).toBe(markdown);
  });

  it("reads and writes every part, then fixes the links finish reports missing", async () => {
    const part1 = `<h1>Widgets</h1>\n<p>See <a href="https://a.com/one">one</a>.</p>`;
    const part2 = `<p>And <img src="https://a.com/two.png" alt="two">.</p>`;
    const { model, prompts } = scriptedModel([
      [{ toolName: "writeSection", input: { part: 1, markdown: "# Widgets\n\nSee one." } }, { toolName: "readPart", input: { part: 2 } }],
      [{ toolName: "writeSection", input: { part: 2, markdown: "And ![two](https://a.com/two.png)." } }, { toolName: "finish", input: {} }],
      [{ toolName: "writeSection", input: { part: 1, markdown: "```markdown\n# Widgets\n\nSee [one](https://a.com/one).\n```" } }, { toolName: "finish", input: {} }],
    ]);
    const markdown = await writeDocument(model, source(`${part1}\n${part2}`), { partChars: part1.length + 1 });
    expect(markdown).toBe("# Widgets\n\nSee [one](https://a.com/one).\n\nAnd ![two](https://a.com/two.png).");
    expect(prompts).toHaveLength(3);
    expect(JSON.stringify(prompts[0])).toContain("Original: https://news.example.com/widgets");
    expect(toolOutputs(prompts[1])).toContain('<img src=\\"https://a.com/two.png\\"');
    expect(toolOutputs(prompts[2])).toContain("https://a.com/one");
    expect(toolOutputs(prompts[2])).toContain('"done":false,"unwrittenParts":[],"missingLinks":["https://a.com/one"]');
  }, 10_000);

  it("gives up (null) when the agent stops before writing every part", async () => {
    const { model } = scriptedModel([[{ toolName: "writeSection", input: { part: 1, markdown: "# A" } }]]);
    expect(await writeDocument(model, source(`${"a".repeat(30_000)}\n${"b".repeat(30_000)}`, "text"))).toBeNull();
  });
});

describe("source markdown pending state", () => {
  const row = (contentMarkdown: string | null, minutesAgo = 1, sourceType: "url" | "local" = "url") => ({
    contentMarkdown, sourceType, ownerId: "owner", createdAt: new Date(Date.now() - minutesAgo * 60_000),
  });

  it("is pending only while the empty placeholder is recent", () => {
    expect(isSourceMarkdownPending(row(""), "owner")).toBe(true);
    expect(isSourceMarkdownPending(row("", 10), "owner")).toBe(false);
    expect(isSourceMarkdownPending(row(null), "owner")).toBe(false);
    expect(isSourceMarkdownPending(row("# Doc"), "owner")).toBe(false);
  });

  it("hides a local file's pending document from everyone but its owner", () => {
    expect(isSourceMarkdownPending(row("", 1, "local"), "owner")).toBe(true);
    expect(isSourceMarkdownPending(row("", 1, "local"), "someone")).toBe(false);
  });
});
