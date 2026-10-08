import { describe, expect, it } from "vitest";
import { paperDocumentSchema, paperPathSchema, type PaperDocument } from "@/lib/contracts/paper";
import { ApiError } from "@/lib/http/errors";
import { parseLatexLog } from "@/lib/latex/compiler";
import { applyPaperOperations, latexTitle, latexToText, paperDigest, paperHash, samePaper, templateFiles } from "@/lib/services/paper-document";

function paper(overrides: Partial<PaperDocument> = {}): PaperDocument {
  return {
    title: "Gears",
    mainFile: "main.tex",
    compiler: "pdflatex",
    files: [
      { path: "main.tex", content: "\\documentclass{article}\n\\title{Quantum \\emph{Gears}}\n\\begin{document}\n\\begin{abstract}We entangle gears.\\end{abstract}\n\\input{sections/intro}\n\\end{document}\n" },
      { path: "sections/intro.tex", content: "\\section{Introduction}\nGears turn. % a comment\n" },
    ],
    ...overrides,
  };
}

describe("parseLatexLog", () => {
  const log = [
    "(./__main_document__.tex",
    "./__main_document__.tex:4: Undefined control sequence.",
    "l.4 \\badcommand",
    "./chapters/intro.tex:2: Missing $ inserted.",
    "./chapters/intro.tex:2:  ==> Fatal error occurred, no output PDF file produced!",
    "! Emergency stop.",
  ].join("\n");

  it("maps errors to project files and lines, naming the main file by its path", () => {
    expect(parseLatexLog(log, "main.tex", "__main_document__.tex")).toEqual([
      { file: "main.tex", line: 4, message: "Undefined control sequence." },
      { file: "chapters/intro.tex", line: 2, message: "Missing $ inserted." },
    ]);
  });

  it("falls back to `!` errors when the log names no place", () => {
    expect(parseLatexLog("! LaTeX Error: File `missing.sty' not found.\n", "main.tex")).toEqual([
      { file: null, line: null, message: "LaTeX Error: File `missing.sty' not found." },
    ]);
  });
});

describe("paper source", () => {
  it("reads the title and digest from the LaTeX", () => {
    const document = paper();
    expect(latexTitle(document.files, document.mainFile)).toBe("Quantum Gears");
    expect(paperDigest(document)).toMatchObject({ summary: "We entangle gears.", highlights: ["Introduction"] });
    expect(latexToText("Gears turn. % a comment\n\\textbf{fast} 50\\% off")).toBe("Gears turn. fast 50% off");
  });

  it("hashes the source regardless of file order", () => {
    const document = paper();
    const reordered = { ...document, files: [...document.files].reverse() };
    expect(paperHash(reordered)).toBe(paperHash(document));
    expect(samePaper(reordered, document)).toBe(true);
    expect(samePaper({ ...document, compiler: "xelatex" }, document)).toBe(false);
  });

  it("templates are valid papers", () => {
    for (const template of ["article", "report", "blank"] as const) {
      const project = templateFiles(template, "A {Study} of 100% Gears");
      const parsed = paperDocumentSchema.safeParse({ title: "x", compiler: "pdflatex", ...project });
      expect(parsed.success).toBe(true);
      expect(latexTitle(project.files, project.mainFile)).toBe("A Study of 100% Gears");
    }
  });

  it("refuses unsafe or unsupported paths", () => {
    for (const bad of ["../main.tex", "/etc/passwd.tex", "figure.svg", "a/./b.tex", "main"]) {
      expect(paperPathSchema.safeParse(bad).success, bad).toBe(false);
    }
    expect(paperPathSchema.safeParse("chapters/01-intro.tex").success).toBe(true);
  });
});

describe("applyPaperOperations", () => {
  it("writes, edits, renames and deletes files", () => {
    const next = applyPaperOperations(paper(), [
      { op: "edit_file", path: "sections/intro.tex", edits: [{ find: "Gears turn.", replace: "Gears spin." }] },
      { op: "write_file", path: "references.bib", content: "@misc{a, title={A}}" },
      { op: "rename_file", from: "main.tex", to: "paper.tex" },
      { op: "set_compiler", compiler: "xelatex" },
      { op: "set_title", title: "Spinning Gears" },
    ]);
    expect(next.mainFile).toBe("paper.tex");
    expect(next.compiler).toBe("xelatex");
    expect(next.title).toBe("Spinning Gears");
    expect(next.files.map((file) => file.path)).toEqual(["paper.tex", "sections/intro.tex", "references.bib"]);
    expect(next.files[1].content).toContain("Gears spin.");
    expect(applyPaperOperations(next, [{ op: "delete_file", path: "references.bib" }]).files).toHaveLength(2);
  });

  it("refuses edits that don't apply, naming the operation", () => {
    const attempt = (operations: Parameters<typeof applyPaperOperations>[1]) => {
      try {
        applyPaperOperations(paper(), operations);
      } catch (error) {
        return error as ApiError;
      }
      throw new Error("expected a failure");
    };
    expect(attempt([{ op: "edit_file", path: "main.tex", edits: [{ find: "nope", replace: "x" }] }]).message).toContain("Operation 1");
    expect(attempt([{ op: "edit_file", path: "main.tex", edits: [{ find: "\\", replace: "x" }] }]).message).toContain("all: true");
    expect(attempt([{ op: "delete_file", path: "main.tex" }]).code).toBe("PAPER_EDIT_FAILED");
    expect(attempt([{ op: "set_main_file", path: "sections/missing.tex" }]).code).toBe("PAPER_EDIT_FAILED");
    expect(attempt([{ op: "write_file", path: "notes.txt", content: "" }, { op: "set_main_file", path: "notes.txt" }]).code).toBe("PAPER_INVALID");
  });
});
