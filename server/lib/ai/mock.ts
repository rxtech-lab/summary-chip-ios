import type { LanguageModelV4, LanguageModelV4CallOptions, LanguageModelV4StreamPart } from "@ai-sdk/provider";
import type { LanguageModel } from "ai";
import type { AiProvider, DesignInput, SummarizeInput } from "./provider";
import type { LlmSummary } from "./summary-schema";

/** Deterministic stand-in for tests and `SUMMARY_MOCK_SERVICES=true` local development. */
export class MockAiProvider implements AiProvider {
  readonly calls: { summarize: SummarizeInput[]; designSvg: DesignInput[]; illustrate: DesignInput[] } = {
    summarize: [],
    designSvg: [],
    illustrate: [],
  };

  async summarize(input: SummarizeInput): Promise<LlmSummary> {
    this.calls.summarize.push(input);
    const words = input.text.split(/\s+/).filter((word) => word.length > 3);
    const firstSentence = input.text.split(/(?<=[.!?。！？])\s*/)[0]?.slice(0, 200) ?? input.text.slice(0, 200);
    const tags = [...new Set(words.slice(0, 20).map((word) => word.toLowerCase().replace(/[^\p{L}\p{N}-]/gu, "")).filter(Boolean))].slice(0, 4);
    return {
      title: input.title ?? `Summary of ${firstSentence.slice(0, 60)}`,
      summary: `${firstSentence} This mock summary was generated for testing.`,
      highlights: ["First key point.", "Second key point.", "Third key point."],
      category: "Technology",
      tags: tags.length >= 3 ? tags : ["mock", "summary", "test"],
      keywords: ["mock", "summary", "chip", "test", "keywords"],
      language: input.language === "auto" ? (input.sourceLang ?? "en") : input.language,
      design: {
        colors: ["#0f172a", "#1d4ed8", "#38bdf8", "#e0f2fe"],
        mode: "dark",
        emoji: "🧪",
        accent: "#f59e0b",
        headline: (input.title ?? firstSentence).slice(0, 70),
      },
    };
  }

  async designSvg(input: DesignInput): Promise<string | null> {
    this.calls.designSvg.push(input);
    const [a, b, c] = input.colors;
    return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 630"><circle cx="960" cy="200" r="180" fill="${a}" opacity="0.6"/><rect x="820" y="330" width="260" height="200" rx="40" fill="${b}" opacity="0.5"/><path d="M700 600 Q900 400 1200 520" stroke="${c}" stroke-width="18" fill="none"/></svg>`;
  }

  async illustrate(input: DesignInput): Promise<Uint8Array | null> {
    this.calls.illustrate.push(input);
    return null;
  }

  chatModel(): LanguageModel {
    return createMockChatModel();
  }

  embeddingModelId(): string | null {
    return MOCK_EMBEDDING_MODEL;
  }

  async embed(values: string[]): Promise<number[][]> {
    return values.map(mockEmbedding);
  }
}

export const MOCK_EMBEDDING_MODEL = "mock/bag-of-words";
const MOCK_EMBEDDING_DIMENSIONS = 4096;

/**
 * Hashed set of words: texts sharing words point the same way, unrelated texts are near
 * orthogonal. Not semantic, but enough to exercise vector ranking deterministically.
 */
export function mockEmbedding(text: string): number[] {
  const vector = Array.from({ length: MOCK_EMBEDDING_DIMENSIONS }, () => 0);
  for (const word of text.toLowerCase().match(/[\p{L}\p{N}]+/gu) ?? []) {
    let hash = 2166136261;
    for (const char of word) hash = Math.imul(hash ^ char.codePointAt(0)!, 16777619);
    vector[(hash >>> 0) % MOCK_EMBEDDING_DIMENSIONS] = 1;
  }
  // An all-zero vector has no direction; give empty texts a constant one instead.
  if (!vector.includes(1)) vector[0] = 1;
  return vector;
}

function lastUserText(options: LanguageModelV4CallOptions): string {
  for (let index = options.prompt.length - 1; index >= 0; index -= 1) {
    const message = options.prompt[index];
    if (message.role === "user") {
      return message.content.map((part) => (part.type === "text" ? part.text : "")).join(" ").trim();
    }
  }
  return "";
}

const usage = {
  inputTokens: { total: 10, noCache: 10, cacheRead: 0, cacheWrite: 0 },
  outputTokens: { total: 10, text: 10, reasoning: 0 },
};

function streamOf(parts: LanguageModelV4StreamPart[]): ReadableStream<LanguageModelV4StreamPart> {
  return new ReadableStream({
    start(controller) {
      for (const part of parts) controller.enqueue(part);
      controller.close();
    },
  });
}

/**
 * First step: calls `searchSummaries` with the user's words. Second step (after the tool result):
 * replies with text. Enough to exercise the tool loop and the UI message stream end to end.
 */
export function createMockChatModel(): LanguageModelV4 {
  const respond = (options: LanguageModelV4CallOptions): LanguageModelV4StreamPart[] => {
    const last = options.prompt[options.prompt.length - 1];
    if (last?.role === "tool") {
      return [
        { type: "stream-start", warnings: [] },
        { type: "text-start", id: "t1" },
        { type: "text-delta", id: "t1", delta: "Here is what I found in your library." },
        { type: "text-end", id: "t1" },
        { type: "finish", usage, finishReason: { unified: "stop", raw: "stop" } },
      ];
    }
    return [
      { type: "stream-start", warnings: [] },
      {
        type: "tool-call",
        toolCallId: "call-1",
        toolName: "searchSummaries",
        input: JSON.stringify({ query: lastUserText(options), scope: "all" }),
      },
      { type: "finish", usage, finishReason: { unified: "tool-calls", raw: "tool_calls" } },
    ];
  };
  return {
    specificationVersion: "v4",
    provider: "mock",
    modelId: "mock-chat",
    supportedUrls: {},
    async doGenerate() {
      throw new Error("The mock chat model only streams");
    },
    async doStream(options) {
      return { stream: streamOf(respond(options)) };
    },
  };
}
