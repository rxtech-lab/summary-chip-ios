import type { LanguageModelUsage } from "ai";
import { and, eq, isNull, lt, or } from "drizzle-orm";
import { getAiProvider, type AiProvider } from "@/lib/ai/provider";
import { TRANSLATION_LANGUAGES, type TranslationLanguage } from "@/lib/contracts/api";
import type { PaperDocument } from "@/lib/contracts/paper";
import type { Database } from "@/lib/db/client";
import { papers, paperTranslations, summaries, type PaperRow, type SummaryRow } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { mapPaperTexts, paperTexts } from "@/lib/latex/paper-texts";
import { getOwnedPaper } from "./papers";
import { holdTranslation, settleTranslation, translationLanguageFor, type TranslationPayer } from "./translations";

const STALE_MS = 10 * 60_000;

export function paperDocument(summary: SummaryRow, paper: PaperRow): PaperDocument {
  return { title: summary.title, files: paper.files, mainFile: paper.mainFile, compiler: paper.compiler };
}

function targetLanguage(summary: SummaryRow, viewerId: string | null, language?: string | null): TranslationLanguage | null {
  const wanted = language === undefined ? (viewerId === summary.ownerId ? summary.displayLanguage : null) : language;
  if (wanted === null || wanted === "original") return null;
  const target = translationLanguageFor(wanted);
  if (!target) throw new ApiError(400, "VALIDATION_ERROR", "Unsupported paper language");
  return target === translationLanguageFor(summary.language) ? null : target;
}

async function savedTranslation(db: Database, id: string, language: TranslationLanguage) {
  const [row] = await db.select().from(paperTranslations)
    .where(and(eq(paperTranslations.summaryId, id), eq(paperTranslations.language, language))).limit(1);
  return row;
}

/** Read saved prose only; reading and exporting never start a paid translation implicitly. */
export async function readPaperDocument(
  db: Database, summary: SummaryRow, paper: PaperRow, viewerId: string | null,
  options: { language?: string | null; document?: PaperDocument; required?: boolean } = {},
) {
  const original = options.document ?? paperDocument(summary, paper);
  const language = targetLanguage(summary, viewerId, options.language);
  if (!language) return { document: original, language: summary.language, outdated: false, translated: false };
  const saved = await savedTranslation(db, summary.id, language);
  const complete = saved && paperTexts(original).every((text) => Object.hasOwn(saved.strings, text));
  const outdated = !complete || (!options.document && saved?.revision !== paper.revision);
  if (options.required && outdated) throw new ApiError(409, "PAPER_TRANSLATION_OUTDATED", "Translate or update this language before exporting the paper.");
  return {
    document: mapPaperTexts(original, (text) => saved?.strings[text] ?? text),
    language, outdated, translated: true,
  };
}

export async function listPaperTranslations(db: Database, summary: SummaryRow, paper: PaperRow) {
  const rows = await db.select().from(paperTranslations).where(eq(paperTranslations.summaryId, summary.id));
  return {
    originalLanguage: summary.language,
    items: rows.sort((a, b) => TRANSLATION_LANGUAGES.indexOf(a.language as TranslationLanguage) - TRANSLATION_LANGUAGES.indexOf(b.language as TranslationLanguage))
      .map((row) => ({ language: row.language, upToDate: row.revision === paper.revision, translating: Boolean(row.translatingSince && Date.now() - row.translatingSince.getTime() < STALE_MS) })),
  };
}

/** Translate only new/changed prose, keeping every LaTeX token and all assets in the original. */
export async function translatePaper(
  db: Database, id: string, ownerId: string, requested: TranslationLanguage | null,
  payer: TranslationPayer, options: { ai?: AiProvider } = {},
): Promise<void> {
  const { summary, paper } = await getOwnedPaper(db, id, ownerId);
  const language = targetLanguage(summary, ownerId, requested);
  if (language) await translateMissing(db, summary, paper, language, payer, options.ai);
  // A translation written while the source changed must not become the selected reading.
  const [current] = await db.select().from(papers).where(eq(papers.summaryId, id)).limit(1);
  if (current?.revision !== paper.revision) throw new ApiError(409, "PAPER_TRANSLATION_OUTDATED", "The paper changed while translating. Update the translation and try again.");
  await db.update(summaries).set({ displayLanguage: language }).where(eq(summaries.id, id));
}

async function translateMissing(db: Database, summary: SummaryRow, paper: PaperRow, language: TranslationLanguage, payer: TranslationPayer, provider?: AiProvider) {
  const texts = paperTexts(paperDocument(summary, paper));
  const saved = await savedTranslation(db, summary.id, language);
  const strings = Object.fromEntries(Object.entries(saved?.strings ?? {}).filter(([text]) => texts.includes(text)));
  const missing = texts.filter((text) => !Object.hasOwn(strings, text));
  if (missing.length === 0) {
    await db.update(paperTranslations).set({ revision: paper.revision, updatedAt: new Date() })
      .where(and(eq(paperTranslations.summaryId, summary.id), eq(paperTranslations.language, language)));
    return;
  }
  const now = new Date();
  const where = and(eq(paperTranslations.summaryId, summary.id), eq(paperTranslations.language, language));
  await db.insert(paperTranslations).values({ summaryId: summary.id, language, strings: {}, revision: -1 }).onConflictDoNothing();
  const claimed = await db.update(paperTranslations).set({ translatingSince: now })
    .where(and(where, or(isNull(paperTranslations.translatingSince), lt(paperTranslations.translatingSince, new Date(now.getTime() - STALE_MS)))))
    .returning({ language: paperTranslations.language });
  if (!claimed.length) throw new ApiError(409, "PAPER_TRANSLATING", "This paper is already being translated into this language. Try again shortly.");
  const steps: LanguageModelUsage[] = [];
  let delivered = false;
  try {
    const ai = provider ?? await getAiProvider();
    const charge = await holdTranslation(ai, payer, `${summary.id}:${language}:paper:${paper.revision}`, { summaryId: summary.id, language, part: "paper", texts: missing.length });
    try {
      const output = await ai.translateStrings(missing, language, { timeoutMs: 240_000, onUsage: (usage) => steps.push(usage) });
      if (output?.length === missing.length) output.forEach((text, index) => { if (text?.trim()) strings[missing[index]] = text.trim(); });
      delivered = missing.some((text) => Object.hasOwn(strings, text));
      const complete = texts.every((text) => Object.hasOwn(strings, text));
      await db.update(paperTranslations).set({ strings, revision: complete ? paper.revision : -1, updatedAt: new Date() }).where(and(where, eq(paperTranslations.translatingSince, now)));
      if (!complete) throw new ApiError(502, "PAPER_TRANSLATION_FAILED", "The paper could not be fully translated. Try again to finish the missing text.");
    } finally {
      await settleTranslation(charge, ai, delivered, steps, { part: "paper" });
    }
  } finally {
    await db.update(paperTranslations).set({ translatingSince: null }).where(and(where, eq(paperTranslations.translatingSince, now)));
  }
}
