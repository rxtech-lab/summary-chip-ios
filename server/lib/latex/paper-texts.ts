import type { PaperDocument } from "@/lib/contracts/paper";

/** Human prose only. Commands, paths, labels, citations, math and drawing/code environments stay verbatim. */
const TEXT_COMMANDS = new Set(["title", "subtitle", "section", "subsection", "subsubsection", "chapter", "part", "paragraph", "subparagraph", "caption", "captionof", "footnote", "thanks", "textbf", "textit", "textsf", "textrm", "texttt", "emph", "underline", "text", "mbox"]);
const OPAQUE_ENVIRONMENTS = /^(?:equation\*?|align\*?|alignat\*?|gather\*?|multline\*?|displaymath|math|tikzpicture|axis|verbatim\*?|lstlisting|minted|thebibliography)$/;
const DEFINITIONS = new Set(["newcommand", "renewcommand", "providecommand", "DeclareRobustCommand", "newenvironment", "renewenvironment", "def", "gdef", "edef", "xdef"]);
const ENV_ARGUMENTS: Record<string, number> = { tabular: 1, "tabular*": 2, tabularx: 2, longtable: 1, array: 1, minipage: 1, list: 2, picture: 1 };

function groupEnd(source: string, start: number, open = "{", close = "}"): number {
  let depth = 0;
  for (let index = start; index < source.length; index++) {
    if (source[index] === "\\") { index++; continue; }
    if (source[index] === open) depth++;
    if (source[index] === close && --depth === 0) return index + 1;
  }
  return source.length;
}

/** Ranges point into the original string, so replacing prose never reserializes LaTeX syntax. */
export function latexTextRanges(source: string): { start: number; end: number; text: string }[] {
  const ranges: { start: number; end: number; text: string }[] = [];
  const add = (start: number, end: number) => {
    const raw = source.slice(start, end);
    // Keep paragraph breaks in the source and bound each model item for long plain-text sections.
    for (const paragraph of raw.matchAll(/[^\n]*(?:\n(?![ \t]*\n)[^\n]*)*/g)) {
      let position = 0;
      while (position < paragraph[0].length) {
        let stop = Math.min(position + 6000, paragraph[0].length);
        if (stop < paragraph[0].length) {
          const whitespace = paragraph[0].slice(position, stop).search(/\s+\S*$/);
          if (whitespace > 3000) stop = position + whitespace;
        }
        const value = paragraph[0].slice(position, stop);
        const text = value.trim();
        if (/\p{L}/u.test(text)) {
          const offset = paragraph.index! + position + value.indexOf(text);
          ranges.push({ start: start + offset, end: start + offset + text.length, text });
        }
        position = stop;
      }
    }
  };
  const visit = (start: number, end: number, prose: boolean) => {
    let index = start;
    while (index < end) {
      const char = source[index];
      if (char === "%") { index = Math.min(end, source.indexOf("\n", index) < 0 ? end : source.indexOf("\n", index)); continue; }
      if (char === "$") {
        const delimiter = source[index + 1] === "$" ? "$$" : "$";
        const stop = source.indexOf(delimiter, index + delimiter.length);
        index = stop < 0 ? end : stop + delimiter.length;
        continue;
      }
      if (char === "\\") {
        const command = /^\\([A-Za-z@]+\*?|.)/s.exec(source.slice(index));
        if (!command) { index++; continue; }
        const name = command[1].replace(/\*$/, "");
        index += command[0].length;
        if (name === "(" || name === "[") {
          const stop = source.indexOf(name === "(" ? "\\)" : "\\]", index);
          index = stop < 0 ? end : stop + 2;
          continue;
        }
        if (name === "verb") {
          const stop = source.indexOf(source[index], index + 1);
          index = stop < 0 ? end : stop + 1;
          continue;
        }
        while (/\s/.test(source[index] ?? "") && index < end) index++;
        if (source[index] === "[") index = groupEnd(source, index, "[", "]");
        if (DEFINITIONS.has(name)) {
          if (name.endsWith("def")) {
            while (index < end && source[index] !== "{") index++;
            if (source[index] === "{") index = groupEnd(source, index);
          } else {
            // Name, optional arity/default, replacement; environments have a second replacement.
            if (source[index] === "{") index = groupEnd(source, index);
            else index += /^\\[A-Za-z@]+/.exec(source.slice(index))?.[0].length ?? 0;
            while (index < end && (/\s/.test(source[index]) || source[index] === "[")) {
              index = source[index] === "[" ? groupEnd(source, index, "[", "]") : index + 1;
            }
            for (let body = 0; body < (name.endsWith("environment") ? 2 : 1); body++) {
              while (/\s/.test(source[index] ?? "") && index < end) index++;
              if (source[index] === "{") index = groupEnd(source, index);
            }
          }
          continue;
        }
        if ((name === "begin" || name === "end") && source[index] === "{") {
          const stop = groupEnd(source, index);
          const environment = source.slice(index + 1, stop - 1);
          index = stop;
          if (name === "begin" && OPAQUE_ENVIRONMENTS.test(environment)) {
            const close = `\\end{${environment}}`;
            const closing = source.indexOf(close, index);
            index = closing < 0 ? end : closing + close.length;
          }
          if (environment === "document") prose = name === "begin";
          if (name === "begin") {
            while (/\s/.test(source[index] ?? "") && index < end) index++;
            if (source[index] === "[") index = groupEnd(source, index, "[", "]");
            for (let argument = 0; argument < (ENV_ARGUMENTS[environment] ?? 0); argument++) {
              while (/\s/.test(source[index] ?? "") && index < end) index++;
              if (source[index] === "{") index = groupEnd(source, index);
            }
          }
          continue;
        }
        // href's first argument is a URL; its second is visible link text.
        let argument = 0;
        while (source[index] === "{") {
          const stop = groupEnd(source, index);
          if ((TEXT_COMMANDS.has(name) && (name !== "captionof" || argument === 1)) || (name === "href" && argument === 1)) visit(index + 1, stop - 1, true);
          index = stop;
          argument++;
        }
        continue;
      }
      if (char === "{") {
        const stop = groupEnd(source, index);
        visit(index + 1, stop - 1, prose);
        index = stop;
        continue;
      }
      if ("}&~^_#".includes(char)) { index++; continue; }
      const textStart = index++;
      while (index < end && !"\\$%{}&~^_#".includes(source[index])) index++;
      if (prose) add(textStart, index);
    }
  };
  // Included chapter files have no preamble; full documents start translating prose at begin{document}.
  visit(0, source.length, !/\\documentclass\b/.test(source));
  return ranges;
}

/** Escape model output as prose: it cannot add commands, math, comments or alignment columns. */
function escapeProse(text: string): string {
  return text.replace(/[\\{}$%&#_^~]/g, (char) => ({ "\\": "\\textbackslash{}", "~": "\\textasciitilde{}", "^": "\\textasciicircum{}" })[char] ?? `\\${char}`);
}

export function mapPaperTexts(document: PaperDocument, visit: (text: string) => string): PaperDocument {
  return {
    ...document,
    title: visit(document.title),
    files: document.files.map((file) => {
      if (file.asset || !file.path.endsWith(".tex")) return file;
      let content = file.content;
      for (const range of latexTextRanges(content).reverse()) {
        const translated = visit(range.text);
        if (translated !== range.text) content = content.slice(0, range.start) + escapeProse(translated) + content.slice(range.end);
      }
      return { ...file, content };
    }),
  };
}

export function paperTexts(document: PaperDocument): string[] {
  const texts = new Set<string>();
  mapPaperTexts(document, (text) => { texts.add(text); return text; });
  return [...texts];
}
