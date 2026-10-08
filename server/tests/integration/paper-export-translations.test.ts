import { inflateRawSync } from "node:zlib";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as papersRoute from "@/app/api/v1/papers/route";
import * as paperRoute from "@/app/api/v1/papers/[id]/route";
import * as exportRoute from "@/app/api/v1/papers/[id]/export/route";
import * as translationsRoute from "@/app/api/v1/papers/[id]/translations/route";
import * as pdfRoute from "@/app/api/v1/papers/[id]/pdf/route";
import * as renderingRoute from "@/app/api/v1/papers/[id]/rendering/route";
import type { PaperJson } from "@/lib/services/papers";
import { apiRequest, params, setupTestEnv, type TestEnv } from "../helpers/setup";

let env: TestEnv;
beforeEach(async () => { env = await setupTestEnv(); vi.stubEnv("SUMMARY_OG_REMOTE_ASSETS", "false"); });
afterEach(() => { env.teardown(); vi.unstubAllEnvs(); });

async function create(): Promise<PaperJson> {
  const response = await papersRoute.POST(apiRequest("POST", "/api/v1/papers", { token: env.tokens.alice, body: { title: "Motion", files: [
    { path: "main.tex", content: String.raw`\documentclass{article}
\title{Motion}
\begin{document}
\maketitle
\input{sections/results}
\end{document}` },
    { path: "sections/results.tex", content: String.raw`\section{Results}
Energy is conserved. $E=mc^2$.
\begin{tabular}{ll}Name & Value\\Energy & 2\end{tabular}` },
  ], mainFile: "main.tex" } }));
  expect(response.status).toBe(201);
  return (await response.json()).paper;
}

function exportFile(id: string, query = "", token = env.tokens.alice) {
  return exportRoute.GET(apiRequest("GET", `/api/v1/papers/${id}/export${query}`, { token }), params({ id }));
}
function translate(id: string, language: string | null, token = env.tokens.alice) {
  return translationsRoute.POST(apiRequest("POST", `/api/v1/papers/${id}/translations`, { token, body: { language } }), params({ id }));
}
function translations(id: string) {
  return translationsRoute.GET(apiRequest("GET", `/api/v1/papers/${id}/translations`, { token: env.tokens.alice }), params({ id }));
}

/** Read the actual DOCX's ZIP directory, including deflated XML (no converter mock). */
function zipEntry(bytes: Uint8Array, name: string): string {
  const zip = Buffer.from(bytes);
  for (let offset = 0; offset + 46 < zip.length; offset++) {
    if (zip.readUInt32LE(offset) !== 0x02014b50) continue;
    const nameLength = zip.readUInt16LE(offset + 28);
    if (zip.subarray(offset + 46, offset + 46 + nameLength).toString() !== name) continue;
    const local = zip.readUInt32LE(offset + 42);
    const start = local + 30 + zip.readUInt16LE(local + 26) + zip.readUInt16LE(local + 28);
    const compressed = zip.subarray(start, start + zip.readUInt32LE(offset + 20));
    return (zip.readUInt16LE(offset + 10) === 8 ? inflateRawSync(compressed) : compressed).toString();
  }
  throw new Error(`Missing ZIP entry ${name}`);
}

describe("paper export and translations", () => {
  it("exports real editable Word headings, tables and equations from included files", async () => {
    const paper = await create();
    const response = await exportFile(paper.id, "?format=docx&lang=original");
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toContain("wordprocessingml.document");
    expect(response.headers.get("content-disposition")).toContain("Motion.docx");
    expect(response.headers.get("cache-control")).toBe("no-store");
    const xml = zipEntry(new Uint8Array(await response.arrayBuffer()), "word/document.xml");
    expect(xml).toContain("Results");
    expect(xml).toContain("Energy is conserved.");
    expect(xml).toContain("w:tbl");
    expect(xml).toContain("m:oMath");
    expect(xml).toContain("Heading1");
    expect(env.ai.calls.translateStrings).toHaveLength(0);
  });

  it("saves translations separately, reuses prose and marks them outdated after an edit", async () => {
    const original = await create();
    const response = await translate(original.id, "ja");
    expect(response.status).toBe(200);
    const translated: PaperJson = (await response.json()).paper;
    expect(translated).toMatchObject({ language: "ja", originalLanguage: "en", displayLanguage: "ja", translationOutdated: false, revision: 0 });
    expect(translated.files[1].content).toContain("[ja] Energy is conserved.");
    expect(translated.files[1].content).toContain("$E=mc^2$");
    expect((await (await translations(original.id)).json()).items).toMatchObject([{ language: "ja", upToDate: true }]);
    expect((await translate(original.id, "ja")).status).toBe(200);
    expect(env.ai.calls.translateStrings).toHaveLength(1);
    const changedFiles = original.files.map((file) => ({ ...file, content: file.content.replace("Energy is conserved.", "Energy changes.") }));
    const save = await paperRoute.PUT(apiRequest("PUT", `/api/v1/papers/${original.id}`, { token: env.tokens.alice, body: { title: original.title, files: changedFiles, mainFile: original.mainFile, compiler: original.compiler, revision: original.revision } }), params({ id: original.id }));
    expect(save.status).toBe(200);
    expect((await (await translations(original.id)).json()).items).toMatchObject([{ language: "ja", upToDate: false }]);
    const reading = await paperRoute.GET(apiRequest("GET", `/api/v1/papers/${original.id}`, { token: env.tokens.alice }), params({ id: original.id }));
    expect((await reading.json()).paper.translationOutdated).toBe(true);
    expect((await exportFile(original.id, "?format=pdf&lang=ja")).status).toBe(409);
    expect((await exportFile(original.id, "?format=docx&lang=ja")).status).toBe(409);
    expect((await translate(original.id, "ja")).status).toBe(200);
    expect(env.ai.calls.translateStrings.at(-1)?.texts).toEqual(["Energy changes."]);
    expect((await (await translations(original.id)).json()).items[0].upToDate).toBe(true);
    const restored = await translate(original.id, null);
    expect((await restored.json()).paper.files).toEqual(changedFiles);
  });

  it("obeys explicit and selected languages in both formats and the PDF preview", async () => {
    const paper = await create();
    expect((await translate(paper.id, "zh-Hant")).status).toBe(200);
    const pdf = await exportFile(paper.id, "?format=pdf&lang=zh-Hant");
    expect(pdf.status).toBe(200);
    expect(pdf.headers.get("content-language")).toBe("zh-Hant");
    expect(env.latex.calls.at(-1)?.project.files[1].content).toContain("[zh-Hant]");
    expect(env.latex.calls.at(-1)?.project.compiler).toBe("xelatex");
    expect((await pdfRoute.GET(apiRequest("GET", `/api/v1/papers/${paper.id}/pdf`, { token: env.tokens.alice }), params({ id: paper.id }))).status).toBe(200);
    expect(env.latex.calls.at(-1)?.project.files[1].content).toContain("[zh-Hant]");
    const word = await exportFile(paper.id, "?format=docx");
    expect(word.status).toBe(200);
    const xml = zipEntry(new Uint8Array(await word.arrayBuffer()), "word/document.xml");
    expect(xml).toContain("[zh-Hant]");
    expect((await exportFile(paper.id, "?format=pdf&lang=original")).status).toBe(200);
    expect(env.latex.calls.at(-1)?.project.files[1].content).not.toContain("[zh-Hant]");
  });

  it("validates choices and preserves private paper and owner-only version access", async () => {
    const paper = await create();
    for (const query of ["?format=exe", "?lang=unknown", "?version=0", "?version="]) expect((await exportFile(paper.id, query)).status).toBe(400);
    expect((await exportFile(paper.id, "?format=docx", env.tokens.bob)).status).toBe(404);
    expect((await translate(paper.id, "fr", env.tokens.bob)).status).toBe(404);
    expect((await exportFile(paper.id, "?format=docx&version=1&lang=original")).status).toBe(200);
    expect((await exportFile(paper.id, "?format=pdf&version=99")).status).toBe(404);
    expect((await exportFile(paper.id, "?format=pdf&lang=fr")).status).toBe(409);
    expect(env.ai.calls.translateStrings).toHaveLength(0);
  });

  it("does not select or export a failed translation and allows retry", async () => {
    const paper = await create();
    env.ai.translates = false;
    expect((await translate(paper.id, "fr")).status).toBe(502);
    const reading = await paperRoute.GET(apiRequest("GET", `/api/v1/papers/${paper.id}`, { token: env.tokens.alice }), params({ id: paper.id }));
    expect((await reading.json()).paper.displayLanguage).toBeNull();
    expect((await exportFile(paper.id, "?lang=fr")).status).toBe(409);
    env.ai.translates = true;
    expect((await translate(paper.id, "fr")).status).toBe(200);
  });

  it("saves layout separately, refreshes the PDF cache and styles editable Word output", async () => {
    const paper = await create();
    expect((await exportFile(paper.id, "?lang=original")).status).toBe(200);
    const calls = env.latex.calls.length;
    expect((await translate(paper.id, "fr")).status).toBe(200);
    const style = { enabled: true, columns: 2, pageSize: "letter", orientation: "landscape", marginLeft: 18, fontFamily: "sans", fontSize: 13, lineSpacing: 1.5, headingColor: "0F766E", sectionNumbers: false, tableOfContents: true, titlePage: true, pageNumbers: "header-right", headerText: "Draft & review", footerText: "Research" };
    const result = await renderingRoute.PUT(apiRequest("PUT", `/api/v1/papers/${paper.id}/rendering`, { token: env.tokens.alice, body: style }), params({ id: paper.id }));
    expect(result.status).toBe(200);
    const fresh = (await result.json()).paper;
    expect(fresh.revision).toBe(paper.revision);
    expect(fresh.renderingOptions).toMatchObject(style);
    expect(fresh.translationOutdated).toBe(false);
    expect((await (await translations(paper.id)).json()).items[0].upToDate).toBe(true);
    expect((await exportFile(paper.id, "?lang=original")).status).toBe(200);
    expect(env.latex.calls.length).toBe(calls + 1);
    const project = env.latex.calls.at(-1)!.project;
    expect(project.compiler).toBe("xelatex");
    expect(project.files[0].content).toContain("\\twocolumn");
    expect(project.files[0].content).toContain("left=18mm");
    expect(project.files[0].content).toContain("\\tableofcontents");
    expect(project.files[0].content).toContain("Draft \\& review");
    expect(project.files[0].content).toContain("\\makeatletter\\let\\ps@plain\\ps@fancy\\makeatother");
    expect((await exportFile(paper.id, "?lang=original")).status).toBe(200);
    expect(env.latex.calls.length).toBe(calls + 1);
    const word = await exportFile(paper.id, "?format=docx&lang=fr");
    expect(word.status).toBe(200);
    const bytes = new Uint8Array(await word.arrayBuffer());
    const xml = zipEntry(bytes, "word/document.xml");
    expect(xml).toContain('[fr] Results');
    expect(xml).toContain('<w:cols w:num="2"');
    expect(xml).toContain('w:orient="landscape"');
    expect(xml).toContain('w:val="nextPage"');
    expect(xml).toContain('TOC');
    const styles = zipEntry(bytes, "word/styles.xml");
    expect(styles).toContain('w:ascii="Arial"');
    expect(styles).toContain('w:line="360"');
    expect(styles).toContain('w:color w:val="0F766E"');
    const header = zipEntry(bytes, "word/chippy-header.xml");
    expect(header).toContain('Draft &amp; review');
    expect(header).toContain('w:instr="PAGE"');
    const original = await paperRoute.GET(apiRequest("GET", `/api/v1/papers/${paper.id}?lang=original`, { token: env.tokens.alice }), params({ id: paper.id }));
    expect((await original.json()).paper.files).toEqual(paper.files);
  });

  it("validates and authorizes styles and allows temporary export overrides", async () => {
    const paper = await create();
    const render = (body: unknown, token = env.tokens.alice) => renderingRoute.PUT(apiRequest("PUT", `/api/v1/papers/${paper.id}/rendering`, { token, body }), params({ id: paper.id }));
    expect((await render({ enabled: true, columns: 99 })).status).toBe(400);
    expect((await render({ fontSize: 0 })).status).toBe(400);
    expect((await render({ headerText: "x".repeat(161) })).status).toBe(400);
    expect((await render({ enabled: true }, env.tokens.bob)).status).toBe(404);
    const response = await exportRoute.POST(apiRequest("POST", `/api/v1/papers/${paper.id}/export`, { token: env.tokens.alice, body: { format: "pdf", lang: "original", rendering: { enabled: true, columns: 2 } } }), params({ id: paper.id }));
    expect(response.status).toBe(200);
    expect(env.latex.calls.at(-1)?.project.files[0].content).toContain("\\twocolumn");
    const reading = await paperRoute.GET(apiRequest("GET", `/api/v1/papers/${paper.id}`, { token: env.tokens.alice }), params({ id: paper.id }));
    expect((await reading.json()).paper.renderingOptions.enabled).toBe(false);
  });
});
