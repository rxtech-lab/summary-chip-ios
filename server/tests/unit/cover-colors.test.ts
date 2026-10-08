import { describe, expect, it } from "vitest";
import type { SummaryTheme } from "@/lib/db/schema";
import { illustrationInstruction } from "@/lib/ai/provider";
import { COVER_PALETTES, randomCoverTheme, RECENT_COVER_PALETTE_COUNT } from "@/lib/services/cover-colors";

const legacy: SummaryTheme = { colors: ["#0f172a", "#1d4ed8", "#38bdf8", "#e0f2fe"], mode: "dark", emoji: "📰", accent: "#f59e0b" };

describe("cover colors", () => {
  it("continues to vary colors after the first palette cycle", () => {
    const recent: SummaryTheme[] = [];
    for (let index = 0; index < 32; index += 1) {
      const theme = randomCoverTheme(legacy, recent);
      expect(recent.slice(0, RECENT_COVER_PALETTE_COUNT).map((item) => item.colors)).not.toContainEqual(theme.colors);
      expect(COVER_PALETTES).toContainEqual({ colors: theme.colors, mode: theme.mode, accent: theme.accent });
      expect(theme.emoji).toBe(legacy.emoji);
      recent.unshift(theme);
    }
  });

  it("excludes an older chip's own color when regenerating without mutating it", () => {
    const theme = { ...COVER_PALETTES[0], emoji: "🦋" };
    const before = structuredClone(theme);
    const recent = COVER_PALETTES.slice(1, 6).map((palette) => ({ ...palette, emoji: "📰" }));
    for (let index = 0; index < 20; index += 1) {
      const next = randomCoverTheme(theme, recent);
      expect([theme, ...recent].map((item) => item.colors)).not.toContainEqual(next.colors);
      expect(next.emoji).toBe("🦋");
    }
    expect(theme).toEqual(before);
  });

  it("tells the image model to use the assigned colors as the dominant palette", () => {
    const prompt = illustrationInstruction({
      title: "Data breach", headline: "Data breach", summary: "Security news", category: "Technology",
      keywords: ["security"], colors: [...COVER_PALETTES[0].colors], mode: "dark",
    });
    expect(prompt).toContain(COVER_PALETTES[0].colors.join(", "));
    expect(prompt).toContain("Make its colors dominant across the background and subject");
  });

  it("draws trips as a text-free travel-diary page", () => {
    const prompt = illustrationInstruction({
      title: "Northbound Japan", headline: "Northbound Japan", summary: "Ten days north", category: "Travel",
      keywords: ["Chiba", "Hakodate"], colors: [...COVER_PALETTES[0].colors], mode: "light", kind: "trip",
    });
    expect(prompt).toContain("travel diary");
    expect(prompt).toContain("Chiba, Hakodate");
    expect(prompt).toContain("NO text of any kind");
    expect(prompt).not.toContain("editorial illustration");
  });

  it("draws papers as a text-free research-notebook page", () => {
    const prompt = illustrationInstruction({
      title: "Sparse attention", headline: "Sparse attention", summary: "Faster transformers", category: "Research",
      keywords: ["transformers", "sparsity"], colors: [...COVER_PALETTES[0].colors], mode: "light", kind: "paper",
    });
    expect(prompt).toContain("research notebook");
    expect(prompt).toContain("transformers, sparsity");
    expect(prompt).toContain("NO text of any kind");
    expect(prompt).not.toContain("editorial illustration");
  });
});
