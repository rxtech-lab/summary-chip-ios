import type { LanguageModelV4, LanguageModelV4CallOptions, LanguageModelV4StreamPart } from "@ai-sdk/provider";
import type { LanguageModel } from "ai";
import type { TranslationLanguage } from "@/lib/contracts/api";
import type { AiProvider, CoverInput, DesignInput, LanguageInput, MarkdownInput, MarkdownOptions, ModelPricing, SummarizeInput, TranslateInput, TranslateOptions, TripAgentCallOptions } from "./provider";
import type { TripAgentInput, TripAgentResult } from "./trip-agent";
import type { TripChangeInput } from "./trip-change-agent";
import type { TripBriefingInput } from "./trip-briefing-agent";
import type { TourNarrationInput, TourNarrationOptions } from "./tour-agent";
import type { TourNarration } from "@/lib/contracts/tour";
import { normalizeSourceUrl, sameContentStart, type DuplicateInput, type DuplicateTools, type DuplicateVerdict } from "./duplicate-agent";
import type { LlmSummary, LlmTranslation } from "./summary-schema";

/** One model step of 10 input + 10 output tokens. */
const MOCK_STEP_USAGE = { inputTokens: 10, outputTokens: 10, totalTokens: 20 } as Parameters<NonNullable<MarkdownOptions["onUsage"]>>[0];

/** Deterministic stand-in for tests and `SUMMARY_MOCK_SERVICES=true` local development. */
export class MockAiProvider implements AiProvider {
  readonly calls: {
    isSharedLink: string[];
    summarize: SummarizeInput[];
    formatMarkdown: MarkdownInput[];
    detectLanguage: LanguageInput[];
    translateSummary: TranslateInput[];
    translateDocument: { markdown: string; to: TranslationLanguage }[];
    translateStrings: { texts: string[]; to: TranslationLanguage }[];
    findDuplicate: DuplicateInput[];
    updateTrip: TripAgentInput[];
    summarizeTripChanges: TripChangeInput[];
    briefTripDay: TripBriefingInput[];
    designCover: CoverInput[];
    designSvg: DesignInput[];
    illustrate: DesignInput[];
    narrateTour: TourNarrationInput[];
    speak: string[];
  } = {
    isSharedLink: [],
    summarize: [],
    formatMarkdown: [],
    detectLanguage: [],
    translateSummary: [],
    translateDocument: [],
    translateStrings: [],
    findDuplicate: [],
    updateTrip: [],
    summarizeTripChanges: [],
    briefTripDay: [],
    designCover: [],
    designSvg: [],
    illustrate: [],
    narrateTour: [],
    speak: [],
  };

  /** A share snippet is a URL with under 200 characters of accompanying text. */
  async isSharedLink(text: string): Promise<boolean> {
    this.calls.isSharedLink.push(text);
    return text.replace(/https?:\/\/\S+/gi, "").trim().length < 200;
  }

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

  /** The text under its title as a heading; `null` from tests simulates a failed rewrite. */
  markdown: ((input: MarkdownInput) => string | null) | undefined;

  /** One agent step of 10 input + 10 output tokens, reported like the real agent does. */
  async formatMarkdown(input: MarkdownInput, options: MarkdownOptions = {}): Promise<string | null> {
    this.calls.formatMarkdown.push(input);
    options.onUsage?.(MOCK_STEP_USAGE);
    if (this.markdown) return this.markdown(input);
    return `${input.title ? `# ${input.title}\n\n` : ""}${input.content.trim()}`;
  }

  /** Judges by script: kana → ja, hangul → ko, other Han → zh-Hans; anything else is left undetected (null). */
  async detectLanguage(input: LanguageInput): Promise<TranslationLanguage | null> {
    this.calls.detectLanguage.push(input);
    const text = `${input.title} ${input.summary}`;
    if (/[\p{Script=Hiragana}\p{Script=Katakana}]/u.test(text)) return "ja";
    if (/\p{Script=Hangul}/u.test(text)) return "ko";
    if (/\p{Script=Han}/u.test(text)) return "zh-Hans";
    return null;
  }

  /** False from tests simulates a failed translation. */
  translates = true;

  /** Prefixes every field with the target language, e.g. "[ja] Title"; one call of 10 input + 10 output tokens. */
  async translateSummary(input: TranslateInput, options: TranslateOptions = {}): Promise<LlmTranslation | null> {
    this.calls.translateSummary.push(input);
    options.onUsage?.(MOCK_STEP_USAGE);
    if (!this.translates) return null;
    const tag = (text: string) => `[${input.to}] ${text}`;
    return { title: tag(input.title), summary: tag(input.summary), highlights: input.highlights.map(tag), tags: input.tags.map(tag), headline: input.headline ? tag(input.headline) : "" };
  }

  async translateDocument(markdown: string, to: TranslationLanguage, options: TranslateOptions = {}): Promise<string | null> {
    this.calls.translateDocument.push({ markdown, to });
    options.onUsage?.(MOCK_STEP_USAGE);
    return this.translates ? `[${to}] ${markdown}` : null;
  }

  async translateStrings(texts: string[], to: TranslationLanguage, options: TranslateOptions = {}): Promise<(string | null)[] | null> {
    this.calls.translateStrings.push({ texts, to });
    options.onUsage?.(MOCK_STEP_USAGE);
    return this.translates ? texts.map((text) => `[${to}] ${text}`) : null;
  }

  /**
   * Plays the agent: searches by title, reads the candidates and the hits, and flags the first chip
   * with the same normalised source URL, the same title (case-insensitive) or the same content start.
   */
  async findDuplicate(input: DuplicateInput, tools: DuplicateTools): Promise<DuplicateVerdict | null> {
    this.calls.findDuplicate.push(input);
    const listed = new Map([...tools.candidates, ...await tools.search(input.title)].map((chip) => [chip.id, chip]));
    const url = normalizeSourceUrl(input.sourceUrl);
    for (const id of listed.keys()) {
      const chip = await tools.read(id);
      if (!chip) continue;
      if (url && normalizeSourceUrl(chip.sourceUrl) === url) return { duplicateOf: id, reason: "Same source URL." };
      if (chip.title.trim().toLowerCase() === input.title.trim().toLowerCase()) return { duplicateOf: id, reason: "Same title." };
      if (sameContentStart(chip.content, input.text)) return { duplicateOf: id, reason: "Same content." };
    }
    return { duplicateOf: null, reason: "No chip shares the source, title or content." };
  }

  /** What the trip agent answers; `null` from tests simulates a failed run. Default: a note with the source's start, and the source's URL. */
  tripAgent: ((input: TripAgentInput) => TripAgentResult | null) | undefined;

  /** One agent step of 10 input + 10 output tokens, reported like the real agent does. */
  async updateTrip(input: TripAgentInput, options: TripAgentCallOptions = {}): Promise<TripAgentResult | null> {
    this.calls.updateTrip.push(input);
    options.onUsage?.(MOCK_STEP_USAGE);
    if (this.tripAgent) return this.tripAgent(input);
    const title = input.source.title?.trim() || "Shared note";
    return {
      operations: [
        { op: "upsert_note", note: { id: `note-${input.document.notes.length + 1}`, title: title.slice(0, 300), text: input.source.text.slice(0, 1_000) } },
        ...(input.source.url ? [{ op: "add_source" as const, source: { title: title.slice(0, 300), url: input.source.url } }] : []),
      ],
      changeSummary: `Added a note: ${title}`,
    };
  }

  async designCover(input: CoverInput): Promise<LlmSummary["design"] | null> {
    this.calls.designCover.push(input);
    return { colors: ["#1e1b4b", "#4c1d95", "#7c3aed", "#c084fc"], mode: "dark", emoji: "🦋", accent: "#facc15", headline: input.title.slice(0, 70) };
  }

  async summarizeTripChanges(input: TripChangeInput): Promise<string> {
    this.calls.summarizeTripChanges.push(input);
    return `Updated ${[...new Set(input.changes.map((change) => change.section))].join(", ")}.`;
  }

  async briefTripDay(input: TripBriefingInput): Promise<string> {
    this.calls.briefTripDay.push(input);
    const departure = input.transports[0]?.departure?.slice(11);
    const forecast = input.weather[0];
    return [...`Tomorrow: ${input.days[0]?.title ?? input.transports[0]?.label ?? "Trip"}${departure ? `, depart ${departure}` : ""}${forecast ? `. ${forecast.place}: ${forecast.condition}, ${forecast.low}–${forecast.high}°C` : ""}.`].slice(0, 140).join("");
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

  chatModelId(): string {
    return "mock/chat";
  }

  /** $0.01 per input and $0.04 per output token, so a mock turn's cost is easy to read in points. */
  pricing: ModelPricing | null = { input: 0.01, output: 0.04 };

  async chatPricing(): Promise<ModelPricing | null> {
    return this.pricing;
  }

  async narrateTour(input: TourNarrationInput, options: TourNarrationOptions = {}): Promise<TourNarration[]> {
    this.calls.narrateTour.push(input);
    options.onUsage?.(MOCK_STEP_USAGE);
    return input.scenes.map((scene, index) => ({
      title: `${scene.kind} ${index + 1}`,
      narration: `Scene ${index + 1}: ${String(scene.facts.name ?? scene.facts.title ?? input.trip.title ?? scene.kind)}.`,
      visuals: [],
    }));
  }

  tourModelId(): string {
    return "mock/tour";
  }

  async tourPricing(): Promise<ModelPricing | null> {
    return this.pricing;
  }

  speechModelId(): string | null {
    return "mock/speech";
  }

  /** $0.01 per character, so a mock narration's cost is easy to read in points. */
  speechUsdPerCharacter(): number {
    return 0.01;
  }

  async speak(text: string): Promise<{ bytes: Uint8Array; mediaType: string }> {
    this.calls.speak.push(text);
    return { bytes: new TextEncoder().encode(`ID3 mock audio: ${text}`), mediaType: "audio/mpeg" };
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
