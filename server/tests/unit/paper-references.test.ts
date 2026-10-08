import { describe, expect, it } from "vitest";
import type { PaperDocument } from "@/lib/contracts/paper";
import { paperReferences } from "@/lib/services/paper-references";

function paper(files: PaperDocument["files"]): PaperDocument {
  return { title: "Gears", mainFile: "main.tex", compiler: "pdflatex", files };
}

const BIB = String.raw`% A comment line with @ in it is skipped
@string{acm = "ACM"}

@article{lamport1978,
  author  = {Leslie Lamport},
  title   = {Time, Clocks, and the Ordering of Events in a {Distributed} System},
  journal = acm # " Communications",
  year    = 1978,
  doi     = {10.1145/359545.359563}
}

@misc{web2024, title = "Gear {"}Ratios{"}", url = {https://example.com/gears\_101}}
@comment{ignored}
@book{knuth1984,
  author = {Donald E. Knuth}, title = {The {\TeX}book}, publisher = {Addison-Wesley}, year = {1984}
}
`;

describe("paperReferences", () => {
  it("reads .bib entries with their fields, links and lines, skipping @string and @comment", () => {
    const references = paperReferences(paper([
      { path: "main.tex", content: "\\begin{document}\nClocks order events \\cite{lamport1978}. Gears \\citep[p.~2]{web2024, knuth1984}.\n\\end{document}\n" },
      { path: "references.bib", content: BIB },
    ]));
    expect(references.map((reference) => [reference.key, reference.line])).toEqual([["lamport1978", 4], ["web2024", 12], ["knuth1984", 14]]);
    const [lamport, web, knuth] = references;
    expect(lamport).toMatchObject({
      type: "article",
      file: "references.bib",
      title: "Time, Clocks, and the Ordering of Events in a Distributed System",
      url: "https://doi.org/10.1145/359545.359563",
      fields: { journal: "ACM Communications", year: "1978" },
    });
    expect(lamport.contexts).toEqual(["Clocks order events [lamport1978]."]);
    expect(web.url).toBe("https://example.com/gears_101");
    expect(knuth.contexts[0]).toContain("Gears");
    expect(knuth.title).toBe("The TeXbook");
  });

  it("hashes an entry's content, not its key or layout", () => {
    const [first] = paperReferences(paper([{ path: "main.tex", content: "" }, { path: "a.bib", content: "@book{a, title={X}, year={1}}" }]));
    const [renamed] = paperReferences(paper([{ path: "main.tex", content: "" }, { path: "a.bib", content: "@book{b,\n  year = {1},\n  title = {X}\n}" }]));
    const [changed] = paperReferences(paper([{ path: "main.tex", content: "" }, { path: "a.bib", content: "@book{a, title={X}, year={2}}" }]));
    expect(renamed.hash).toBe(first.hash);
    expect(changed.hash).not.toBe(first.hash);
  });

  it("reads \\bibitem entries of a thebibliography", () => {
    const references = paperReferences(paper([{
      path: "main.tex",
      content: String.raw`\begin{document}
See \cite{doe}.
\begin{thebibliography}{9}
\bibitem{doe} J. Doe. \emph{Gears}. 2020. \url{https://example.org/doe}
\bibitem[Roe]{roe} R. Roe. Wheels. doi:10.1000/xyz123
\end{thebibliography}
\end{document}
`,
    }]));
    expect(references.map((reference) => ({ key: reference.key, line: reference.line, url: reference.url }))).toEqual([
      { key: "doe", line: 4, url: "https://example.org/doe" },
      { key: "roe", line: 5, url: "https://doi.org/10.1000/xyz123" },
    ]);
    expect(references[0].title).toContain("Gears");
  });

  it("lists a key defined twice once, as BibTeX reads it", () => {
    const references = paperReferences(paper([
      { path: "main.tex", content: "" },
      { path: "a.bib", content: "@book{same, title={First}}" },
      { path: "b.bib", content: "@book{same, title={Second}}" },
    ]));
    expect(references.map((reference) => reference.title)).toEqual(["First"]);
  });
});
