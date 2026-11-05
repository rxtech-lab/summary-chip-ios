import { afterEach, describe, expect, it, vi } from "vitest";
import { audiobookVoices, speechRoute, voiceUsdPerCharacter } from "@/lib/ai/voices";
import { azureSsml } from "@/lib/ai/azure-speech";
import { MAX_AUDIOBOOK_CHAPTER_SECONDS, audiobookPlanSchema, type AudiobookPlanDocument } from "@/lib/contracts/audiobook";
import { chipSourceText, narrationRatio, narrationSeconds, normalizeAudiobookPlan, splitPassages } from "@/lib/services/audiobook-source";
import type { SummaryRow } from "@/lib/db/schema";
import type { ObjectStore } from "@/lib/storage/r2";
import { assignStretches } from "@/lib/services/audiobooks";

vi.mock("@/lib/extract/pdf", () => ({ extractPdfText: vi.fn(async (bytes: Uint8Array) => {
  if (!bytes.length) throw new Error("not a PDF");
  return { text: "The whole book, every chapter of it.", title: null, pages: 300 };
}) }));

afterEach(() => vi.unstubAllEnvs());

describe("source text", () => {
  const chip = (fields: Partial<SummaryRow>) => ({ id: "c", ownerId: "me", source: "pdf", sourceFileKey: "k.pdf", contentText: "Capped", contentExcerpt: null, ...fields }) as SummaryRow;
  const store = (bytes: number[]) => ({ get: async () => ({ bytes: Uint8Array.from(bytes), contentType: "application/pdf" }) }) as unknown as ObjectStore;
  it("reads the viewer's own PDF again, because stored text is capped", async () => {
    expect(await chipSourceText(chip({}), "me", store([1]))).toContain("whole book");
  });
  it("never opens someone else's upload", async () => {
    expect(await chipSourceText(chip({ ownerId: "them" }), "me", store([1]))).toBe("Capped");
  });
  it("falls back to the stored text when the PDF can't be read", async () => {
    expect(await chipSourceText(chip({}), "me", store([]))).toBe("Capped");
  });
  it("uses stored text for other sources", async () => {
    expect(await chipSourceText(chip({ source: "web" as SummaryRow["source"], sourceFileKey: null }), "me", store([1]))).toBe("Capped");
  });
});

const passage = (characters: number) => ({ text: "a".repeat(characters) });
const plan = (chapters: Partial<AudiobookPlanDocument["chapters"][number]>[], cues = ["m1", "m2", "m3"]): AudiobookPlanDocument => ({
  title: "Book", summary: "A book.", speakers: [{ name: "N", voice: "elevenlabs:x", role: "" }], visualGuide: "", videoTheme: "cinematic",
  musicCues: cues.map(id => ({ id, title: id, prompt: "piano", mood: "calm" as const })),
  chapters: chapters.map((chapter, index) => ({ title: `C${index}`, synopsis: "s", firstPassage: 0, lastPassage: 0, music: ["m1"], scenes: [], ...chapter })),
});

describe("voices", () => {
  it("routes by prefix and leaves other voices to the default model", () => {
    expect(speechRoute("elevenlabs:abc")).toEqual({ provider: "elevenlabs", voice: "abc" });
    expect(speechRoute("azure:en-US-AvaMultilingualNeural")).toEqual({ provider: "azure", voice: "en-US-AvaMultilingualNeural" });
    expect(speechRoute("en-US-Harper")).toEqual({ provider: "default", voice: "en-US-Harper" });
  });

  it("offers the ElevenLabs voices always and Azure only with credentials", () => {
    vi.stubEnv("AZURE_SPEECH_KEY", "");
    vi.stubEnv("AZURE_SPEECH_REGION", "");
    const eleven = audiobookVoices();
    expect(eleven.map(voice => voice.name)).toEqual(["Bella", "Roger", "Sarah", "Laura", "Charlie"]);
    vi.stubEnv("AZURE_SPEECH_KEY", "key");
    vi.stubEnv("AZURE_SPEECH_REGION", "eastus");
    const all = audiobookVoices();
    expect(all.some(voice => voice.provider === "azure")).toBe(true);
    // A translation is read by the same speakers, so every voice must speak every language.
    expect(all.filter(voice => voice.provider === "azure").every(voice => voice.id.endsWith("MultilingualNeural"))).toBe(true);
    expect(new Set(all.map(voice => voice.id)).size).toBe(all.length);
  });

  it("prices each provider, and leaves other voices to the caller", () => {
    expect(voiceUsdPerCharacter("elevenlabs:x")).toBe(0.00004);
    expect(voiceUsdPerCharacter("azure:x")).toBe(0.000016);
    expect(voiceUsdPerCharacter("en-US-Harper")).toBeNull();
    vi.stubEnv("AZURE_SPEECH_USD_PER_CHARACTER", "0.5");
    expect(voiceUsdPerCharacter("azure:x")).toBe(0.5);
  });

  it("escapes text in SSML, so a source can't break out of the voice element", () => {
    const ssml = azureSsml("en-GB-AdaMultilingualNeural", `Tom & "Jerry" </voice><evil>`);
    expect(ssml).toContain("Tom &amp; &quot;Jerry&quot; &lt;/voice&gt;&lt;evil&gt;");
    expect(ssml).toContain('xml:lang="en-GB"');
  });
});

describe("passages", () => {
  it("cuts at paragraph ends and never exceeds the size", () => {
    const text = Array.from({ length: 40 }, (_, index) => `Paragraph ${index}. ${"word ".repeat(40)}`).join("\n\n");
    const passages = splitPassages(text, 1000);
    expect(passages.length).toBeGreaterThan(5);
    expect(passages.every(item => item.length <= 1000)).toBe(true);
    expect(passages.join(" ").replace(/\s+/g, " ")).toContain("Paragraph 39.");
  });

  it("splits unbroken CJK text at sentence ends and even a text with none", () => {
    expect(splitPassages("这是一句话。".repeat(600), 500).every(item => item.length <= 500)).toBe(true);
    expect(splitPassages("字".repeat(1200), 500).every(item => item.length <= 500)).toBe(true);
  });

  it("reads CJK slower per character than alphabetic text", () => {
    expect(narrationSeconds("字".repeat(100))).toBeGreaterThan(narrationSeconds("a".repeat(100)));
  });

  it("condenses only past the target or the four-hour limit", () => {
    expect(narrationRatio(600)).toBe(1);
    expect(narrationRatio(3600, 1800)).toBe(0.5);
    expect(narrationRatio(8 * 3600)).toBe(0.5);
  });
});

describe("plan repair", () => {
  it("covers every passage in order, whatever ranges were planned", () => {
    const fixed = normalizeAudiobookPlan(plan([{ firstPassage: 3, lastPassage: 4 }, { firstPassage: 1, lastPassage: 1 }]), Array.from({ length: 6 }, () => passage(300)), 1);
    expect(fixed.chapters.map(chapter => [chapter.firstPassage, chapter.lastPassage])).toEqual([[0, 2], [3, 5]]);
  });

  it("splits a chapter too long to mix in one go into parts, sharing its scenes", () => {
    const scenes = [0, 1, 2, 3].map(index => ({ prompt: `Scene ${index}`, motion: "zoom-in" as const }));
    const passages = Array.from({ length: 20 }, () => passage(3500));
    const fixed = normalizeAudiobookPlan(plan([{ lastPassage: 19, scenes, music: ["m1", "m2", "m3"] }]), passages, 1);
    expect(fixed.chapters.length).toBeGreaterThan(1);
    expect(fixed.chapters[0].title).toContain("(1/");
    expect(fixed.chapters.flatMap(chapter => chapter.scenes)).toHaveLength(4);
    expect(fixed.chapters.at(-1)!.lastPassage).toBe(19);
    for (const chapter of fixed.chapters) {
      const seconds = passages.slice(chapter.firstPassage, chapter.lastPassage + 1).reduce((sum, item) => sum + narrationSeconds(item.text), 0);
      expect(seconds).toBeLessThanOrEqual(MAX_AUDIOBOOK_CHAPTER_SECONDS * 1.1);
    }
  });

  it("never leaves one piece of music on a long stretch or across a chapter change", () => {
    const passages = Array.from({ length: 8 }, () => passage(3500));
    const fixed = normalizeAudiobookPlan(plan([{ lastPassage: 3, music: ["m1"] }, { firstPassage: 4, lastPassage: 7, music: ["m1"] }]), passages, 1);
    for (const [index, chapter] of fixed.chapters.entries()) {
      // Four passages run about 16 minutes before splitting and each part's stretches stay near five minutes.
      expect(chapter.music.length).toBeGreaterThanOrEqual(1);
      if (index) expect(chapter.music[0]).not.toBe(fixed.chapters[index - 1].music.at(-1));
      chapter.music.forEach((cue, position) => { if (position) expect(cue).not.toBe(chapter.music[position - 1]); });
    }
    expect(new Set(fixed.chapters.flatMap(chapter => chapter.music)).size).toBeGreaterThan(1);
  });

  it("requires at least two cues in the schema", () => {
    expect(audiobookPlanSchema.safeParse(plan([{}], ["m1"])).success).toBe(false);
  });
});

describe("assignStretches", () => {
  const turn = (music: string, scene = 0) => ({ caption: "x".repeat(100), music, scene });
  it("keeps the writer's cues when all were used, moving forward only", () => {
    const out = assignStretches([turn("m1"), turn("m2"), turn("m1"), turn("m3")], ["m1", "m2", "m3"], 0);
    expect(out.map(item => item.music)).toEqual(["m1", "m2", "m2", "m3"]);
  });
  it("spreads planned cues evenly when the writer stayed on one", () => {
    const out = assignStretches([turn("m1"), turn("m1"), turn("m1"), turn("m1")], ["m1", "m2"], 0);
    expect(out.map(item => item.music)).toEqual(["m1", "m1", "m2", "m2"]);
  });
  it("keeps scenes moving forward and in range", () => {
    const out = assignStretches([turn("m1", 2), turn("m1", 0), turn("m1", 9)], ["m1"], 3);
    expect(out.map(item => item.scene)).toEqual([2, 2, 2]);
  });
});
