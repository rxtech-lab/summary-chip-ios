import { describe, expect, it } from "vitest";
import type { PaperDocument } from "@/lib/contracts/paper";
import { renderLatex } from "@/lib/latex/rendering";

const source: PaperDocument = { title: "Study", mainFile: "main.tex", compiler: "pdflatex", files: [
  { path: "main.tex", content: String.raw`\documentclass{article}
\title{Study}
\begin{document}
\maketitle
\tableofcontents
\section{Results}
\input{figures/result}
\end{document}` },
  { path: "figures/result.tex", content: String.raw`\begin{figure}[H]
\includegraphics[width=\textwidth]{images/result.png}
\caption{Results}
\end{figure}` },
] };

describe("paper rendering", () => {
  it("preserves the original layout when disabled and never mutates source files", () => {
    expect(renderLatex(source, { enabled: false, columns: 2 })).toBe(source);
    const before = JSON.stringify(source);
    const output = renderLatex(source, { enabled: true, columns: 2 });
    expect(output.files[1].content).toContain("\\begin{figure*}");
    expect(output.files[1].content).not.toContain("[H]");
    expect(output.files[1].content).toContain("\\end{figure*}");
    expect(JSON.stringify(source)).toBe(before);
    for (let index = 0; index < source.files.length; index++) {
      expect(output.files[index].content.split("\n").length).toBe(source.files[index].content.split("\n").length);
    }
  });

  it("controls authored contents and places inserted contents after the title page", () => {
    expect(renderLatex(source, { enabled: true, tableOfContents: false }).files[0].content).not.toContain("\\tableofcontents");
    const document = { ...source, files: source.files.map((file) => ({ ...file, content: file.content.replace("\\tableofcontents", "") })) };
    const output = renderLatex(document, { enabled: true, titlePage: true, tableOfContents: true, columns: 2 }).files[0].content;
    expect(output.indexOf("\\end{titlepage}")).toBeLessThan(output.indexOf("\\tableofcontents"));
  });
});
