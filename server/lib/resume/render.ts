import { zipSync, strToU8 } from "fflate";
import { z } from "zod";
import type { ResumeDocument } from "@/lib/contracts/resume";

export const RESUME_TEMPLATES = [
  { id: "compact-v1", name: "Compact", version: 1 },
  { id: "profile-v1", name: "Profile", version: 1 },
] as const;

export const presentationSchema = z
  .object({
    template: z.enum(["compact-v1", "profile-v1"]).default("compact-v1"),
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
  return lines;
}
export function displaysAvatar(p: ResumePresentation) {
  return p.template === "profile-v1" && p.showAvatar;
}

export function renderResumeHtml(
  doc: ResumeDocument,
  presentation: ResumePresentation,
  language: string,
  avatarSrc?: string,
) {
  const profile = presentation.template === "profile-v1";
  let html = "",
    list = false;
  for (const line of linesOf(doc, language)) {
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

export function renderResumeDocx(
  doc: ResumeDocument,
  p: ResumePresentation,
  language: string,
  avatar?: Uint8Array,
): Uint8Array {
  const profile = p.template === "profile-v1";
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
  for (const line of linesOf(doc, language)) {
    const bidi = /^[^\p{L}]*[\p{Script=Hebrew}\p{Script=Arabic}]/u.test(line.text);
    const text = line.text
      .split(/\r\n?|\n/)
      .map((s) => '<w:t xml:space="preserve">' + xml(s) + "</w:t>")
      .join("<w:br/>");
    const run =
      "<w:r><w:rPr>" +
      (line.href ? '<w:color w:val="16545A"/><w:u w:val="single"/>' : "") +
      (bidi ? "<w:rtl/>" : "") +
      "</w:rPr>" +
      text +
      "</w:r>";
    body +=
      '<w:p><w:pPr><w:pStyle w:val="' +
      line.style +
      '"/>' +
      (line.style === "Bullet" ? '<w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr>' : "") +
      (bidi ? "<w:bidi/>" : "") +
      "</w:pPr>" +
      (line.href
        ? '<w:hyperlink r:id="' + addRelationship("hyperlink", line.href, true) + '">' + run + "</w:hyperlink>"
        : run) +
      "</w:p>";
  }
  const sizes = p.paperSize === "A4" ? [11906, 16838] : [12240, 15840];
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
  const styles = [
    ["Normal", 21, 0],
    ["Title", profile ? 60 : 48, 0],
    ["Subtitle", 26, 0],
    ["Contact", 19, 0],
    ["Heading1", 28, 280],
    ["Heading2", 23, 150],
    ["Bullet", 21, 0],
  ] as const;
  put(
    "word/styles.xml",
    '<w:styles xmlns:w="' +
      word +
      '">' +
      styles
        .map(([name, sz, before]) => {
          const heading = name.startsWith("Heading");
          return (
            '<w:style w:type="paragraph" w:styleId="' +
            name +
            '"' +
            (name === "Normal" ? ' w:default="1"' : "") +
            '><w:name w:val="' +
            (heading ? "heading " + name.at(-1) : name) +
            '"/><w:pPr>' +
            (heading ? "<w:keepNext/>" : "") +
            '<w:spacing w:before="' +
            before +
            '" w:after="55"/>' +
            (heading ? '<w:outlineLvl w:val="' + (name === "Heading1" ? 0 : 1) + '"/>' : "") +
            '</w:pPr><w:rPr><w:rFonts w:ascii="' +
            (profile && name === "Title" ? "Georgia" : "Arial") +
            '"/>' +
            (heading || name === "Title" ? "<w:b/>" : "") +
            '<w:color w:val="' +
            (profile && heading ? "225E63" : "18232B") +
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
