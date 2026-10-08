import { describe, expect, it } from "vitest";
import { renderLatex } from "@/lib/latex/rendering";
import type { PaperDocument } from "@/lib/contracts/paper";

describe("paper rendering", () => {
  const main = String.raw`\documentclass{article}
\begin{document}
\begin{figure}[H]\centering\includegraphics[width=\textwidth]{a.png}\end{figure}
\input{sections/results}
\end{document}`;
  const section = String.raw`\begin{table}[htbp]
\begin{subfigure}{0.5\textwidth}\end{subfigure}
\end{table}`;
  const document: PaperDocument = { title: "Study", mainFile: "main.tex", compiler: "pdflatex", files: [{ path: "main.tex", content: main }, { path: "sections/results.tex", content: section }] };

  it("makes figures and tables span both columns in two-column layouts", () => {
    const rendered = renderLatex(document, { enabled: true, columns: 2 });
    expect(rendered.files[0].content).toContain("\\begin{figure*}\\centering");
    expect(rendered.files[0].content).toContain("\\end{figure*}");
    expect(rendered.files[1].content).toBe("\\begin{table*}\n\\begin{subfigure}{0.5\\textwidth}\\end{subfigure}\n\\end{table*}");
    expect(rendered.files[0].content.split("\n")).toHaveLength(main.split("\n").length);
  });

  it("leaves floats alone in one-column layouts", () => {
    const rendered = renderLatex(document, { enabled: true, columns: 1 });
    expect(rendered.files[0].content).toContain("\\begin{figure}[H]");
    expect(rendered.files[1].content).toBe(section);
  });
});
