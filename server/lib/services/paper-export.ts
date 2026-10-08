import { and, eq } from "drizzle-orm";
import type { PaperExportFormat, PaperDocument } from "@/lib/contracts/paper";
import type { Database } from "@/lib/db/client";
import { documentVersions } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import { DOCX_MIME, paperWord } from "@/lib/latex/word";
import { paperAssetBytes } from "./paper-assets";
import { readPaperDocument } from "./paper-translations";
import { compilePaperDocument, findPaperForViewer, paperFilename, paperPdf } from "./papers";
import { resolveDeps } from "./summaries";
import { translatedPdfProject } from "@/lib/latex/translated-pdf";
import { paperRenderingSchema, type PaperRendering } from "@/lib/contracts/paper-rendering";
import { renderLatex } from "@/lib/latex/rendering";

export async function exportPaper(
  db: Database, id: string, viewerId: string,
  options: { format: PaperExportFormat; language?: string | null; version?: number; rendering?: Partial<PaperRendering> },
) {
  const found = await findPaperForViewer(db, id, viewerId);
  if (!found) throw new ApiError(404, "NOT_FOUND", "The paper does not exist");
  let document: PaperDocument | undefined;
  if (options.version !== undefined) {
    if (found.summary.ownerId !== viewerId) throw new ApiError(404, "NOT_FOUND", "The paper does not exist");
    const [version] = await db.select().from(documentVersions).where(and(eq(documentVersions.summaryId, id), eq(documentVersions.version, options.version))).limit(1);
    if (!version) throw new ApiError(404, "VERSION_NOT_FOUND", "The paper version does not exist");
    document = version.content as unknown as PaperDocument;
  }
  const reading = await readPaperDocument(db, found.summary, found.paper, viewerId, { language: options.language, document, required: true });
  const revision = options.version === undefined ? found.paper.revision : null;
  const style = paperRenderingSchema.parse(options.rendering ?? found.paper.renderingOptions);
  if (options.format === "pdf" && !reading.translated && !options.rendering) {
    return { ...await paperPdf(db, id, viewerId, { version: options.version }), contentType: "application/pdf", language: reading.language };
  }
  const { store } = await resolveDeps();
  if (options.format === "pdf") {
    const project = reading.translated ? translatedPdfProject(reading.document, reading.language) : reading.document;
    const result = await compilePaperDocument(renderLatex(project, style), false, id, store);
    if (!result.ok) throw new ApiError(422, "LATEX_COMPILE_FAILED", "The paper could not compile. Check its LaTeX, rendering options and language fonts.", { errors: result.errors, log: result.log });
    return { bytes: result.pdf, filename: paperFilename(reading.document.title), revision, contentType: "application/pdf", language: reading.language };
  }
  const assetData: Record<string, Uint8Array> = {};
  await Promise.all(reading.document.files.map(async (file) => {
    if (file.asset) assetData[file.path] = (await paperAssetBytes(store, id, file)).bytes;
  }));
  const bytes = await paperWord({ ...reading.document, language: reading.language, assetData }, style);
  return { bytes, filename: paperFilename(reading.document.title).replace(/\.pdf$/, ".docx"), revision, contentType: DOCX_MIME, language: reading.language };
}
