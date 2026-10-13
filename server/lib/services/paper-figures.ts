import { createHash } from "node:crypto";
import { and, eq } from "drizzle-orm";
import { z } from "zod";
import type { PaperDocument, PaperFile } from "@/lib/contracts/paper";
import type { Database } from "@/lib/db/client";
import { documentVersions } from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import type { ObjectStore } from "@/lib/storage/r2";
import { compilePaperDocument, findPaperForViewer } from "./papers";
import { resolveDeps } from "./summaries";

/**
 * One figure of a paper drawn on its own, for the app's native reader: a `tikzpicture`,
 * `axis` (pgfplots) or similar environment the reader can't draw itself is compiled as a
 * `standalone` document with the paper's preamble (its packages, TikZ libraries, pgfplots
 * settings and macros), and the PDF comes back cropped to the drawing. Results are kept in
 * storage by the figure's hash, so a figure is compiled once per source.
 */

export const MAX_FIGURE_SOURCE_CHARS = 100_000;
const MAIN = "__figure__.tex";

export const renderFigureSchema = z.object({
  /** The environment as it appears in the paper, `\begin{tikzpicture}…\end{tikzpicture}`. */
  source: z.string().trim().min(1).max(MAX_FIGURE_SOURCE_CHARS).refine((source) => /\\begin\{/.test(source), { message: "Pass a LaTeX environment" }),
  version: z.number().int().positive().optional(),
});
export type RenderFigureInput = z.infer<typeof renderFigureSchema>;

/** Preamble commands the figure needs; anything else in the preamble (geometry, titles) stays out. */
const PREAMBLE_COMMANDS = [
  "usepackage", "RequirePackage", "usetikzlibrary", "usepgfplotslibrary", "pgfplotsset", "tikzset", "tikzstyle", "pgfmathsetmacro",
  "newcommand", "renewcommand", "providecommand", "DeclareMathOperator", "def", "newcolumntype", "definecolor", "colorlet",
  "newlength", "setlength", "usetikztimingtable", "pgfkeys", "pgfdeclarelayer", "pgfsetlayers", "newif", "newcounter",
];

function balanced(text: string, from: number): number {
  // The end of the command: its star, optional arguments and balanced brace groups.
  let pos = from;
  while (pos < text.length && text[pos] === "*") pos += 1;
  for (;;) {
    while (pos < text.length && /[ \t]/.test(text[pos])) pos += 1;
    const open = text[pos];
    if (open === "[") {
      const close = text.indexOf("]", pos);
      if (close < 0) return text.length;
      pos = close + 1;
    } else if (open === "{") {
      let depth = 0;
      for (; pos < text.length; pos += 1) {
        if (text[pos] === "\\") { pos += 1; continue; }
        if (text[pos] === "{") depth += 1;
        if (text[pos] === "}") { depth -= 1; if (depth === 0) { pos += 1; break; } }
      }
    } else {
      return pos;
    }
  }
}

/** The preamble commands of `main` a figure relies on, in order. */
export function figurePreamble(main: string): string {
  const start = main.indexOf("\\begin{document}");
  const preamble = (start >= 0 ? main.slice(0, start) : main).replace(/(^|[^\\])%.*$/gm, "$1");
  const commands: string[] = [];
  const pattern = new RegExp(`\\\\(${PREAMBLE_COMMANDS.join("|")})(?![A-Za-z@])`, "g");
  for (let match = pattern.exec(preamble); match; match = pattern.exec(preamble)) {
    const end = balanced(preamble, match.index + match[0].length);
    const command = preamble.slice(match.index, end).trim();
    if (match[1] === "def") {
      // `\def\name{…}`: the name follows the command, then the body.
      const named = /^\\def\\[A-Za-z@]+/.exec(preamble.slice(match.index));
      if (named) { const bodyEnd = balanced(preamble, match.index + named[0].length); commands.push(preamble.slice(match.index, bodyEnd).trim()); pattern.lastIndex = bodyEnd; continue; }
    }
    if (command.startsWith("\\usepackage") && /\{\s*(?:geometry|fullpage|fancyhdr|titlesec|titling|abstract|authblk|standalone|float|caption|subcaption|setspace|hyperref|cleveref|biblatex|natbib|lineno)\s*\}/.test(command)) continue;
    commands.push(command);
    pattern.lastIndex = end;
  }
  return commands.join("\n");
}

/** The standalone document that draws `source` with `main`'s preamble. */
export function figureDocument(source: string, main: string): string {
  const preamble = figurePreamble(main);
  const extra: string[] = [];
  if (/\\begin\{axis|\\begin\{semilog|\\begin\{loglog|\\addplot/.test(source) && !/\{pgfplots\}/.test(preamble)) extra.push("\\usepackage{pgfplots}\n\\pgfplotsset{compat=newest}");
  if (!/\{tikz\}|\{pgfplots\}|\{circuitikz\}|\{tikz-cd\}|\{forest\}/.test(preamble) && !extra.length) extra.push("\\usepackage{tikz}");
  if (/\\begin\{tikzcd\}/.test(source) && !/\{tikz-cd\}/.test(preamble)) extra.push("\\usepackage{tikz-cd}");
  if (/\\begin\{circuitikz\}/.test(source) && !/\{circuitikz\}/.test(preamble)) extra.push("\\usepackage{circuitikz}");
  if (/\\begin\{forest\}/.test(source) && !/\{forest\}/.test(preamble)) extra.push("\\usepackage{forest}");
  if (!/\{amsmath\}/.test(preamble)) extra.push("\\usepackage{amsmath,amssymb}");
  return [
    "\\documentclass[border=6pt]{standalone}",
    preamble,
    ...extra,
    "\\begin{document}",
    source,
    "\\end{document}",
    "",
  ].filter((line) => line !== "").join("\n");
}

function figureKey(paperId: string, hash: string): string {
  return `papers/${paperId}/figures/${hash}.pdf`;
}

/**
 * Compiles one figure of the paper (the working copy, or a saved version for the owner) and
 * returns its PDF. A figure that doesn't compile is `422 LATEX_COMPILE_FAILED` with the errors.
 */
export async function renderPaperFigure(db: Database, id: string, viewerId: string, input: RenderFigureInput, store?: ObjectStore): Promise<{ bytes: Uint8Array; cached: boolean }> {
  const found = await findPaperForViewer(db, id, viewerId);
  if (!found) throw new ApiError(404, "NOT_FOUND", "The paper does not exist");
  const objects = store ?? (await resolveDeps()).store;
  let document: PaperDocument = { title: found.summary.title, files: found.paper.files, mainFile: found.paper.mainFile, compiler: found.paper.compiler };
  if (input.version !== undefined) {
    if (found.summary.ownerId !== viewerId) throw new ApiError(404, "NOT_FOUND", "The paper does not exist");
    const [row] = await db.select().from(documentVersions).where(and(eq(documentVersions.summaryId, id), eq(documentVersions.version, input.version))).limit(1);
    if (!row) throw new ApiError(404, "VERSION_NOT_FOUND", "The paper version does not exist");
    document = row.content as unknown as PaperDocument;
  }
  const main = document.files.find((file) => file.path === document.mainFile)?.content ?? "";
  const standalone = figureDocument(input.source, main);
  const files: PaperFile[] = [
    { path: MAIN, content: standalone },
    // Everything the figure may `\input`, read data from or include; the paper's own main file stays out.
    ...document.files.filter((file) => file.path !== document.mainFile),
  ];
  const hash = createHash("sha256").update(document.compiler).update("\n").update(standalone)
    .update("\n").update(files.map((file) => file.asset?.key ?? `${file.path}:${file.content.length}:${createHash("sha256").update(file.content).digest("hex")}`).join("\n"))
    .digest("hex");
  const key = figureKey(id, hash);
  const cached = await objects.get(key).catch(() => null);
  if (cached) return { bytes: cached.bytes, cached: true };
  const result = await compilePaperDocument({ ...document, files, mainFile: MAIN }, false, id, objects);
  if (!result.ok) {
    const errors = result.errors.map((issue) => ({ ...issue, file: issue.file === MAIN ? null : issue.file }));
    const first = errors[0];
    throw new ApiError(422, "LATEX_COMPILE_FAILED", `LaTeX could not draw the figure: ${first?.message ?? "no PDF was produced"}`, { errors, log: result.log });
  }
  await objects.put(key, { bytes: result.pdf, contentType: "application/pdf", cacheControl: "private, max-age=0" }).catch(() => undefined);
  return { bytes: result.pdf, cached: false };
}
