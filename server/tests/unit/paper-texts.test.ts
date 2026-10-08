import { describe, expect, it } from "vitest";
import { latexTextRanges, mapPaperTexts } from "@/lib/latex/paper-texts";
import type { PaperDocument } from "@/lib/contracts/paper";

describe("paper prose translation", () => {
  it("preserves equations, citations, labels, URLs, images, code and bibliography", () => {
    const source = String.raw`\documentclass{article}
\title{Study of motion}
\usepackage{graphicx}
\begin{document}
\section{Results}\label{sec:results}
The energy is $E=mc^2$ and \textbf{remains constant}.
\cite{Smith2020} \ref{sec:results}
\href{https://example.com/a_b}{Read the source}
\includegraphics[width=0.5\textwidth]{images/photo.png}
\begin{equation}x+y=z\end{equation}
\begin{tikzpicture}\node{Chart label};\end{tikzpicture}
\begin{verbatim}Do not translate code\end{verbatim}
% Do not translate comments
\bibliography{references}
\end{document}`;
    const document: PaperDocument = { title: "Study", mainFile: "main.tex", compiler: "pdflatex", files: [{ path: "main.tex", content: source }, { path: "references.bib", content: "@article{Smith2020,title={Original title}}" }] };
    const translated = mapPaperTexts(document, (text) => `Translated ${text}`);
    expect(translated.files[0].content).toContain("\\section{Translated Results}\\label{sec:results}");
    for (const preserved of ["$E=mc^2$", "\\cite{Smith2020}", "\\ref{sec:results}", "https://example.com/a_b", "images/photo.png", "x+y=z", "\\node{Chart label}", "Do not translate code", "% Do not translate comments", "\\bibliography{references}"]) expect(translated.files[0].content).toContain(preserved);
    expect(translated.files[1]).toEqual(document.files[1]);
    expect(translated.files[0].content).toContain("{Translated Read the source}");
    expect(document.files[0].content).toBe(source);
  });

  it("escapes translated prose rather than allowing the model to inject LaTeX", () => {
    const original: PaperDocument = { title: "Study", mainFile: "main.tex", compiler: "pdflatex", files: [{ path: "main.tex", content: "\\section{Result}" }] };
    const result = mapPaperTexts(original, () => "50% & $x$ \\input{secret}");
    expect(result.files[0].content).toContain("50\\% \\& \\$x\\$ \\textbackslash{}input\\{secret\\}");
  });

  it("translates headings and prose in included files", () => {
    expect(latexTextRanges("\\section{Introduction}\nThe introduction.").map((range) => range.text)).toEqual(["Introduction", "The introduction."]);
  });

  it("keeps table specifications, caption types and macro definitions intact", () => {
    const source = String.raw`\newcommand{\sample}[1]{Sample #1} \def\other#1{Macro #1} Visible prose.
\begin{tabular}{ll}Name & Value\\Energy & Two\end{tabular}
\captionof{figure}{A caption}`;
    const document: PaperDocument = { title: "Study", mainFile: "main.tex", compiler: "pdflatex", files: [{ path: "main.tex", content: source }] };
    const output = mapPaperTexts(document, (text) => `Translated ${text}`).files[0].content;
    expect(output).toContain(String.raw`\newcommand{\sample}[1]{Sample #1} \def\other#1{Macro #1} Translated Visible prose.`);
    expect(output).toContain(String.raw`\begin{tabular}{ll}Translated Name`);
    expect(output).toContain(String.raw`\captionof{figure}{Translated A caption}`);
  });

  it("keeps paragraph breaks and bounds prose sent to translation", () => {
    const document: PaperDocument = { title: "Study", mainFile: "main.tex", compiler: "pdflatex", files: [{ path: "main.tex", content: "First paragraph.\n\nSecond paragraph.\n\n" + "Words ".repeat(1500) }] };
    const ranges = latexTextRanges(document.files[0].content);
    expect(ranges.every((range) => range.text.length <= 6000)).toBe(true);
    const output = mapPaperTexts(document, (text) => `Translated ${text}`).files[0].content;
    expect(output).toContain("Translated First paragraph.\n\nTranslated Second paragraph.");
  });
});
