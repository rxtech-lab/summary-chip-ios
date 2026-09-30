import { z } from "zod";
import { CATEGORIES, type Category, type OutputLanguage } from "@/lib/contracts/api";
import type { SummaryTheme } from "@/lib/db/schema";

/**
 * The schema the model fills in. Kept deliberately loose (no min/max/pattern keywords, which some
 * providers reject in strict structured-output mode); `normalizeDraft` enforces the real limits.
 */
export const llmSummarySchema = z.object({
  title: z.string().describe("Concise, informative title for the content (max ~90 characters)."),
  summary: z.string().describe("2-4 sentence summary of the content."),
  highlights: z.array(z.string()).describe("3-5 key takeaways, each one short sentence."),
  category: z.enum(CATEGORIES).describe("The single best category."),
  tags: z.array(z.string()).describe("3-6 short lowercase topical tags (1-3 words each)."),
  keywords: z.array(z.string()).describe("5-10 search keywords or named entities."),
  language: z.string().describe("BCP-47 code of the language the title/summary are written in, e.g. en, zh-Hans, ja."),
  design: z.object({
    colors: z.array(z.string()).describe("4-6 harmonious hex colors (#rrggbb) for a gradient background that evokes the topic."),
    mode: z.enum(["light", "dark"]).describe("Whether the palette is light (dark text) or dark (light text)."),
    emoji: z.string().describe("One emoji that represents the content."),
    accent: z.string().describe("A hex accent color (#rrggbb) that contrasts with the palette."),
    headline: z.string().describe("Punchy headline for a social preview image, at most 70 characters, same language as the summary."),
  }),
});
export type LlmSummary = z.infer<typeof llmSummarySchema>;

export interface SummaryDraft {
  title: string;
  summary: string;
  highlights: string[];
  category: Category;
  tags: string[];
  keywords: string[];
  language: string;
  theme: SummaryTheme;
  headline: string;
}

const HEX = /^#[0-9a-f]{6}$/i;
const FALLBACK_PALETTES: string[][] = [
  ["#0f172a", "#1e3a8a", "#2563eb", "#38bdf8", "#e0f2fe"],
  ["#fff7ed", "#fed7aa", "#fb923c", "#ea580c", "#7c2d12"],
  ["#f0fdf4", "#bbf7d0", "#4ade80", "#16a34a", "#14532d"],
  ["#1e1b4b", "#4c1d95", "#7c3aed", "#c084fc", "#f5d0fe"],
];

function expandHex(value: string): string | null {
  const trimmed = value.trim();
  if (HEX.test(trimmed)) return trimmed.toLowerCase();
  const short = /^#?([0-9a-f])([0-9a-f])([0-9a-f])$/i.exec(trimmed);
  if (short) return `#${short[1]}${short[1]}${short[2]}${short[2]}${short[3]}${short[3]}`.toLowerCase();
  const bare = /^([0-9a-f]{6})$/i.exec(trimmed);
  return bare ? `#${bare[1].toLowerCase()}` : null;
}

export function hashString(value: string): number {
  let hash = 2166136261;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 16777619);
  }
  return hash >>> 0;
}

export function luminance(hex: string): number {
  const value = parseInt(hex.slice(1), 16);
  const channel = (shift: number) => {
    const c = ((value >> shift) & 255) / 255;
    return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0);
}

function cleanList(values: string[], max: number, transform = (value: string) => value): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const raw of values) {
    const value = transform(raw.replace(/\s+/g, " ").trim());
    if (!value || seen.has(value.toLowerCase())) continue;
    seen.add(value.toLowerCase());
    out.push(value);
    if (out.length === max) break;
  }
  return out;
}

function clip(value: string, max: number): string {
  const trimmed = value.replace(/\s+/g, " ").trim();
  return trimmed.length <= max ? trimmed : `${trimmed.slice(0, max - 1).trimEnd()}…`;
}

function firstGrapheme(value: string): string | null {
  const segmenter = new Intl.Segmenter(undefined, { granularity: "grapheme" });
  for (const { segment } of segmenter.segment(value.trim())) {
    return /\p{Extended_Pictographic}|\p{Regional_Indicator}/u.test(segment) ? segment : null;
  }
  return null;
}

/** Enforces every limit from the contract on whatever the model returned. */
export function normalizeDraft(raw: LlmSummary, options: { requestedLanguage: OutputLanguage; seed: string; fallbackTitle?: string | null }): SummaryDraft {
  const colors = cleanList(raw.design.colors, 6).map(expandHex).filter((value): value is string => value !== null);
  const palette = colors.length >= 4 ? colors.slice(0, 6) : FALLBACK_PALETTES[hashString(options.seed) % FALLBACK_PALETTES.length];
  const average = palette.reduce((total, color) => total + luminance(color), 0) / palette.length;
  const mode: "light" | "dark" = raw.design.mode === "dark" || raw.design.mode === "light"
    ? raw.design.mode
    : average < 0.35 ? "dark" : "light";
  const accent = expandHex(raw.design.accent) ?? palette[Math.min(2, palette.length - 1)];
  const title = clip(raw.title || options.fallbackTitle || "Untitled", 120);
  const tags = cleanList(raw.tags, 6, (value) => value.toLowerCase().replace(/^#/, "").slice(0, 40));
  return {
    title,
    summary: clip(raw.summary, 1200),
    highlights: cleanList(raw.highlights, 5, (value) => clip(value, 300)),
    category: (CATEGORIES as readonly string[]).includes(raw.category) ? raw.category : "Other",
    tags,
    keywords: cleanList(raw.keywords, 10, (value) => value.slice(0, 60)),
    language: options.requestedLanguage === "auto" ? (raw.language?.trim().slice(0, 35) || "en") : options.requestedLanguage,
    theme: { colors: palette, mode, emoji: firstGrapheme(raw.design.emoji) ?? "📰", accent },
    headline: clip(raw.design.headline || title, 70),
  };
}

export const LANGUAGE_NAMES: Record<Exclude<OutputLanguage, "auto">, string> = {
  en: "English",
  "zh-Hans": "Simplified Chinese",
  "zh-Hant": "Traditional Chinese",
  ja: "Japanese",
  ko: "Korean",
  es: "Spanish",
  fr: "French",
  de: "German",
};
