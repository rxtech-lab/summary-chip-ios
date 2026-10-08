import { createHash } from "node:crypto";
import { paperDocumentSchema, type PaperCompiler, type PaperDocument, type PaperFile, type PaperOperation } from "@/lib/contracts/paper";
import { ApiError } from "@/lib/http/errors";

/* ------------------------------------------------------------------------------------------------
 * Starting projects
 * ---------------------------------------------------------------------------------------------- */

export type PaperTemplate = "article" | "report" | "blank";

const ARTICLE_MAIN = String.raw`\documentclass[11pt]{article}

\usepackage[utf8]{inputenc}
\usepackage[T1]{fontenc}
\usepackage{lmodern}
\usepackage[margin=1in]{geometry}
\usepackage{amsmath,amssymb}
\usepackage{graphicx}
\usepackage{booktabs}
\usepackage[hidelinks]{hyperref}

\title{TITLE}
\author{Author Name}
\date{\today}

\begin{document}

\maketitle

\begin{abstract}
A short summary of the problem, the approach and the main results.
\end{abstract}

\input{sections/introduction}

\bibliographystyle{plain}
\bibliography{references}

\end{document}
`;

const ARTICLE_INTRODUCTION = String.raw`\section{Introduction}
\label{sec:introduction}

State the problem and why it matters. Prior work such as \cite{knuth1984} is discussed here.

\begin{equation}
  E = mc^2
  \label{eq:energy}
\end{equation}
`;

const REFERENCES = String.raw`@book{knuth1984,
  author    = {Donald E. Knuth},
  title     = {The {\TeX}book},
  publisher = {Addison-Wesley},
  year      = {1984}
}
`;

const REPORT_MAIN = String.raw`\documentclass[11pt]{report}

\usepackage[utf8]{inputenc}
\usepackage[T1]{fontenc}
\usepackage{lmodern}
\usepackage[margin=1in]{geometry}
\usepackage{amsmath,amssymb}
\usepackage[hidelinks]{hyperref}

\title{TITLE}
\author{Author Name}
\date{\today}

\begin{document}

\maketitle
\tableofcontents

\include{chapters/introduction}

\bibliographystyle{plain}
\bibliography{references}

\end{document}
`;

const REPORT_INTRODUCTION = String.raw`\chapter{Introduction}

The first chapter. Cite sources such as \cite{knuth1984}.
`;

const BLANK_MAIN = String.raw`\documentclass{article}

\title{TITLE}

\begin{document}

\maketitle

\end{document}
`;

/** Braces and backslashes would break the template's `\title{…}`. */
function titleForTex(title: string): string {
  return title.replace(/[\\{}]/g, "").replace(/([#$%&_^~])/g, "\\$1");
}

export function templateFiles(template: PaperTemplate, title: string): { files: PaperFile[]; mainFile: string } {
  const main = (source: string) => source.replace("TITLE", titleForTex(title));
  switch (template) {
    case "report":
      return {
        mainFile: "main.tex",
        files: [
          { path: "main.tex", content: main(REPORT_MAIN) },
          { path: "chapters/introduction.tex", content: REPORT_INTRODUCTION },
          { path: "references.bib", content: REFERENCES },
        ],
      };
    case "blank":
      return { mainFile: "main.tex", files: [{ path: "main.tex", content: main(BLANK_MAIN) }] };
    default:
      return {
        mainFile: "main.tex",
        files: [
          { path: "main.tex", content: main(ARTICLE_MAIN) },
          { path: "sections/introduction.tex", content: ARTICLE_INTRODUCTION },
          { path: "references.bib", content: REFERENCES },
        ],
      };
  }
}

/* ------------------------------------------------------------------------------------------------
 * Reading the source
 * ---------------------------------------------------------------------------------------------- */

/** The source without `%` comments (an escaped `\%` stays). */
export function stripComments(source: string): string {
  return source.replace(/(^|[^\\])%.*$/gm, "$1");
}

/** The contents of the first `\command{…}`, following nested braces. */
function argumentOf(source: string, command: string): string | null {
  const start = new RegExp(String.raw`\\${command}\*?(?:\[[^\]]*\])?\s*\{`).exec(source);
  if (!start) return null;
  let depth = 1;
  let index = start.index + start[0].length;
  const from = index;
  for (; index < source.length && depth > 0; index += 1) {
    if (source[index] === "\\") index += 1;
    else if (source[index] === "{") depth += 1;
    else if (source[index] === "}") depth -= 1;
  }
  return depth === 0 ? source.slice(from, index - 1) : null;
}

/** LaTeX as readable text: commands dropped, their arguments kept, whitespace collapsed. */
export function latexToText(source: string): string {
  return stripComments(source)
    .replace(/\\begin\{(?:equation|align|figure|table|tikzpicture)\*?\}[\s\S]*?\\end\{(?:equation|align|figure|table|tikzpicture)\*?\}/g, " ")
    .replace(/\\(?:label|ref|eqref|cite|citep|citet|input|include|usepackage|documentclass|bibliography|bibliographystyle)\*?(?:\[[^\]]*\])?\{[^}]*\}/g, " ")
    .replace(/\\(?:begin|end)\{[^}]*\}/g, " ")
    .replace(/\\[A-Za-z@]+\*?(?:\[[^\]]*\])?/g, " ")
    .replace(/\\(.)/g, "$1")
    .replace(/[{}$~^_]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function clip(text: string, limit: number): string {
  return text.length > limit ? `${text.slice(0, limit - 1).trimEnd()}…` : text;
}

/** The main file's `\title{…}` as plain text, or null. */
export function latexTitle(files: PaperFile[], mainFile: string): string | null {
  const main = files.find((file) => file.path === mainFile)?.content;
  const raw = main ? argumentOf(stripComments(main), "title") : null;
  const title = raw ? latexToText(raw.replace(/\\\\/g, " ")) : "";
  return title ? clip(title, 200) : null;
}

/** `.tex` files in the order a reader meets them: the main file first. */
function texFiles(document: Pick<PaperDocument, "files" | "mainFile">): PaperFile[] {
  const tex = document.files.filter((file) => file.path.toLowerCase().endsWith(".tex"));
  return [...tex.filter((file) => file.path === document.mainFile), ...tex.filter((file) => file.path !== document.mainFile)];
}

/** What the library item shows: the abstract (else the opening text) and the section titles. */
export function paperDigest(document: PaperDocument): { title: string; summary: string; highlights: string[]; keywords: string[] } {
  const sources = texFiles(document).map((file) => stripComments(file.content));
  const joined = sources.join("\n");
  const abstract = /\\begin\{abstract\}([\s\S]*?)\\end\{abstract\}/.exec(joined)?.[1];
  const body = latexToText(joined.replace(/^[\s\S]*?\\begin\{document\}/, ""));
  const summary = clip(latexToText(abstract ?? "") || body || "A LaTeX paper.", 1200);
  const sections = [...joined.matchAll(/\\(?:chapter|section)\*?\{([^}]*)\}/g)].map((match) => clip(latexToText(match[1]), 300)).filter(Boolean);
  const keywords = (argumentOf(joined, "keywords") ?? "").split(/[,;]/).map((word) => latexToText(word).slice(0, 60)).filter(Boolean);
  return { title: clip(document.title, 200), summary, highlights: sections.slice(0, 5), keywords: keywords.slice(0, 10) };
}

/** The paper as plain text: what search, embeddings and the library chat read. */
export function paperText(document: PaperDocument): string {
  const bib = document.files.filter((file) => file.path.toLowerCase().endsWith(".bib")).map((file) => file.content);
  return [document.title, ...texFiles(document).map((file) => latexToText(file.content)), ...bib].filter(Boolean).join("\n\n");
}

/** Identifies a compile's input: the same hash compiles to the same PDF. */
export function paperHash(project: { files: PaperFile[]; mainFile: string; compiler: PaperCompiler }): string {
  const files = [...project.files].sort((a, b) => a.path.localeCompare(b.path)).map((file) => file.asset ? [file.path, file.asset.key] : [file.path, file.content]);
  return createHash("sha256").update(JSON.stringify([project.compiler, project.mainFile, files])).digest("hex").slice(0, 32);
}

/** Whether two states hold the same title and source (file order aside). */
export function samePaper(a: PaperDocument, b: PaperDocument): boolean {
  return a.title === b.title && paperHash(a) === paperHash(b);
}

/* ------------------------------------------------------------------------------------------------
 * Editing
 * ---------------------------------------------------------------------------------------------- */

function editFailed(index: number, message: string): ApiError {
  return new ApiError(422, "PAPER_EDIT_FAILED", `Operation ${index + 1}: ${message}`, { index });
}

function countOf(content: string, find: string): number {
  let count = 0;
  for (let at = content.indexOf(find); at !== -1; at = content.indexOf(find, at + find.length)) count += 1;
  return count;
}

/** Applies operations in order; one that can't apply is `422 PAPER_EDIT_FAILED` naming it. */
export function applyPaperOperations(document: PaperDocument, operations: PaperOperation[]): PaperDocument {
  let { title, mainFile, compiler } = document;
  const files = document.files.map((file) => ({ ...file }));
  const find = (path: string) => files.findIndex((file) => file.path === path);
  operations.forEach((operation, index) => {
    switch (operation.op) {
      case "write_file": {
        const at = find(operation.path);
        const file = { path: operation.path, content: operation.content, ...(operation.asset ? { asset: operation.asset } : {}) };
        if (at === -1) files.push(file);
        else files[at] = file;
        break;
      }
      case "edit_file": {
        const at = find(operation.path);
        if (at === -1) throw editFailed(index, `There is no file "${operation.path}". Files: ${files.map((file) => file.path).join(", ")}`);
        if (files[at].asset) throw editFailed(index, "Images cannot be edited as text; replace the S3 asset with write_file");
        let content = files[at].content;
        operation.edits.forEach((edit, editIndex) => {
          const count = countOf(content, edit.find);
          if (count === 0) throw editFailed(index, `edit ${editIndex + 1}: the text to find is not in ${operation.path}`);
          if (count > 1 && !edit.all) throw editFailed(index, `edit ${editIndex + 1}: the text to find occurs ${count} times in ${operation.path}; add more context or set all: true`);
          content = edit.all ? content.split(edit.find).join(edit.replace) : content.replace(edit.find, () => edit.replace);
        });
        files[at] = { ...files[at], content };
        break;
      }
      case "delete_file": {
        const at = find(operation.path);
        if (at === -1) throw editFailed(index, `There is no file "${operation.path}"`);
        if (operation.path === mainFile) throw editFailed(index, "The main file can't be deleted; set another main file first");
        files.splice(at, 1);
        break;
      }
      case "rename_file": {
        const at = find(operation.from);
        if (at === -1) throw editFailed(index, `There is no file "${operation.from}"`);
        if (operation.from !== operation.to && find(operation.to) !== -1) throw editFailed(index, `"${operation.to}" already exists`);
        files[at] = { ...files[at], path: operation.to };
        if (mainFile === operation.from) mainFile = operation.to;
        break;
      }
      case "set_main_file":
        if (find(operation.path) === -1) throw editFailed(index, `There is no file "${operation.path}"`);
        mainFile = operation.path;
        break;
      case "set_compiler":
        compiler = operation.compiler;
        break;
      case "set_title":
        title = operation.title;
        break;
    }
  });
  return validPaper({ title, files, mainFile, compiler }, "The operations");
}

/** Parses a paper after edits; a broken one is `422 PAPER_INVALID` with the issues in `details`. */
export function validPaper(document: PaperDocument, what = "The edit"): PaperDocument {
  const parsed = paperDocumentSchema.safeParse(document);
  if (parsed.success) return parsed.data;
  const issues = parsed.error.issues.map((issue) => ({ path: issue.path, message: issue.message }));
  const listed = issues.slice(0, 3).map((issue) => `${issue.path.join(".") || "paper"}: ${issue.message}`).join("; ");
  throw new ApiError(422, "PAPER_INVALID", `${what} leaves the paper invalid: ${listed}`, { issues });
}
