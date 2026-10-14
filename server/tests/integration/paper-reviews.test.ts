import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as apiKeysRoute from "@/app/api/v1/api-keys/route";
import * as mcpRoute from "@/app/api/mcp/route";
import * as papersRoute from "@/app/api/v1/papers/route";
import * as paperRoute from "@/app/api/v1/papers/[id]/route";
import * as figuresRoute from "@/app/api/v1/papers/[id]/figures/route";
import * as reviewsRoute from "@/app/api/v1/papers/[id]/reviews/route";
import * as reviewRoute from "@/app/api/v1/papers/[id]/reviews/[reviewId]/route";
import * as versionsRoute from "@/app/api/v1/summaries/[id]/versions/route";
import type { PaperFile } from "@/lib/contracts/paper";
import type { PaperJson } from "@/lib/services/papers";
import type { PaperReviewJson } from "@/lib/services/paper-reviews";
import { figureDocument, figurePreamble, inlinePreambleInputs } from "@/lib/services/paper-figures";
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
});

const MAIN = "\\documentclass{article}\n\\usepackage{tikz}\n\\usetikzlibrary{arrows}\n\\usepackage{geometry}\n\\title{Gears}\n\\begin{document}\n\\maketitle\n\\input{intro}\n\\end{document}\n";

async function createPaper(token = env.tokens.alice): Promise<PaperJson> {
  const body = { files: [{ path: "main.tex", content: MAIN }, { path: "intro.tex", content: "The gears turn slowly.\n" }] };
  const response = await papersRoute.POST(apiRequest("POST", "/api/v1/papers", { token, body }));
  expect(response.status).toBe(201);
  return (await response.json()).paper;
}

function withFile(files: PaperFile[], path: string, content: string): PaperFile[] {
  return files.map((file) => (file.path === path ? { path, content } : file));
}

async function autosave(paper: PaperJson, files: PaperFile[]): Promise<PaperJson> {
  const body = { title: paper.title, files, mainFile: paper.mainFile, compiler: paper.compiler, revision: paper.revision };
  const response = await paperRoute.PUT(apiRequest("PUT", `/api/v1/papers/${paper.id}`, { token: env.tokens.alice, body }), params({ id: paper.id }));
  expect(response.status).toBe(200);
  return (await response.json()).paper;
}

function review(id: string, body: Record<string, unknown>, token = env.tokens.alice) {
  return reviewsRoute.POST(apiRequest("POST", `/api/v1/papers/${id}/reviews`, { token, body }), params({ id }));
}

async function reviews(id: string, query = "", token = env.tokens.alice): Promise<PaperReviewJson[]> {
  const response = await reviewsRoute.GET(apiRequest("GET", `/api/v1/papers/${id}/reviews${query}`, { token }), params({ id }));
  expect(response.status).toBe(200);
  return (await response.json()).reviews;
}

async function versions(id: string): Promise<VersionJson[]> {
  const response = await versionsRoute.GET(apiRequest("GET", `/api/v1/summaries/${id}/versions`, { token: env.tokens.alice }), params({ id }));
  return (await response.json()).items;
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

describe("paper reviews", () => {
  it("keeps a comment on a passage at the version it was made on, saving pending edits first", async () => {
    const paper = await createPaper();
    const edited = await autosave(paper, withFile(paper.files, "intro.tex", "The gears turn slowly, then stop.\n"));
    expect(edited).toMatchObject({ revision: 1, version: 1, hasUnversionedChanges: true });

    const response = await review(paper.id, { quote: "turn slowly, then stop", comment: "Say why they stop.", file: "intro.tex" });
    expect(response.status).toBe(201);
    const created: PaperReviewJson = (await response.json()).review;
    expect(created).toMatchObject({ paperId: paper.id, file: "intro.tex", quote: "turn slowly, then stop", comment: "Say why they stop.", status: "open", version: 2, addressedVersion: null });
    expect((await versions(paper.id)).map((item) => [item.version, item.actor])).toEqual([[2, "owner"], [1, "owner"]]);

    expect(await reviews(paper.id)).toHaveLength(1);
    expect(await reviews(paper.id, "?status=addressed")).toEqual([]);
    expect((await review(paper.id, { quote: "x", comment: "y", file: "missing.tex" })).status).toBe(422);
    expect((await review(paper.id, { quote: "x", comment: "" })).status).toBe(400);
  });

  it("is the owner's: others can't read or add reviews", async () => {
    const paper = await createPaper();
    expect((await review(paper.id, { quote: "gears", comment: "no" }, env.tokens.bob)).status).toBe(404);
    const listed = await reviewsRoute.GET(apiRequest("GET", `/api/v1/papers/${paper.id}/reviews`, { token: env.tokens.bob }), params({ id: paper.id }));
    expect(listed.status).toBe(404);
  });

  it("lets the agent read and finish reviews, and the owner resolve, reopen and delete them", async () => {
    const paper = await createPaper();
    const first: PaperReviewJson = (await (await review(paper.id, { quote: "turn slowly", comment: "Add a number.", file: "intro.tex" })).json()).review;
    const second: PaperReviewJson = (await (await review(paper.id, { quote: "Gears", comment: "Rename the paper." })).json()).review;

    const key = await mcpKey();
    const listed = await callTool(key, "get_paper_reviews", { paperId: paper.id });
    expect(listed.isError).toBeFalsy();
    expect(listed.structuredContent).toMatchObject({ count: 2, open: 2 });
    expect(listed.content[0].text).toContain("Add a number.");

    const edit = await callTool(key, "update_paper", { paperId: paper.id, operations: [{ op: "edit_file", path: "intro.tex", edits: [{ find: "turn slowly", replace: "turn at 3 rpm" }] }] });
    expect(edit.isError).toBeFalsy();
    const finished = await callTool(key, "finish_paper_review", { paperId: paper.id, reviewIds: [first.id], note: "Gave the speed." });
    expect(finished.isError).toBeFalsy();
    expect(finished.structuredContent).toMatchObject({ version: 2, addressed: 1 });

    const after = await reviews(paper.id);
    expect(after.find((item) => item.id === first.id)).toMatchObject({ status: "addressed", version: 1, addressedVersion: 2, agentNote: "Gave the speed." });
    expect(after.find((item) => item.id === second.id)).toMatchObject({ status: "open", addressedVersion: null });
    expect((await callTool(key, "get_paper_reviews", { paperId: paper.id, status: "open" })).structuredContent).toMatchObject({ count: 1 });

    const unknown = await callTool(key, "finish_paper_review", { paperId: paper.id, reviewIds: ["nope"] });
    expect(unknown.isError).toBe(true);
    expect(unknown.content[0].text).toContain("PAPER_REVIEW_NOT_FOUND");

    const resolved = await reviewRoute.PATCH(apiRequest("PATCH", `/api/v1/papers/${paper.id}/reviews/${first.id}`, { token: env.tokens.alice, body: { status: "resolved" } }), params({ id: paper.id, reviewId: first.id }));
    expect(resolved.status).toBe(200);
    expect((await resolved.json()).review).toMatchObject({ status: "resolved", addressedVersion: 2 });
    expect((await reviews(paper.id, "?status=unresolved")).map((item) => item.id)).toEqual([second.id]);
    // Finishing a resolved review again leaves it resolved.
    await callTool(key, "finish_paper_review", { paperId: paper.id, reviewIds: [first.id, second.id] });
    expect((await reviews(paper.id)).map((item) => item.status)).toEqual(["resolved", "addressed"]);

    const reopened = await reviewRoute.PATCH(apiRequest("PATCH", `/api/v1/papers/${paper.id}/reviews/${second.id}`, { token: env.tokens.alice, body: { status: "open", comment: "Rename it to Cogs." } }), params({ id: paper.id, reviewId: second.id }));
    expect((await reopened.json()).review).toMatchObject({ status: "open", comment: "Rename it to Cogs.", addressedVersion: null, agentNote: null });

    const deleted = await reviewRoute.DELETE(apiRequest("DELETE", `/api/v1/papers/${paper.id}/reviews/${first.id}`, { token: env.tokens.alice }), params({ id: paper.id, reviewId: first.id }));
    expect(deleted.status).toBe(204);
    expect((await reviews(paper.id)).map((item) => item.id)).toEqual([second.id]);
    const missing = await reviewRoute.DELETE(apiRequest("DELETE", `/api/v1/papers/${paper.id}/reviews/${first.id}`, { token: env.tokens.alice }), params({ id: paper.id, reviewId: first.id }));
    expect(missing.status).toBe(404);
  });
});

describe("paper figures", () => {
  it("builds a standalone document from the paper's preamble", () => {
    const preamble = figurePreamble(MAIN);
    expect(preamble).toBe("\\usepackage{tikz}\n\\usetikzlibrary{arrows}");
    const document = figureDocument("\\begin{axis}\\addplot {x};\\end{axis}", "\\documentclass{article}\n\\newcommand{\\R}{\\mathbb{R}} % reals\n\\pgfplotsset{\n  compat=1.18,\n}\n\\begin{document}");
    expect(document).toContain("\\documentclass[border=6pt]{standalone}");
    expect(document).toContain("\\newcommand{\\R}{\\mathbb{R}}");
    expect(document).toContain("\\pgfplotsset{\n  compat=1.18,\n}");
    expect(document).toContain("\\usepackage{pgfplots}");
    expect(document).toContain("\\begin{document}\n\\begin{axis}\\addplot {x};\\end{axis}\n\\end{document}");
  });

  it("only sets lengths and commands the figure's packages define", () => {
    const preamble = figurePreamble("\\documentclass{article}\n\\usepackage{fancyhdr}\n\\usepackage{natbib}\n\\usepackage{tikz}\n\\renewcommand{\\headrulewidth}{0pt}\n\\setlength{\\bibsep}{0pt}\n\\newcommand{\\R}{\\mathbb{R}}\n\\begin{document}");
    expect(preamble).toBe("\\usepackage{tikz}\n\\ifdefined\\headrulewidth\\renewcommand{\\headrulewidth}{0pt}\\fi\n\\ifdefined\\bibsep\\setlength{\\bibsep}{0pt}\\fi\n\\newcommand{\\R}{\\mathbb{R}}");
  });

  it("brings in a preamble kept in its own file", () => {
    const files = [
      { path: "preamble.tex", content: "\\usepackage{tikz}\n\\input{macros}\n" },
      { path: "macros.tex", content: "\\usetikzlibrary{positioning}\n\\newcommand{\\R}{\\mathbb{R}}\n" },
    ];
    const main = inlinePreambleInputs("\\documentclass{article}\n\\input{preamble}\n% \\input{unused}\n\\begin{document}\n\\input{body}\n\\end{document}", files);
    expect(figurePreamble(main)).toBe("\\usepackage{tikz}\n\\usetikzlibrary{positioning}\n\\newcommand{\\R}{\\mathbb{R}}");
    expect(main).toContain("\\begin{document}\n\\input{body}");
  });

  it("compiles a figure once per source and reports LaTeX errors", async () => {
    const paper = await createPaper();
    const source = "\\begin{tikzpicture}\\draw (0,0) -- (1,1);\\end{tikzpicture}";
    const render = (body: Record<string, unknown>, token = env.tokens.alice) =>
      figuresRoute.POST(apiRequest("POST", `/api/v1/papers/${paper.id}/figures`, { token, body }), params({ id: paper.id }));
    const first = await render({ source });
    expect(first.status).toBe(200);
    expect(first.headers.get("content-type")).toBe("application/pdf");
    expect(first.headers.get("x-figure-cache")).toBe("miss");
    expect(Buffer.from(await first.arrayBuffer()).subarray(0, 5).toString()).toBe("%PDF-");
    const project = env.latex.calls.at(-1)!.project;
    expect(project.mainFile).toBe("__figure__.tex");
    expect(project.files.map((file) => file.path)).toEqual(["__figure__.tex", "intro.tex"]);
    expect(project.files[0].content).toContain("\\usetikzlibrary{arrows}");
    expect(project.files[0].content).not.toContain("geometry");

    const compiles = env.latex.calls.length;
    const second = await render({ source });
    expect(second.headers.get("x-figure-cache")).toBe("hit");
    expect(env.latex.calls).toHaveLength(compiles);

    const failed = await render({ source: "\\begin{tikzpicture}\\undefinedcommand\\end{tikzpicture}" });
    expect(failed.status).toBe(422);
    expect((await failed.json()).error).toMatchObject({ code: "LATEX_COMPILE_FAILED", details: { errors: [{ file: null, line: expect.any(Number) }] } });

    expect((await render({ source: "no environment" })).status).toBe(400);
    expect((await render({ source }, env.tokens.bob)).status).toBe(404);
  });
});
