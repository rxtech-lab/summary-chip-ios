import type { PaperDocument } from "@/lib/contracts/paper";

/** Unicode translations need XeLaTeX; inject font support into the export copy only. */
export function translatedPdfProject(document: PaperDocument, language: string): PaperDocument {
  const cjk = /^(?:zh|ja|ko)/.test(language);
  const fonts: Record<string, [string, string]> = {
    "zh-Hans": ["Noto Serif CJK SC", "FandolSong-Regular.otf"],
    "zh-Hant": ["Noto Serif CJK TC", "FandolSong-Regular.otf"],
    ja: ["Noto Serif CJK JP", "HaranoAjiMincho-Regular.otf"],
    ko: ["Noto Serif CJK KR", "UnBatang.ttf"],
  };
  const [font, fallback] = fonts[language] ?? fonts["zh-Hans"];
  const fontSetup = cjk ? `\\usepackage{xeCJK}\n\\IfFontExistsTF{${font}}{\\setCJKmainfont{${font}}}{\\setCJKmainfont{${fallback}}}\n` : "";
  return {
    ...document, compiler: "xelatex",
    files: document.files.map((file) => file.path === document.mainFile ? {
      ...file,
      content: file.content.replace(/\\usepackage(?:\[[^\]]*\])?\{(?:inputenc|fontenc)\}/g, "")
        .replace(/\\begin\{document\}/, `\\usepackage{fontspec}\n${fontSetup}\\begin{document}`),
    } : file),
  };
}
