import { strFromU8, strToU8, unzipSync, zipSync } from "fflate";
import type { PaperRendering } from "@/lib/contracts/paper-rendering";

const xml = (value: string) => value.replace(/[<>&"']/g, (char) => ({ "<": "&lt;", ">": "&gt;", "&": "&amp;", '"': "&quot;", "'": "&apos;" })[char]!);
const twips = (mm: number) => Math.round(mm * 1440 / 25.4);

function pageSection(style: PaperRendering): string {
  const sizes = { a4: [210, 297], letter: [215.9, 279.4], legal: [215.9, 355.6], a5: [148, 210] };
  const dimensions = sizes[style.pageSize];
  const [width, height] = style.orientation === "landscape" ? [...dimensions].reverse() : dimensions;
  return `<w:sectPr><w:headerReference w:type="default" r:id="rIdChippyHeader"/><w:footerReference w:type="default" r:id="rIdChippyFooter"/><w:pgSz w:w="${twips(width)}" w:h="${twips(height)}" w:orient="${style.orientation}"/><w:pgMar w:top="${twips(style.marginTop)}" w:bottom="${twips(style.marginBottom)}" w:left="${twips(style.marginLeft)}" w:right="${twips(style.marginRight)}" w:header="284" w:footer="284" w:gutter="0"/><w:cols w:num="${style.columns}" w:space="${twips(style.columnGap)}"/></w:sectPr>`;
}

function headerFooter(style: PaperRendering, kind: "header" | "footer"): string {
  const [region, alignment] = style.pageNumbers.split("-");
  const tag = kind === "header" ? "hdr" : "ftr";
  const number = region === kind ? '<w:fldSimple w:instr="PAGE"><w:r><w:t>1</w:t></w:r></w:fldSimple>' : "";
  const text = xml(kind === "header" ? style.headerText : style.footerText);
  return `<?xml version="1.0" encoding="UTF-8"?><w:${tag} xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:p><w:pPr><w:jc w:val="${region === kind ? alignment : "left"}"/></w:pPr><w:r><w:t xml:space="preserve">${text}${number && text ? "   " : ""}</w:t></w:r>${number}</w:p></w:${tag}>`;
}

/** WordprocessingML carries layout, fonts and spacing directly; columns remain editable in Word. */
export function renderWord(bytes: Uint8Array, style: PaperRendering): Uint8Array {
  if (!style.enabled) return bytes;
  const files = unzipSync(bytes);
  let document = strFromU8(files["word/document.xml"]);
  document = document.replace(/<w:sectPr\b[^>]*>[\s\S]*?<\/w:sectPr>/g, pageSection(style));
  if (style.titlePage) {
    // Keep title/author/date together in a full-width section before the column layout.
    const paragraphs = [...document.matchAll(/<w:p\b[^>]*>[\s\S]*?<\/w:p>/g)];
    let lastTitle: RegExpMatchArray | undefined;
    for (const paragraph of paragraphs) {
      if (!/w:pStyle w:val="(?:Title|Subtitle|Author|Date)"/.test(paragraph[0])) break;
      lastTitle = paragraph;
    }
    if (lastTitle) {
      const index = lastTitle.index! + lastTitle[0].length;
      const titleSection = pageSection({ ...style, columns: 1 }).replace("<w:pgSz", '<w:type w:val="nextPage"/><w:pgSz');
      document = document.slice(0, index) + `<w:p><w:pPr>${titleSection}</w:pPr></w:p>` + document.slice(index);
    }
  }
  files["word/document.xml"] = strToU8(document);
  const family = { original: null, serif: "Cambria", sans: "Arial", mono: "Consolas" }[style.fontFamily];
  const font = family ? `<w:rFonts w:ascii="${family}" w:hAnsi="${family}"/>` : "";
  const size = Math.round(style.fontSize * 2);
  const alignment = style.alignment === "justified" ? "both" : style.alignment;
  const paragraph = `<w:spacing w:after="${Math.round(style.paragraphSpacing * 20)}" w:line="${Math.round(style.lineSpacing * 240)}" w:lineRule="auto"/><w:ind w:firstLine="${Math.round(style.paragraphIndent * 20)}"/><w:jc w:val="${alignment}"/>`;
  let styles = strFromU8(files["word/styles.xml"]);
  styles = styles.replace(/<w:docDefaults>[\s\S]*?<\/w:docDefaults>/, `<w:docDefaults><w:rPrDefault><w:rPr>${font}<w:sz w:val="${size}"/><w:szCs w:val="${size}"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr>${paragraph}</w:pPr></w:pPrDefault></w:docDefaults>`);
  styles = styles.replace(/<w:style\b[^>]*>[\s\S]*?<\/w:style>/g, (block) => {
    const heading = /w:styleId="Heading([1-9])"/.exec(block);
    if (heading) {
      const headingSize = Math.round(Math.max(8, style.headingSize - (Number(heading[1]) - 1) * 2) * 2);
      return block.replace(/<w:rPr>[\s\S]*?<\/w:rPr>/, `<w:rPr>${font}<w:b/><w:color w:val="${style.headingColor}"/><w:sz w:val="${headingSize}"/><w:szCs w:val="${headingSize}"/></w:rPr>`);
    }
    if (/w:styleId="(?:Normal|BodyText|FirstParagraph)"/.test(block)) {
      block = block.replace(/<w:pPr>[\s\S]*?<\/w:pPr>/, `<w:pPr>${paragraph}</w:pPr>`);
      if (!block.includes("<w:pPr>")) block = block.replace("</w:style>", `<w:pPr>${paragraph}</w:pPr></w:style>`);
      // These explicit run defaults otherwise override the document defaults.
      block = block.replace(/<w:rPr>[\s\S]*?<\/w:rPr>/, `<w:rPr>${font}<w:sz w:val="${size}"/><w:szCs w:val="${size}"/></w:rPr>`);
    }
    return block;
  });
  files["word/styles.xml"] = strToU8(styles);
  let settings = strFromU8(files["word/settings.xml"]);
  settings = settings.replace(/<w:autoHyphenation\b[^>]*\/?>(?:<\/w:autoHyphenation>)?/g, "").replace("</w:settings>", `<w:autoHyphenation w:val="${style.hyphenation ? "true" : "false"}"/></w:settings>`);
  files["word/settings.xml"] = strToU8(settings);
  for (const kind of ["header", "footer"] as const) {
    files[`word/chippy-${kind}.xml`] = strToU8(headerFooter(style, kind));
    const key = "word/_rels/document.xml.rels";
    files[key] = strToU8(strFromU8(files[key]).replace("</Relationships>", `<Relationship Id="rIdChippy${kind === "header" ? "Header" : "Footer"}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/${kind}" Target="chippy-${kind}.xml"/></Relationships>`));
    files["[Content_Types].xml"] = strToU8(strFromU8(files["[Content_Types].xml"]).replace("</Types>", `<Override PartName="/word/chippy-${kind}.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.${kind}+xml"/></Types>`));
  }
  return zipSync(files);
}
