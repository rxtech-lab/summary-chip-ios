import { zipSync, strToU8 } from "fflate";
import { z } from "zod";
import type { ResumeDocument } from "@/lib/contracts/resume";

export const RESUME_TEMPLATES = [
  { id: "compact-v1", name: "Compact", version: 1 },
  { id: "profile-v1", name: "Profile", version: 1 },
  { id: "editorial-v1", name: "Editorial", version: 1 },
  { id: "modern-v1", name: "Modern", version: 1 },
] as const;

export const presentationSchema = z
  .object({
    template: z.enum(RESUME_TEMPLATES.map(({ id }) => id)).default("compact-v1"),
    paperSize: z.enum(["A4", "Letter"]).default("A4"),
    showAvatar: z.boolean().default(true),
  })
  .strict();
export type ResumePresentation = z.infer<typeof presentationSchema>;

const xml = (text: string) =>
  text
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\uFFFE\uFFFF]/g, "")
    .replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&apos;" })[char]!);
const safeLink = (value: string) => (/^https?:\/\//i.test(value) ? value : undefined);
type Line = {
  style: "Title" | "Subtitle" | "Contact" | "Heading1" | "Heading2" | "Normal" | "Bullet";
  text: string;
  href?: string;
};
function linesOf(doc: ResumeDocument, language: string) {
  const lines: Line[] = [{ style: "Title", text: doc.candidateName }];
  function add(style: Line["style"], text?: string, href?: string) {
    if (text) lines.push({ style, text, href });
  }
  add("Subtitle", doc.headline);
  add("Contact", [doc.contact?.email, doc.contact?.phone, doc.contact?.location].filter(Boolean).join("  ·  "));
  for (const link of doc.links) add("Contact", link.label || link.url, safeLink(link.url));
  const headerLength = lines.length;
  for (const section of doc.sections) {
    add("Heading1", section.title);
    for (const entry of section.entries) {
      add("Heading2", [entry.title, entry.organization].filter(Boolean).join(" · "));
      const present =
        (
          {
            fr: "présent",
            es: "actualidad",
            de: "heute",
            ja: "現在",
            ko: "현재",
            ar: "الآن",
            zh: "至今",
            pt: "atual",
          } as Record<string, string>
        )[language.split("-")[0]] ?? "Present";
      const dates = [entry.startDate, entry.current ? present : entry.endDate].filter(Boolean).join(" – ");
      add("Contact", [entry.location, dates].filter(Boolean).join(" · "));
      add("Normal", entry.description);
      add("Normal", entry.url, entry.url && safeLink(entry.url));
      for (const bullet of entry.bullets) add("Bullet", bullet.text);
    }
  }
  return { header: lines.slice(0, headerLength), content: lines.slice(headerLength) };
}
export function displaysAvatar(p: ResumePresentation) {
  return p.template === "profile-v1" && p.showAvatar;
}

const templateStyles = {
  "editorial-v1": `
    .resume-header{text-align:center;border-bottom:1pt solid #B88FA6;padding:0 0 12pt;break-inside:avoid}
    h1{font:bold 31pt/1.18 Georgia,"Noto Serif",serif;color:#67364F}
    h2{font:bold 15pt/1.18 Georgia,"Noto Serif",serif;color:#67364F}
    .resume-header a{color:#67364F}`,
  "modern-v1": `
    .resume-header{background:#173047;color:white;text-align:left;padding:15pt 17pt;break-inside:avoid;
      -webkit-print-color-adjust:exact;print-color-adjust:exact}
    .resume-header h1{font-size:30pt}
    .resume-header .Subtitle,.resume-header .Contact,.resume-header a{color:#D4F3EE}
    h2{color:#17665F;border-bottom:0.75pt solid #B9DCD7;padding-bottom:3pt}`,
};

function renderHtmlLines(lines: Line[]) {
  let html = "",
    list = false;
  for (const line of lines) {
    if (line.style === "Bullet" && !list) {
      html += "<ul>";
      list = true;
    }
    if (line.style !== "Bullet" && list) {
      html += "</ul>";
      list = false;
    }
    const tag = { Title: "h1", Heading1: "h2", Heading2: "h3", Bullet: "li", Subtitle: "p", Contact: "p", Normal: "p" }[
      line.style
    ];
    const body = line.href
      ? '<a rel="noreferrer noopener" href="' + xml(line.href) + '">' + xml(line.text) + "</a>"
      : xml(line.text);
    html += "<" + tag + ' class="' + line.style + '" dir="auto">' + body + "</" + tag + ">";
  }
  if (list) html += "</ul>";
  return html;
}

export function renderResumeHtml(
  doc: ResumeDocument,
  presentation: ResumePresentation,
  language: string,
  avatarSrc?: string,
) {
  const { template } = presentation;
  const profile = template === "profile-v1";
  const styledHeader = template === "editorial-v1" || template === "modern-v1";
  const { header, content } = linesOf(doc, language);
  const headerHtml = renderHtmlLines(header);
  const html = (styledHeader ? '<header class="resume-header">' + headerHtml + "</header>" : headerHtml) +
    renderHtmlLines(content);
  const avatar =
    displaysAvatar(presentation) && avatarSrc ? '<img class="avatar" alt="" src="' + xml(avatarSrc) + '">' : "";
  return (
    '<!doctype html><html lang="' +
    xml(language) +
    '"><head><meta charset="utf-8"><title>' +
    xml(doc.candidateName) +
    '</title><meta name="robots" content="noindex,nofollow"><meta name="viewport" content="width=device-width,initial-scale=1"><style>' +
    `
    *{box-sizing:border-box} body{margin:0;color:#18232b;background:white;font:10.5pt/1.43 Arial,"Noto Sans",sans-serif}
    article{max-width:820px;margin:auto;overflow-wrap:anywhere} h1,h2,h3{break-after:avoid;line-height:1.18}
    h1{font:${profile ? "bold 30pt Georgia,serif" : "bold 24pt Arial,sans-serif"};margin:0 0 5pt}
    h2{font-size:14pt;margin:15pt 0 5pt;clear:both;color:${profile ? "#225e63" : "#273441"}}
    h3{font-size:11.5pt;margin:9pt 0 3pt} p,li{white-space:pre-wrap;orphans:2;widows:2}p{margin:3pt 0}
    .Subtitle{font-size:13pt}.Contact{color:#475966;font-size:9.5pt}ul{margin:4pt 0;padding-inline-start:18pt}
    .avatar{width:64pt;height:64pt;object-fit:cover;float:right;margin:0 0 10pt 15pt}a{color:#16545a}
    @media screen{article{padding:clamp(16px,4vw,44px)}}` +
    (styledHeader ? templateStyles[template] : "") +
    "</style></head><body><article>" +
    avatar +
    html +
    "</article></body></html>"
  );
}

const namespace = "http://schemas.openxmlformats.org";
const word = namespace + "/wordprocessingml/2006/main";
const rel = namespace + "/officeDocument/2006/relationships";
const declaration = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>';
const paragraphRule = (color: string, size: number, space: number) =>
  `<w:pBdr><w:bottom w:val="single" w:sz="${size}" w:space="${space}" w:color="${color}"/></w:pBdr>`;

export function renderResumeDocx(
  doc: ResumeDocument,
  p: ResumePresentation,
  language: string,
  avatar?: Uint8Array,
): Uint8Array {
  const profile = p.template === "profile-v1";
  const editorial = p.template === "editorial-v1";
  const modern = p.template === "modern-v1";
  const files: Record<string, Uint8Array> = {};
  const put = (path: string, content: string) => {
    files[path] = strToU8(declaration + content);
  };
  const relationships: string[] = [];
  const addRelationship = (type: string, target: string, external = false) => {
    const id = "rId" + (relationships.length + 1);
    relationships.push(
      '<Relationship Id="' +
        id +
        '" Type="' +
        rel +
        "/" +
        type +
        '" Target="' +
        xml(target) +
        '"' +
        (external ? ' TargetMode="External"' : "") +
        "/>",
    );
    return id;
  };
  const rels = (entries: string[]) =>
    '<Relationships xmlns="' + namespace + '/package/2006/relationships">' + entries.join("") + "</Relationships>";
  addRelationship("styles", "styles.xml");
  addRelationship("numbering", "numbering.xml");
  let body = "";
  if (displaysAvatar(p) && avatar) {
    files["word/media/avatar.jpg"] = avatar;
    const id = addRelationship("image", "media/avatar.jpg");
    body += `<w:p><w:r><w:drawing><wp:inline xmlns:wp="${namespace}/drawingml/2006/wordprocessingDrawing"><wp:extent cx="812800" cy="812800"/><wp:docPr id="1" name="Avatar"/><a:graphic xmlns:a="${namespace}/drawingml/2006/main"><a:graphicData uri="${namespace}/drawingml/2006/picture"><pic:pic xmlns:pic="${namespace}/drawingml/2006/picture"><pic:nvPicPr><pic:cNvPr id="0" name="Avatar"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="${id}"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="812800" cy="812800"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>`;
  }
  const { header, content } = linesOf(doc, language);
  function paragraph(line: Line, inHeader = false) {
    const styledHeader = inHeader && (editorial || modern);
    const style = styledHeader && line.style === "Contact" ? "HeaderContact" : line.style;
    const lastHeaderLine = inHeader && line === header.at(-1);
    const linkColor = styledHeader ? (modern ? "D4F3EE" : "67364F") : "16545A";
    const bidi = /^[^\p{L}]*[\p{Script=Hebrew}\p{Script=Arabic}]/u.test(line.text);
    const text = line.text
      .split(/\r\n?|\n/)
      .map((s) => '<w:t xml:space="preserve">' + xml(s) + "</w:t>")
      .join("<w:br/>");
    const run =
      "<w:r><w:rPr>" +
      (line.href ? `<w:color w:val="${linkColor}"/><w:u w:val="single"/>` : "") +
      (bidi ? "<w:rtl/>" : "") +
      "</w:rPr>" +
      text +
      "</w:r>";
    return (
      '<w:p><w:pPr><w:pStyle w:val="' +
      style +
      '"/>' +
      (styledHeader && !lastHeaderLine ? "<w:keepNext/>" : "") +
      (line.style === "Bullet" ? '<w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr>' : "") +
      (editorial && lastHeaderLine ? paragraphRule("B88FA6", 8, 8) : "") +
      (bidi ? "<w:bidi/>" : "") +
      "</w:pPr>" +
      (line.href
        ? '<w:hyperlink r:id="' + addRelationship("hyperlink", line.href, true) + '">' + run + "</w:hyperlink>"
        : run) +
      "</w:p>"
    );
  }
  const sizes = p.paperSize === "A4" ? [11906, 16838] : [12240, 15840];
  const headerBody = header.map((line) => paragraph(line, true)).join("");
  if (modern) {
    const width = sizes[0] - 2040;
    body +=
      '<w:tbl><w:tblPr><w:tblW w:w="5000" w:type="pct"/><w:tblCellMar>' +
      '<w:top w:w="300" w:type="dxa"/><w:left w:w="340" w:type="dxa"/>' +
      '<w:bottom w:w="300" w:type="dxa"/><w:right w:w="340" w:type="dxa"/>' +
      `</w:tblCellMar></w:tblPr><w:tblGrid><w:gridCol w:w="${width}"/></w:tblGrid>` +
      `<w:tr><w:tc><w:tcPr><w:tcW w:w="${width}" w:type="dxa"/><w:shd w:val="clear" w:fill="173047"/></w:tcPr>` +
      headerBody +
      '</w:tc></w:tr></w:tbl>';
  } else {
    body += headerBody;
  }
  body += content.map((line) => paragraph(line)).join("");
  body +=
    '<w:sectPr><w:pgSz w:w="' +
    sizes[0] +
    '" w:h="' +
    sizes[1] +
    '"/><w:pgMar w:top="1020" w:bottom="1020" w:left="1020" w:right="1020"/></w:sectPr>';
  put(
    "word/document.xml",
    '<w:document xmlns:w="' + word + '" xmlns:r="' + rel + '"><w:body>' + body + "</w:body></w:document>",
  );
  const styles: [Line["style"] | "HeaderContact", number, number][] = [
    ["Normal", 21, 0],
    ["Title", editorial ? 62 : profile || modern ? 60 : 48, 0],
    ["Subtitle", 26, 0],
    ["Contact", 19, 0],
    ["Heading1", editorial ? 30 : 28, 280],
    ["Heading2", 23, 150],
    ["Bullet", 21, 0],
  ];
  if (editorial || modern) styles.push(["HeaderContact", 19, 0]);
  put(
    "word/styles.xml",
    '<w:styles xmlns:w="' +
      word +
      '">' +
      styles
        .map(([name, sz, before]) => {
          const heading = name.startsWith("Heading");
          const header = name === "Title" || name === "Subtitle" || name === "HeaderContact";
          const font = (profile && name === "Title") || (editorial && (name === "Title" || name === "Heading1"))
            ? "Georgia"
            : "Arial";
          let color = profile && heading ? "225E63" : "18232B";
          if (editorial && (name === "Title" || name === "Heading1")) color = "67364F";
          if (modern && header) color = name === "Title" ? "FFFFFF" : "D4F3EE";
          if (modern && name === "Heading1") color = "17665F";
          const alignment = editorial && header ? '<w:jc w:val="center"/>' : modern && header ? '<w:jc w:val="left"/>' : "";
          return (
            '<w:style w:type="paragraph" w:styleId="' +
            name +
            '"' +
            (name === "Normal" ? ' w:default="1"' : "") +
            '><w:name w:val="' +
            (heading ? "heading " + name.at(-1) : name) +
            '"/><w:pPr>' +
            (heading ? "<w:keepNext/>" : "") +
            (modern && name === "Heading1" ? paragraphRule("B9DCD7", 6, 3) : "") +
            '<w:spacing w:before="' +
            before +
            '" w:after="55"/>' +
            alignment +
            (heading ? '<w:outlineLvl w:val="' + (name === "Heading1" ? 0 : 1) + '"/>' : "") +
            '</w:pPr><w:rPr><w:rFonts w:ascii="' +
            font +
            '"' +
            (editorial || modern ? ` w:hAnsi="${font}"` : "") +
            '/>' +
            (heading || name === "Title" ? "<w:b/>" : "") +
            '<w:color w:val="' +
            color +
            '"/><w:sz w:val="' +
            sz +
            '"/><w:szCs w:val="' +
            sz +
            '"/><w:lang w:val="' +
            xml(language) +
            '"/></w:rPr></w:style>'
          );
        })
        .join("") +
      "</w:styles>",
  );
  put(
    "word/numbering.xml",
    '<w:numbering xmlns:w="' +
      word +
      '"><w:abstractNum w:abstractNumId="1"><w:multiLevelType w:val="singleLevel"/><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="•"/><w:pPr><w:ind w:left="360" w:hanging="180"/></w:pPr></w:lvl></w:abstractNum><w:num w:numId="1"><w:abstractNumId w:val="1"/></w:num></w:numbering>',
  );
  put("word/_rels/document.xml.rels", rels(relationships));
  put("_rels/.rels", rels(['<Relationship Id="rId1" Type="' + rel + '/officeDocument" Target="word/document.xml"/>']));
  put(
    "[Content_Types].xml",
    '<Types xmlns="' +
      namespace +
      '/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="jpg" ContentType="image/jpeg"/>' +
      ["document", "styles", "numbering"]
        .map(
          (n) =>
            '<Override PartName="/word/' +
            n +
            '.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.' +
            (n === "document" ? "document.main" : n) +
            '+xml"/>',
        )
        .join("") +
      "</Types>",
  );
  return zipSync(files);
}
