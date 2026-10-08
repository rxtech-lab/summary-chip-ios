import { eq } from "drizzle-orm";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as apiKeysRoute from "@/app/api/v1/api-keys/route";
import * as mcpRoute from "@/app/api/mcp/route";
import * as papersRoute from "@/app/api/v1/papers/route";
import * as paperRoute from "@/app/api/v1/papers/[id]/route";
import * as commitRoute from "@/app/api/v1/papers/[id]/versions/route";
import * as pdfRoute from "@/app/api/v1/papers/[id]/pdf/route";
import * as checkRoute from "@/app/api/v1/papers/[id]/check/route";
import * as publicPdfRoute from "@/app/s/[slug]/paper.pdf/route";
import * as summariesRoute from "@/app/api/v1/summaries/route";
import * as versionsRoute from "@/app/api/v1/summaries/[id]/versions/route";
import * as versionRoute from "@/app/api/v1/summaries/[id]/versions/[version]/route";
import * as restoreRoute from "@/app/api/v1/summaries/[id]/versions/[version]/restore/route";
import type { PaperFile } from "@/lib/contracts/paper";
import { papers } from "@/lib/db/schema";
import type { PaperJson } from "@/lib/services/papers";
import type { VersionJson } from "@/lib/services/versions";
import { apiRequest, params, setupTestEnv, type TestEnv } from "../helpers/setup";

let env: TestEnv;

beforeEach(async () => {
  env = await setupTestEnv();
  vi.stubEnv("SUMMARY_OG_REMOTE_ASSETS", "false");
});

afterEach(() => {
  env.teardown();
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
});

async function createPaper(body: Record<string, unknown> = { title: "Quantum Gears" }, token = env.tokens.alice): Promise<PaperJson> {
  const response = await papersRoute.POST(apiRequest("POST", "/api/v1/papers", { token, body }));
  expect(response.status).toBe(201);
  return (await response.json()).paper;
}

function autosave(paper: PaperJson, changes: Partial<Pick<PaperJson, "title" | "files" | "mainFile" | "compiler" | "revision">>, token = env.tokens.alice) {
  const body = { title: paper.title, files: paper.files, mainFile: paper.mainFile, compiler: paper.compiler, revision: paper.revision, ...changes };
  return paperRoute.PUT(apiRequest("PUT", `/api/v1/papers/${paper.id}`, { token, body }), params({ id: paper.id }));
}

async function commit(id: string, token = env.tokens.alice): Promise<{ paper: PaperJson; version: number | null }> {
  const response = await commitRoute.POST(apiRequest("POST", `/api/v1/papers/${id}/versions`, { token }), params({ id }));
  expect(response.status).toBe(200);
  return response.json();
}

async function versions(id: string): Promise<VersionJson[]> {
  const response = await versionsRoute.GET(apiRequest("GET", `/api/v1/summaries/${id}/versions`, { token: env.tokens.alice }), params({ id }));
  expect(response.status).toBe(200);
  return (await response.json()).items;
}

function pdf(id: string, query = "", token = env.tokens.alice) {
  return pdfRoute.GET(apiRequest("GET", `/api/v1/papers/${id}/pdf${query}`, { token }), params({ id }));
}

function withFile(files: PaperFile[], path: string, content: string): PaperFile[] {
  return files.some((file) => file.path === path) ? files.map((file) => (file.path === path ? { path, content } : file)) : [...files, { path, content }];
}

let rpcId = 0;

async function mcpKey() {
  const response = await apiKeysRoute.POST(apiRequest("POST", "/api/v1/api-keys", { token: env.tokens.alice, body: { name: "Agent" } }));
  return ((await response.json()) as { key: string }).key;
}

async function callTool(key: string, name: string, args: Record<string, unknown>) {
  const response = await mcpRoute.POST(apiRequest("POST", "/api/mcp", {
    token: key,
    headers: { accept: "application/json, text/event-stream" },
    body: { jsonrpc: "2.0", id: ++rpcId, method: "tools/call", params: { name, arguments: args } },
  }));
  expect(response.status).toBe(200);
  return (await response.json()).result as { isError?: boolean; content: { text: string }[]; structuredContent?: Record<string, unknown> };
}

describe("papers", () => {
  it("creates a paper from a template as version 1 in the library", async () => {
    const paper = await createPaper({ title: "Quantum Gears", template: "article" });
    expect(paper).toMatchObject({ title: "Quantum Gears", mainFile: "main.tex", compiler: "pdflatex", revision: 0, version: 1, hasUnversionedChanges: false, visibility: "private" });
    expect(paper.files.map((file) => file.path)).toEqual(["main.tex", "sections/introduction.tex", "references.bib"]);
    expect(paper.files[0].content).toContain("\\title{Quantum Gears}");

    const library = await (await summariesRoute.GET(apiRequest("GET", "/api/v1/summaries?kind=paper", { token: env.tokens.alice }))).json();
    expect(library.items.map((item: { id: string; kind: string }) => [item.id, item.kind])).toEqual([[paper.id, "paper"]]);
    expect(await versions(paper.id)).toMatchObject([{ version: 1, kind: "paper", actor: "owner", title: "Quantum Gears", isCurrent: true }]);
  });

  it("autosaves without versions and saves one version when the editor closes", async () => {
    const created = await createPaper();
    const first = await autosave(created, { files: withFile(created.files, "sections/introduction.tex", "\\section{Introduction}\nDraft one.") });
    expect(first.status).toBe(200);
    const saved: PaperJson = (await first.json()).paper;
    expect(saved).toMatchObject({ revision: 1, version: 1, hasUnversionedChanges: true });
    const second: PaperJson = (await (await autosave(saved, { files: withFile(saved.files, "sections/introduction.tex", "\\section{Introduction}\nDraft two.") })).json()).paper;
    expect(second.revision).toBe(2);
    expect(await versions(created.id)).toHaveLength(1);

    const closed = await commit(created.id);
    expect(closed.version).toBe(2);
    expect(closed.paper).toMatchObject({ version: 2, hasUnversionedChanges: false });
    expect((await versions(created.id))[0]).toMatchObject({ version: 2, actor: "owner" });
    // Leaving again without edits adds nothing.
    expect((await commit(created.id)).version).toBeNull();

    const v2 = await (await versionRoute.GET(apiRequest("GET", `/api/v1/summaries/${created.id}/versions/2`, { token: env.tokens.alice }), params({ id: created.id, version: "2" }))).json();
    expect(v2.content.files.find((file: PaperFile) => file.path === "sections/introduction.tex").content).toContain("Draft two.");
  });

  it("an edit that undoes itself before leaving adds no version", async () => {
    const created = await createPaper();
    const edited: PaperJson = (await (await autosave(created, { files: withFile(created.files, "main.tex", "\\documentclass{article}\\begin{document}x\\end{document}") })).json()).paper;
    await autosave(edited, { files: created.files });
    expect((await commit(created.id)).version).toBeNull();
    expect(await versions(created.id)).toHaveLength(1);
  });

  it("refuses an autosave made on an older revision", async () => {
    const created = await createPaper();
    await autosave(created, { title: "Renamed" });
    const stale = await autosave(created, { title: "Stale" });
    expect(stale.status).toBe(409);
    expect((await stale.json()).error).toMatchObject({ code: "PAPER_REVISION_CONFLICT", details: { revision: 1 } });
  });

  it("only the owner edits; others can't open a private paper", async () => {
    const created = await createPaper();
    expect((await autosave(created, { title: "Bob's" }, env.tokens.bob)).status).toBe(404);
    expect((await paperRoute.GET(apiRequest("GET", `/api/v1/papers/${created.id}`, { token: env.tokens.bob }), params({ id: created.id }))).status).toBe(404);
    expect((await pdf(created.id, "", env.tokens.bob)).status).toBe(404);
  });

  it("compiles the working copy once per source and reports LaTeX errors", async () => {
    const created = await createPaper();
    const first = await pdf(created.id);
    expect(first.status).toBe(200);
    expect(first.headers.get("content-type")).toBe("application/pdf");
    expect(first.headers.get("x-paper-revision")).toBe("0");
    expect(new TextDecoder().decode((await first.arrayBuffer()).slice(0, 5) as ArrayBuffer)).toBe("%PDF-");
    expect((await pdf(created.id)).status).toBe(200);
    expect(env.latex.calls).toHaveLength(1);
    expect(env.latex.calls[0].options.strict).toBe(false);
    const [row] = await env.handle.db.select().from(papers).where(eq(papers.summaryId, created.id));
    expect(await env.store.head(row.pdfKey!)).not.toBeNull();

    const broken = await autosave(created, { files: withFile(created.files, "sections/introduction.tex", "\\section{Intro}\n\\undefinedcommand") });
    expect(broken.status).toBe(200);
    const failed = await pdf(created.id);
    expect(failed.status).toBe(422);
    const error = (await failed.json()).error;
    expect(error.code).toBe("LATEX_COMPILE_FAILED");
    expect(error.details.errors).toEqual([{ file: "sections/introduction.tex", line: 2, message: "Undefined control sequence." }]);

    const check = await checkRoute.POST(apiRequest("POST", `/api/v1/papers/${created.id}/check`, { token: env.tokens.alice }), params({ id: created.id }));
    expect(await check.json()).toMatchObject({ ok: false, revision: 1, errors: [{ file: "sections/introduction.tex", line: 2 }] });
    expect(env.latex.calls.at(-1)?.options.strict).toBe(true);

    // A saved version compiles on its own, for the owner only.
    expect((await pdf(created.id, "?version=1")).status).toBe(200);
    expect((await pdf(created.id, "?version=9")).status).toBe(404);
    expect((await pdf(created.id, "?version=zero")).status).toBe(400);
  });

  it("restores a version, saving pending manual edits first", async () => {
    const created = await createPaper();
    await autosave(created, { title: "Draft title" });
    const response = await restoreRoute.POST(apiRequest("POST", `/api/v1/summaries/${created.id}/versions/1/restore`, { token: env.tokens.alice }), params({ id: created.id, version: "1" }));
    expect(response.status).toBe(200);
    const restored = await response.json();
    expect(restored.paper).toMatchObject({ title: "Quantum Gears", version: 3, hasUnversionedChanges: false });
    expect(restored.version).toMatchObject({ version: 3, actor: "restore", restoredFrom: 1 });
    expect((await versions(created.id)).map((item) => [item.version, item.actor, item.title])).toEqual([
      [3, "restore", "Quantum Gears"], [2, "owner", "Draft title"], [1, "owner", "Quantum Gears"],
    ]);
  });

  it("serves a public paper's PDF from its share link", async () => {
    const created = await createPaper({ title: "Open Gears", visibility: "public" });
    const response = await publicPdfRoute.GET(new Request(`http://localhost/s/${created.slug}/paper.pdf`), params({ slug: created.slug }));
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("application/pdf");
    const hidden = await createPaper({ title: "Hidden Gears" });
    expect((await publicPdfRoute.GET(new Request(`http://localhost/s/${hidden.slug}/paper.pdf`), params({ slug: hidden.slug }))).status).toBe(404);
  });

  it("deletes the paper with its PDF", async () => {
    const created = await createPaper();
    await pdf(created.id);
    const [row] = await env.handle.db.select().from(papers).where(eq(papers.summaryId, created.id));
    const response = await paperRoute.DELETE(apiRequest("DELETE", `/api/v1/papers/${created.id}`, { token: env.tokens.alice }), params({ id: created.id }));
    expect(response.status).toBe(204);
    expect(await env.store.head(row.pdfKey!)).toBeNull();
    expect(await env.handle.db.select().from(papers)).toHaveLength(0);
  });
});

describe("paper MCP tools", () => {
  it("adds an image through create_upload and write_file without inline image bytes", async () => {
    const key = await mcpKey();
    const bytes = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=", "base64");
    const upload = await callTool(key, "create_upload", { filename: "figure.png", mimeType: "image/png", byteSize: bytes.length });
    expect(upload.isError).toBeFalsy();
    const uploadKey = (upload.structuredContent as { key: string }).key;
    await env.store.put(uploadKey, { bytes, contentType: "image/png" });
    const created = await callTool(key, "create_paper", { title: "Illustrated Paper", template: "blank" });
    const paperId = (created.structuredContent as { paper: { id: string } }).paper.id;
    const edited = await callTool(key, "update_paper", { paperId, operations: [{
      op: "write_file", path: "images/figure.png", asset: { key: uploadKey, mimeType: "image/png", byteSize: bytes.length },
    }] });
    expect(edited.isError).toBeFalsy();
    const asset = (edited.structuredContent as { paper: { files: PaperFile[] } }).paper.files.find((file) => file.path === "images/figure.png")!;
    expect(asset.content).toBe("");
    expect(asset.asset?.key).toContain(`papers/${paperId}/assets/`);
    expect(asset.asset?.key).not.toBe(uploadKey);
    const check = await callTool(key, "compile_paper", { paperId });
    expect(check.structuredContent).toMatchObject({ ok: true });
    expect(env.latex.calls.at(-1)?.project.assetData?.[asset.path]).toEqual(bytes);
  });

  it("creates, edits and compiles a paper; every edit is its own version", async () => {
    const key = await mcpKey();
    const created = await callTool(key, "create_paper", {
      files: [
        { path: "main.tex", content: "\\documentclass{article}\n\\title{Agent Paper}\n\\begin{document}\n\\maketitle\n\\input{intro}\n\\end{document}\n" },
        { path: "intro.tex", content: "Hello gears.\n" },
      ],
    });
    expect(created.isError).toBeFalsy();
    const paper = (created.structuredContent as { paper: { id: string; title: string; version: number } }).paper;
    expect(paper).toMatchObject({ title: "Agent Paper", version: 1 });

    const listed = await callTool(key, "list_papers", {});
    expect((listed.structuredContent as { count: number }).count).toBe(1);

    // The user edits in the app first; the agent's edit lands as its own version after theirs.
    const current: PaperJson = (await (await paperRoute.GET(apiRequest("GET", `/api/v1/papers/${paper.id}`, { token: env.tokens.alice }), params({ id: paper.id }))).json()).paper;
    await autosave(current, { files: withFile(current.files, "intro.tex", "Hello spinning gears.\n") });

    const edited = await callTool(key, "update_paper", {
      paperId: paper.id,
      operations: [{ op: "edit_file", path: "intro.tex", edits: [{ find: "spinning", replace: "quantum" }] }],
    });
    expect(edited.isError).toBeFalsy();
    expect(edited.content[0].text).toContain("version 3");
    const files = (edited.structuredContent as { paper: { files: { path: string; content?: string }[] } }).paper.files;
    expect(files.find((file) => file.path === "intro.tex")?.content).toBe("Hello quantum gears.\n");
    expect(files.find((file) => file.path === "main.tex")).toEqual({ path: "main.tex", characters: expect.any(Number) });
    expect((await versions(paper.id)).map((item) => item.actor)).toEqual(["agent", "owner", "agent"]);

    const second = await callTool(key, "update_paper", { paperId: paper.id, operations: [{ op: "write_file", path: "intro.tex", content: "\\undefinedcommand\n" }] });
    expect(second.content[0].text).toContain("version 4");
    const check = await callTool(key, "compile_paper", { paperId: paper.id });
    expect(check.structuredContent).toMatchObject({ ok: false, errors: [{ file: "intro.tex", line: 1 }] });
    expect(env.latex.calls.at(-1)?.options.strict).toBe(true);

    const failedEdit = await callTool(key, "update_paper", { paperId: paper.id, operations: [{ op: "delete_file", path: "main.tex" }] });
    expect(failedEdit.isError).toBe(true);
    expect(failedEdit.content[0].text).toContain("PAPER_EDIT_FAILED");

    const stale = await callTool(key, "update_paper", { paperId: paper.id, revision: 0, operations: [{ op: "set_title", title: "Stale" }] });
    expect(stale.content[0].text).toContain("get_paper");

    const read = await callTool(key, "get_paper", { paperId: paper.id, paths: ["intro.tex"] });
    expect((read.structuredContent as { paper: { files: unknown[] } }).paper.files).toEqual([
      { path: "main.tex", characters: expect.any(Number) },
      { path: "intro.tex", content: "\\undefinedcommand\n" },
    ]);
    expect((await callTool(key, "update_summary", { summaryId: paper.id, title: "x" })).content[0].text).toContain("update_paper");
  });
});

describe("paper references", () => {
  const FABRICATED = "\n@article{ghost2031,\n  author = {A. Nobody},\n  title = {A Fabricated Survey of Gears},\n  year = {2031}\n}\n";

  async function read(id: string): Promise<PaperJson> {
    return (await (await paperRoute.GET(apiRequest("GET", `/api/v1/papers/${id}`, { token: env.tokens.alice }), params({ id }))).json()).paper;
  }

  /** The paper once no reference is being checked any more (autosave checks run after the response). */
  async function settled(id: string): Promise<PaperJson> {
    let paper = await read(id);
    await vi.waitFor(async () => {
      paper = await read(id);
      expect(paper.references.some((reference) => reference.status === "checking")).toBe(false);
    });
    return paper;
  }

  it("checks only the entries an autosave added or changed, and flags the ones that don't hold up", async () => {
    const created = await createPaper();
    expect((await settled(created.id)).references).toMatchObject([{ key: "knuth1984", file: "references.bib", line: 1, status: "verified", issue: null }]);
    expect(env.ai.calls.checkReference.map((input) => input.key)).toEqual(["knuth1984"]);

    const bib = created.files.find((file) => file.path === "references.bib")!.content;
    const saved = await autosave(created, { files: withFile(created.files, "references.bib", bib + FABRICATED) });
    expect(saved.status).toBe(200);
    const paper = await settled(created.id);
    expect(paper.references.find((reference) => reference.key === "ghost2031")).toMatchObject({
      status: "error",
      issue: "reference_not_found",
      title: "A Fabricated Survey of Gears",
      line: 8,
      message: expect.any(String),
    });
    expect(env.ai.calls.checkReference.map((input) => input.key)).toEqual(["knuth1984", "ghost2031"]);

    // Editing the text around it isn't a reference change: nothing is checked again.
    await autosave(paper, { files: withFile(paper.files, "sections/introduction.tex", "\\section{Introduction}\nMore text \\cite{ghost2031}.\n") });
    await settled(created.id);
    expect(env.ai.calls.checkReference).toHaveLength(2);

    // Removing the entry forgets its check.
    const latest = await read(created.id);
    await autosave(latest, { files: withFile(latest.files, "references.bib", bib) });
    expect((await settled(created.id)).references.map((reference) => reference.key)).toEqual(["knuth1984"]);
  });

  it("flags a link that doesn't open", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response("Not found", { status: 404 })));
    const created = await createPaper({
      title: "Links",
      files: [
        { path: "main.tex", content: "\\documentclass{article}\n\\begin{document}\nSee \\cite{dead}.\n\\bibliography{refs}\n\\end{document}\n" },
        { path: "refs.bib", content: "@misc{dead, title = {Gear Tables}, url = {https://gears.example.com/missing}}\n" },
      ],
    });
    const [reference] = (await settled(created.id)).references;
    expect(reference).toMatchObject({ key: "dead", url: "https://gears.example.com/missing", status: "error", issue: "link_not_found" });
    expect(env.ai.calls.checkReference[0].contexts).toEqual(["See [dead]."]);
  });

  it("saves an agent's edit with a bad reference and warns it to rewrite the reference", async () => {
    const key = await mcpKey();
    const created = await callTool(key, "create_paper", { title: "Agent Paper" });
    expect(created.isError).toBeFalsy();
    expect(created.structuredContent?.warning).toBeUndefined();
    const id = (created.structuredContent as { paper: { id: string } }).paper.id;

    const edited = await callTool(key, "update_paper", {
      paperId: id,
      operations: [{ op: "edit_file", path: "references.bib", edits: [{ find: "year      = {1984}\n}", replace: `year      = {1984}\n}${FABRICATED}` }] }],
    });
    expect(edited.isError).toBeFalsy();
    expect(edited.content[0].text).toContain("version 2");
    expect(edited.content[0].text).toContain("Warning: 1 reference doesn't hold up");
    expect(edited.content[0].text).toContain("ghost2031 (references.bib:7): the work can't be found");
    expect(edited.structuredContent?.warning).toContain("rewrite it with update_paper");
    const references = (edited.structuredContent as { paper: { references: { key: string; status: string }[] } }).paper.references;
    expect(references).toEqual([
      { key: "knuth1984", file: "references.bib", line: 1, status: "verified" },
      { key: "ghost2031", file: "references.bib", line: 7, status: "error", issue: "reference_not_found", message: expect.any(String) },
    ]);
    // The edit was saved all the same.
    expect((await read(id)).files.find((file) => file.path === "references.bib")?.content).toContain("ghost2031");
  });
});
