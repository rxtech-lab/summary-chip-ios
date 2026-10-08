import type { PaperDocument } from "@/lib/contracts/paper";
import { paperRenderingSchema, type PaperRendering } from "@/lib/contracts/paper-rendering";

export function latexProse(value: string): string {
  return value.replace(/[\\{}$%&#_^~]/g, (char) => ({ "\\": "\\textbackslash{}", "~": "\\textasciitilde{}", "^": "\\textasciicircum{}" })[char] ?? `\\${char}`);
}

function preamble(style: PaperRendering): string {
  // TeX Live finds bundled OTF files even when the container has no fontconfig name index.
  const font = { original: "", serif: "texgyretermes", sans: "texgyreheros", mono: "texgyrecursor" }[style.fontFamily];
  const [region, position] = style.pageNumbers.split("-");
  const place = { left: "L", center: "C", right: "R" }[position as "left" | "center" | "right"] ?? "C";
  return [
    `\\usepackage{geometry}\n\\geometry{${style.pageSize}paper,${style.orientation},top=${style.marginTop}mm,bottom=${style.marginBottom}mm,left=${style.marginLeft}mm,right=${style.marginRight}mm,includeheadfoot}`,
    "\\usepackage{fontspec,setspace,ragged2e,xcolor,titlesec,fancyhdr}",
    font ? `\\setmainfont{${font}}[Extension=.otf,UprightFont=*-regular,BoldFont=*-bold,ItalicFont=*-italic,BoldItalicFont=*-bolditalic]` : "",
    `\\setstretch{${style.lineSpacing}}\n\\setlength{\\parskip}{${style.paragraphSpacing}pt}\n\\setlength{\\parindent}{${style.paragraphIndent}pt}\n\\setlength{\\columnsep}{${style.columnGap}mm}`,
    `\\definecolor{chippyheading}{HTML}{${style.headingColor}}`,
    ...["section", "subsection", "subsubsection"].map((name, index) => `\\titleformat{\\${name}}{\\normalfont\\bfseries\\color{chippyheading}\\fontsize{${Math.max(8, style.headingSize - index * 2)}}{${style.headingSize + 3}pt}\\selectfont}{\\csname the${name}\\endcsname}{1em}{}`),
    `\\ifdefined\\chapter\\titleformat{\\chapter}[display]{\\normalfont\\bfseries\\color{chippyheading}\\fontsize{${style.headingSize}}{${style.headingSize + 3}pt}\\selectfont}{\\chaptertitlename\\ \\thechapter}{1em}{}\\fi`,
    `\\setcounter{secnumdepth}{${style.sectionNumbers ? 3 : -1}}\n\\setcounter{tocdepth}{${style.tocDepth}}`,
    "\\pagestyle{fancy}\n\\fancyhf{}\n\\renewcommand{\\headrulewidth}{0pt}\n\\renewcommand{\\footrulewidth}{0pt}",
    style.headerText ? `\\fancyhead[L]{${latexProse(style.headerText)}}` : "",
    style.footerText ? `\\fancyfoot[L]{${latexProse(style.footerText)}}` : "",
    region !== "none" ? `\\fancy${region === "header" ? "head" : "foot"}[${place}]{${place === "L" ? latexProse(region === "header" ? style.headerText : style.footerText) + "\\quad " : ""}\\thepage}` : "",
    "\\makeatletter\\let\\ps@plain\\ps@fancy\\makeatother",
    "\\makeatletter\\ifdefined\\@titlepagefalse\\@titlepagefalse\\fi\\makeatother",
    style.hyphenation ? "" : "\\hyphenpenalty=10000\n\\exhyphenpenalty=10000",
  ].filter(Boolean).join("\n");
}

/**
 * Papers are usually written for one column, so their figures and tables are sized to \textwidth.
 * In two columns those overflow a single column; make them span both columns instead. Placement
 * options are dropped because double-column floats reject `h`/`H`. Edits stay on the same line.
 */
function spanColumns(content: string): string {
  return content
    .replace(/\\begin\{(figure|table)\}(?:\s*\[[^\]]*\])?/g, "\\begin{$1*}")
    .replace(/\\end\{(figure|table)\}/g, "\\end{$1*}");
}

/** Apply only to the generated copy. Original files, including custom classes, are never rewritten in storage. */
export function renderLatex(document: PaperDocument, input: Partial<PaperRendering>): PaperDocument {
  const style = paperRenderingSchema.parse(input);
  if (!style.enabled) return document;
  const align = { justified: "\\justifying", left: "\\RaggedRight", center: "\\Centering", right: "\\RaggedLeft" }[style.alignment];
  return { ...document, compiler: "xelatex", files: document.files.map((source) => {
    const file = style.columns === 2 && source.path.endsWith(".tex") ? { ...source, content: spanColumns(source.content) } : source;
    if (file.path !== document.mainFile) return file;
    let content = file.content.replace(/\\usepackage(?:\[[^\]]*\])?\{(?:inputenc|fontenc)\}/g, "");
    // Pass geometry before a class can load it, avoiding an option clash with custom classes.
    content = `\\PassOptionsToPackage{${style.pageSize}paper,${style.orientation}}{geometry}` + content;
    // Keep source line numbers stable for the editor's error markers.
    content = content.replace(/\\begin\{document\}/, `${preamble(style).replace(/\n/g, " ")} \\begin{document} ${style.columns === 2 ? "\\twocolumn" : "\\onecolumn"} \\fontsize{${style.fontSize}}{${style.fontSize * 1.2}}\\selectfont ${align} \\setlength{\\parindent}{${style.paragraphIndent}pt} `);
    if (style.titlePage && /\\maketitle\b/.test(content)) content = content.replace(/\\maketitle\b/, "\\begin{titlepage}\\onecolumn\\maketitle\\end{titlepage}" + (style.columns === 2 ? "\\twocolumn" : ""));
    if (style.tableOfContents && !/\\tableofcontents\b/.test(file.content)) {
      const afterTitle = style.titlePage ? /(\\end\{titlepage\})/ : /(\\maketitle)/;
      content = /\\maketitle\b/.test(content) ? content.replace(afterTitle, "$1 \\tableofcontents \\clearpage ") : content.replace(/(\\selectfont \\(?:justifying|RaggedRight|Centering|RaggedLeft))/, "$1 \\tableofcontents \\clearpage ");
    }
    if (!style.tableOfContents) content = content.replace(/\\tableofcontents\b/g, "");
    return { ...file, content };
  }) };
}
