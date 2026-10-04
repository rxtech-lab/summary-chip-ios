import { randomInt } from "node:crypto";
import { desc, eq } from "drizzle-orm";
import type { Database } from "@/lib/db/client";
import { summaries, type SummaryTheme } from "@/lib/db/schema";

type CoverPalette = Pick<SummaryTheme, "colors" | "mode" | "accent">;

/** Distinct color families, independent of the article's category or the model's defaults. */
export const COVER_PALETTES: readonly CoverPalette[] = [
  { colors: ["#431407", "#7c2d12", "#c2410c", "#fb923c", "#ffedd5"], mode: "dark", accent: "#fdba74" },
  { colors: ["#fffbeb", "#fef3c7", "#fcd34d", "#d97706", "#78350f"], mode: "light", accent: "#92400e" },
  { colors: ["#f7fee7", "#ecfccb", "#bef264", "#65a30d", "#365314"], mode: "light", accent: "#3f6212" },
  { colors: ["#052e16", "#14532d", "#15803d", "#4ade80", "#dcfce7"], mode: "dark", accent: "#86efac" },
  { colors: ["#172554", "#1e40af", "#2563eb", "#93c5fd", "#eff6ff"], mode: "dark", accent: "#bfdbfe" },
  { colors: ["#2e1065", "#5b21b6", "#8b5cf6", "#c4b5fd", "#f5f3ff"], mode: "dark", accent: "#ddd6fe" },
  { colors: ["#fff1f2", "#ffe4e6", "#fda4af", "#e11d48", "#881337"], mode: "light", accent: "#9f1239" },
  { colors: ["#4a044e", "#86198f", "#c026d3", "#e879f9", "#fae8ff"], mode: "dark", accent: "#f0abfc" },
];

/** Keep a library's last five palettes out of the next random draw. */
export const RECENT_COVER_PALETTE_COUNT = 5;

function paletteKey(colors: string[]): string {
  return colors.map((color) => color.toLowerCase()).join(",");
}

export function randomCoverTheme(theme: SummaryTheme, recent: SummaryTheme[]): SummaryTheme {
  // Also exclude this chip's old palette when regenerating an older cover.
  const excluded = new Set([theme, ...recent.slice(0, RECENT_COVER_PALETTE_COUNT)].map((item) => paletteKey(item.colors)));
  const available = COVER_PALETTES.filter((palette) => !excluded.has(paletteKey(palette.colors)));
  const palette = available[randomInt(available.length)];
  return { ...theme, ...palette, colors: [...palette.colors] };
}

/** The persisted theme is the palette history; all clients read the same stored colors. */
export async function selectCoverTheme(db: Database, ownerId: string, theme: SummaryTheme): Promise<SummaryTheme> {
  const recent = await db.select({ theme: summaries.theme }).from(summaries)
    .where(eq(summaries.ownerId, ownerId))
    .orderBy(desc(summaries.updatedAt), desc(summaries.id))
    .limit(RECENT_COVER_PALETTE_COUNT);
  return randomCoverTheme(theme, recent.map((row) => row.theme));
}
