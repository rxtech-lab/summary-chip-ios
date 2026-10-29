import { splitPodcastCaptions } from "./podcast-caption-splitting";
import type { CaptionCue } from "@/lib/podcast-video/captions";
import type { PodcastInput } from "./podcast-agent";
import type { PodcastVideoDraft, PodcastVideoInput, PodcastVideoTurnOptions, PodcastVideoTurnResult } from "./podcast-video-agent";
import type { PodcastTranslationInput } from "./podcast-translation";
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
import type { ReferenceInput, ReferenceTools, ReferenceVerdict } from "./reference-agent";
import type { LlmSummary, LlmTranslation } from "./summary-schema";
import type { PodcastVideoStyle } from "@/lib/contracts/daily-podcast";
import type { Cutout } from "@/lib/podcast-video/cutout";
import sharp from "sharp";

/** One model step of 10 input + 10 output tokens. */
const MOCK_STEP_USAGE = { inputTokens: 10, outputTokens: 10, totalTokens: 20 } as Parameters<NonNullable<MarkdownOptions["onUsage"]>>[0];

/** Kana → ja, hangul → ko, other Han → zh-Hans; anything else is left undetected (null). */
function languageByScript(text: string): TranslationLanguage | null {
  if (/[\p{Script=Hiragana}\p{Script=Katakana}]/u.test(text)) return "ja";
  if (/\p{Script=Hangul}/u.test(text)) return "ko";
  if (/\p{Script=Han}/u.test(text)) return "zh-Hans";
  return null;
}

/** Deterministic stand-in for tests and `SUMMARY_MOCK_SERVICES=true` local development. */
export class MockAiProvider implements AiProvider {
  readonly calls: {
    isSharedLink: string[];
    summarize: SummarizeInput[];
    formatMarkdown: MarkdownInput[];
    detectLanguage: LanguageInput[];
    detectSourceLanguage: string[];
    translateSummary: TranslateInput[];
    translateDocument: { markdown: string; to: TranslationLanguage }[];
    translateStrings: { texts: string[]; to: TranslationLanguage }[];
    findDuplicate: DuplicateInput[];
    checkReference: ReferenceInput[];
    updateTrip: TripAgentInput[];
    summarizeTripChanges: TripChangeInput[];
    briefTripDay: TripBriefingInput[];
    designCover: CoverInput[];
    designSvg: DesignInput[];
    illustrate: DesignInput[];
    narrateTour: TourNarrationInput[];
    speak: string[];
    composeMusic: string[];
    writePodcastVideo: PodcastVideoInput[];
    drawPodcastVideoImage: { subject: string; style?: PodcastVideoStyle }[];
    drawStoryboardFrame: import("./provider").StoryboardShot[];
    translatePodcast: PodcastTranslationInput[];
    translatePodcastVideo: { files: Record<string, string>; language: string }[];
  } = {
    isSharedLink: [],
    summarize: [],
    formatMarkdown: [],
    detectLanguage: [],
    detectSourceLanguage: [],
    translateSummary: [],
    translateDocument: [],
    translateStrings: [],
    findDuplicate: [],
    checkReference: [],
    updateTrip: [],
    summarizeTripChanges: [],
    briefTripDay: [],
    designCover: [],
    designSvg: [],
    illustrate: [],
    narrateTour: [],
    speak: [],
    composeMusic: [],
    writePodcastVideo: [],
    drawPodcastVideoImage: [],
    drawStoryboardFrame: [],
    translatePodcast: [],
    translatePodcastVideo: [],
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

  /** Judges by script (`languageByScript`). */
  async detectLanguage(input: LanguageInput): Promise<TranslationLanguage | null> {
    this.calls.detectLanguage.push(input);
    return languageByScript(`${input.title} ${input.summary}`);
  }

  /** Judged by script like `detectLanguage`. */
  async detectSourceLanguage(text: string): Promise<TranslationLanguage | null> {
    this.calls.detectSourceLanguage.push(text);
    return languageByScript(text);
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

  /**
   * Opens the entry's link (a dead one is `link_not_found`); a title with "fabricated" in it is
   * `reference_not_found`; anything else is verified.
   */
  async checkReference(input: ReferenceInput, tools: ReferenceTools): Promise<ReferenceVerdict | null> {
    this.calls.checkReference.push(input);
    if (input.url && !(await tools.openLink(input.url)).reachable) {
      return { status: "error", issue: "link_not_found", message: `The link ${input.url} doesn't open.` };
    }
    if (/fabricated/i.test(input.fields.title ?? input.fields.text ?? "")) {
      return { status: "error", issue: "reference_not_found", message: "No work with this title and these authors could be found." };
    }
    return { status: "verified", issue: null, message: "Found the work as described." };
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

  podcastModelId(): string {
    return "mock/podcast";
  }

  async podcastPricing(): Promise<ModelPricing | null> {
    return this.pricing;
  }

  async writePodcastSummary(_podcast: import("@/lib/contracts/daily-podcast").DailyPodcast, options?: TourNarrationOptions) {
    options?.onUsage?.(MOCK_STEP_USAGE);
    return "A roundup of the recorded stories and their main takeaways.";
  }

  async writePodcastArticle(podcast: import("@/lib/contracts/daily-podcast").DailyPodcast) {
    return { description: `Explore ${podcast.title}.`, sections: [{ heading: podcast.title,
      paragraphs: ["An editorial overview of the episode’s central ideas and their implications."], segmentIndex: 0 }] };
  }

  async writePodcast(input: PodcastInput) {
    return { title: "Your daily podcast", summary: "A roundup of the selected stories and their main takeaways.", mood: "calm" as const, speakers: (input.speakerNames ?? ["Alex"]).map((name, index) => ({ name, voice: input.voices[index] })),
      segments: input.chips.map((chip, index) => ({ speaker: index % (input.speakerNames?.length ?? 1), chipId: chip.id, caption: chip.summary.slice(0, 500), ...(input.storyboard ? { camera: "Wide shot of the story artwork, slow push in, then dissolve to the next story." } : {}) })) };
  }

  async refinePodcastPlan(input: import("./podcast-agent").PodcastPlanRefinementInput, options: TourNarrationOptions = {}) {
    options.onUsage?.(MOCK_STEP_USAGE);
    return { reply: "Updated the plan.", script: { ...input.script, segments: input.script.segments.map((segment, index) => index === 0
      ? { ...segment, camera: `${segment.camera} Revised: ${input.request.slice(0, 200)}` } : segment) } };
  }

  /** Storyboard frames are off unless a test opts in. */
  storyboardImageModelId(): string | null {
    return this.storyboardFrames ? "mock/storyboard" : null;
  }

  storyboardImageUsdPerImage(): number {
    return 0.05;
  }

  async drawStoryboardFrame(shot: import("./provider").StoryboardShot) {
    this.calls.drawStoryboardFrame.push(shot);
    const png = await sharp({ create: { width: 1280, height: 720, channels: 3, background: "#336699" } }).png().toBuffer();
    return { png: new Uint8Array(png), width: 1280, height: 720 };
  }

  async translatePodcast(input: PodcastTranslationInput, options: TourNarrationOptions = {}) {
    this.calls.translatePodcast.push(input);
    options.onUsage?.(MOCK_STEP_USAGE);
    if (!this.translates) throw new Error("mock translation failed");
    return { title: `[${input.language}] ${input.title}`, chipTitles: input.chips.map((chip) => `[${input.language}] ${chip.title}`),
      captions: input.segments.map((segment) => `[${input.language}] ${segment.caption}`.slice(0, 500)) };
  }

  async translatePodcastVideo(files: Record<string, string>, language: string, options: TourNarrationOptions = {}) {
    this.calls.translatePodcastVideo.push({ files, language });
    options.onUsage?.(MOCK_STEP_USAGE);
    return this.translates ? Object.fromEntries(Object.entries(files).map(([path, source]) => [path, `// ${language}\n${source}`])) : null;
  }

  /** Videos are off unless a test opts in, like music. */
  video = false;

  podcastVideoModelId(): string | null {
    return this.video ? "mock/video" : null;
  }

  async podcastVideoPricing(): Promise<ModelPricing | null> {
    return this.pricing;
  }

  async writePodcastVideo(input: PodcastVideoInput, options: TourNarrationOptions = {}): Promise<Record<string, string> | null> {
    this.calls.writePodcastVideo.push(input);
    options.onUsage?.(MOCK_STEP_USAGE);
    return { "src/Video.tsx": MOCK_PODCAST_VIDEO };
  }

  /** A background run's turn: the whole mock design in one turn, so spies on `writePodcastVideo` shape it. */
  async podcastVideoTurn(input: PodcastVideoInput, draft: PodcastVideoDraft, options: PodcastVideoTurnOptions = {}): Promise<PodcastVideoTurnResult> {
    const result = await this.writePodcastVideo(input, { abortSignal: options.abortSignal, onUsage: options.onUsage });
    // Without a result the run is over too: it spent its submissions.
    return { draft: { ...draft, turns: draft.turns + 1, files: result ?? draft.files, result, attempts: result ? draft.attempts + 1 : 5 },
      evidence: result ? "Validation passed" : "Validation failed" };
  }

  /** Images are off unless a test opts in, like videos. */
  images = false;
  /** Tests opt in to storyboard frames for podcast plans. */
  storyboardFrames = false;

  imageModelId(): string | null {
    return this.images ? "mock/image" : null;
  }

  /** $0.04 per image. */
  imageUsdPerImage(): number {
    return 0.04;
  }

  /** A 64×48 orange cut-out on a transparent canvas. */
  async drawPodcastVideoImage(subject: string, style?: PodcastVideoStyle): Promise<Cutout> {
    this.calls.drawPodcastVideoImage.push({ subject, style });
    const png = await sharp({ create: { width: 64, height: 48, channels: 4, background: { r: 240, g: 140, b: 40, alpha: 1 } } }).png().toBuffer();
    return { png: new Uint8Array(png), width: 64, height: 48 };
  }

  speechModelId(): string | null {
    return "mock/speech";
  }

  /** $0.01 per character, so a mock narration's cost is easy to read in points. */
  speechUsdPerCharacter(): number {
    return 0.01;
  }

  async splitPodcastCaptions(cues: CaptionCue[], options?: { abortSignal?: AbortSignal }) {
    return splitPodcastCaptions(cues, options?.abortSignal, async () => null);
  }

  async transcribePodcast(audio: Uint8Array) {
    const size = audio[6] * 2097152 + audio[7] * 16384 + audio[8] * 128 + audio[9];
    return [{ text: new TextDecoder().decode(audio.subarray(21, 10 + size)), startSecond: 0, endSecond: 4 * 1152 / 44100 }];
  }

  async speak(text: string): Promise<{ bytes: Uint8Array; mediaType: string }> {
    this.calls.speak.push(text);
    // A valid ID3 title keeps tests able to identify which text was spoken, followed by silent MP3 frames.
    const title = new TextEncoder().encode(text);
    const tagSize = 11 + title.length;
    const bytes = new Uint8Array(10 + tagSize + 417 * 4);
    const syncsafe = (size: number) => [(size >> 21) & 127, (size >> 14) & 127, (size >> 7) & 127, size & 127];
    bytes.set([73, 68, 51, 4, 0, 0, ...syncsafe(tagSize)]);
    bytes.set([84, 73, 84, 50, ...syncsafe(title.length + 1), 0, 0, 3], 10);
    bytes.set(title, 21);
    for (let at = 10 + tagSize; at < bytes.length; at += 417) bytes.set([0xff, 0xfb, 0x90, 0xc0], at);
    return { bytes, mediaType: "audio/mpeg" };
  }

  /** Music is off unless a test opts in, keeping other podcast tests on the plain recording. */
  music = false;

  musicModelId(): string | null {
    return this.music ? "mock/music" : null;
  }

  musicUsdPerClip(): number {
    return 0.04;
  }

  async composeMusic(prompt: string): Promise<Uint8Array> {
    this.calls.composeMusic.push(prompt);
    // Two seconds of silent stereo 44.1 kHz frames.
    const bytes = new Uint8Array(417 * 77);
    for (let at = 0; at < bytes.length; at += 417) bytes.set([0xff, 0xfb, 0x90, 0x00], at);
    return bytes;
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

/** A deterministic animated composition without burned captions. */
export const MOCK_PODCAST_VIDEO = `import { AbsoluteFill, useCurrentFrame } from "remotion";
import { podcast } from "./podcast";
export const PodcastVideo: React.FC = () => {
  const frame = useCurrentFrame();
  return <AbsoluteFill style={{ backgroundColor: "#242354", color: "white", justifyContent: "center", alignItems: "center", fontSize: 48 }}>
    <div style={{transform: "translateX(" + Math.sin(frame / 24) * 100 + "px)"}}>{podcast.title}</div>
  </AbsoluteFill>;
};
`;
