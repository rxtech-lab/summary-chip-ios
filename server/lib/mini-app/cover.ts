import { eq } from "drizzle-orm";
import type { AiProvider } from "@/lib/ai/provider";
import { normalizeDraft } from "@/lib/ai/summary-schema";
import type { MiniAppDocument } from "@/lib/contracts/mini-app";
import type { Database } from "@/lib/db/client";
import { miniApps, type SummaryRow } from "@/lib/db/schema";

/** Words describing what the app does, for the cover model: its table, screen and button titles. */
export function miniAppKeywords(document: MiniAppDocument): string[] {
  const titles = Object.values(document.ui.elements).map(node => node.props.title).filter((value): value is string => typeof value === "string" && value.trim() !== "");
  return [...new Set([...Object.keys(document.tables), ...titles])].slice(0, 10);
}

/** The model designs the cover theme and headline for an app, like it does for trips and papers. */
export async function designMiniAppCover(ai: AiProvider, id: string, document: MiniAppDocument) {
  const summary = document.description || "Interactive Mini App";
  const keywords = miniAppKeywords(document);
  const language = await ai.detectLanguage({ title: document.title, summary, highlights: [] }) ?? "en";
  const design = await ai.designCover({ title: document.title, summary, category: "Technology", keywords, text: summary, language });
  const draft = normalizeDraft({ title: document.title, summary, highlights: [], category: "Technology", tags: [], keywords, language, design: design ?? { colors: [], mode: undefined as unknown as "light", emoji: "", accent: "", headline: "" } }, { requestedLanguage: "auto", seed: id });
  return { ...draft, title: document.title, summary };
}

/**
 * Apps saved before covers were designed carry a placeholder theme and no headline or keywords:
 * design them from the app's current definition before drawing. Null for apps that already have one.
 */
export async function redesignMiniAppCover(db: Database, ai: AiProvider, row: SummaryRow): Promise<Pick<SummaryRow, "theme" | "ogHeadline" | "language" | "keywords"> | null> {
  if (row.kind !== "mini_app" || row.ogHeadline) return null;
  const [app] = await db.select({ document: miniApps.document }).from(miniApps).where(eq(miniApps.summaryId, row.id));
  if (!app) return null;
  const draft = await designMiniAppCover(ai, row.id, app.document);
  return { theme: draft.theme, ogHeadline: draft.headline, language: draft.language, keywords: draft.keywords };
}
