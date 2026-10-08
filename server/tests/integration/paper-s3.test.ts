import { afterEach, beforeEach, describe, expect, it } from "vitest";
import * as uploadsRoute from "@/app/api/v1/uploads/route";
import * as papersRoute from "@/app/api/v1/papers/route";
import * as paperRoute from "@/app/api/v1/papers/[id]/route";
import * as assetsRoute from "@/app/api/v1/papers/[id]/assets/route";
import * as commitRoute from "@/app/api/v1/papers/[id]/versions/route";
import * as pdfRoute from "@/app/api/v1/papers/[id]/pdf/route";
import * as restoreRoute from "@/app/api/v1/summaries/[id]/versions/[version]/restore/route";
import type { PaperFile } from "@/lib/contracts/paper";
import { runCleanup } from "@/lib/services/cleanup";
import type { PaperJson } from "@/lib/services/papers";
import { apiRequest, params, setupTestEnv, type TestEnv } from "../helpers/setup";

const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=", "base64");
let env: TestEnv;
beforeEach(async () => { env = await setupTestEnv(); });
afterEach(() => env.teardown());

async function stage(bytes = png, token = env.tokens.alice, complete = true): Promise<PaperFile> {
  const response = await uploadsRoute.POST(apiRequest("POST", "/api/v1/uploads", { token, body: { filename: "figure.png", mimeType: "image/png", byteSize: bytes.length } }));
  expect(response.status).toBe(201);
  const ticket = await response.json();
  expect(ticket).toMatchObject({ method: "PUT", headers: { "content-type": "image/png" } });
  expect(ticket.uploadUrl).toContain("uploads.invalid");
  if (complete) await env.store.put(ticket.key, { bytes, contentType: "image/png" });
  return { path: "images/figure.png", content: "", asset: { key: ticket.key, mimeType: "image/png", byteSize: bytes.length } };
}

async function create(files?: PaperFile[], visibility = "private"): Promise<PaperJson> {
  const response = await papersRoute.POST(apiRequest("POST", "/api/v1/papers", { token: env.tokens.alice, body: { title: "Figures", visibility, ...(files ? { files, mainFile: "main.tex" } : {}) } }));
  expect(response.status).toBe(201);
  return (await response.json()).paper;
}

function save(paper: PaperJson, files: PaperFile[]) {
  return paperRoute.PUT(apiRequest("PUT", `/api/v1/papers/${paper.id}`, { token: env.tokens.alice, body: {
    title: paper.title, files, mainFile: paper.mainFile, compiler: paper.compiler, revision: paper.revision,
  } }), params({ id: paper.id }));
}

function image(paper: PaperJson, version?: number, token = env.tokens.alice) {
  return assetsRoute.GET(apiRequest("GET", `/api/v1/papers/${paper.id}/assets?path=images/figure.png${version ? `&version=${version}` : ""}`, { token }), params({ id: paper.id }));
}

async function commit(paper: PaperJson) {
  const response = await commitRoute.POST(apiRequest("POST", `/api/v1/papers/${paper.id}/versions`, { token: env.tokens.alice }), params({ id: paper.id }));
  expect(response.status).toBe(200);
  return (await response.json()).paper as PaperJson;
}

describe("paper S3 uploads", () => {
  it("copies image uploads to immutable assets, preserves versions, and deletes their objects with the paper", async () => {
    const staged = await stage();
    const created = await create([{ path: "main.tex", content: "\\documentclass{article}\n\\usepackage{graphicx,tikz,pgfplots}\n\\begin{document}\n\\includegraphics{images/figure.png}\n\\end{document}" }, staged]);
    const firstKey = created.files[1].asset!.key;
    expect(firstKey).toMatch(new RegExp(`^papers/${created.id}/assets/[0-9a-f]{64}-[0-9a-f-]{36}\\.png$`));
    expect(created.files[1].content).toBe("");
    expect((await env.store.get(firstKey)).bytes).toEqual(png);
    // Reusing the staging PUT URL cannot change a saved image or its PDF cache key.
    await env.store.put(staged.asset!.key, { bytes: Buffer.concat([png, Buffer.from("overwritten")]), contentType: "image/png" });
    expect(Buffer.from(await (await image(created)).arrayBuffer())).toEqual(png);
    const compiled = await pdfRoute.GET(apiRequest("GET", `/api/v1/papers/${created.id}/pdf`, { token: env.tokens.alice }), params({ id: created.id }));
    expect(compiled.status).toBe(200);
    expect(env.latex.calls[0].project.assetData?.[staged.path]).toEqual(png);

    const replacement = await stage(Buffer.concat([png, Buffer.from("new image")]));
    const savedResponse = await save(created, [created.files[0], replacement]);
    expect(savedResponse.status).toBe(200);
    const saved: PaperJson = (await savedResponse.json()).paper;
    const secondKey = saved.files[1].asset!.key;
    expect(secondKey).not.toBe(firstKey);
    await commit(saved);
    expect(Buffer.from(await (await image(saved, 1)).arrayBuffer())).toEqual(png);

    const restoredResponse = await restoreRoute.POST(apiRequest("POST", `/api/v1/summaries/${created.id}/versions/1/restore`, { token: env.tokens.alice }), params({ id: created.id, version: "1" }));
    expect(restoredResponse.status).toBe(200);
    const restored: PaperJson = (await restoredResponse.json()).paper;
    expect(restored.files[1].asset!.key).toBe(firstKey);
    // Staging uploads expire while assets used by history survive cleanup.
    await runCleanup(env.handle.db, { store: env.store, now: new Date(Date.now() + 2 * 86_400_000) });
    expect(await env.store.head(firstKey)).not.toBeNull();
    expect(await env.store.head(secondKey)).not.toBeNull();
    expect(await env.store.head(staged.asset!.key)).toBeNull();
    const deleted = await paperRoute.DELETE(apiRequest("DELETE", `/api/v1/papers/${created.id}`, { token: env.tokens.alice }), params({ id: created.id }));
    expect(deleted.status).toBe(204);
    expect(await env.store.head(firstKey)).toBeNull();
    expect(await env.store.head(secondKey)).toBeNull();
  });

  it("rejects unfinished, foreign, mismatched, and invalid uploads without changing the paper", async () => {
    const paper = await create();
    const unfinished = await stage(png, env.tokens.alice, false);
    expect((await save(paper, [...paper.files, unfinished])).status).toBe(409);
    const foreign = await stage(png, env.tokens.bob);
    expect((await save(paper, [...paper.files, foreign])).status).toBe(403);
    const invalid = await stage(Buffer.from("not a PNG"));
    expect((await save(paper, [...paper.files, invalid])).status).toBe(422);
    const valid = await stage();
    expect((await save(paper, [...paper.files, { ...valid, asset: { ...valid.asset!, byteSize: valid.asset!.byteSize + 1 } }])).status).toBe(422);
    const read = await paperRoute.GET(apiRequest("GET", `/api/v1/papers/${paper.id}`, { token: env.tokens.alice }), params({ id: paper.id }));
    expect((await read.json()).paper.revision).toBe(0);
  });

  it("gates image previews by paper access and disallows cross-paper asset references", async () => {
    const privatePaper = await create([{ path: "main.tex", content: "\\documentclass{article}\\begin{document}x\\end{document}" }, await stage()]);
    expect((await image(privatePaper, undefined, env.tokens.bob)).status).toBe(404);
    const other = await create();
    expect((await save(other, [...other.files, privatePaper.files[1]])).status).toBe(403);
    const publicPaper = await create([{ path: "main.tex", content: "\\documentclass{article}\\begin{document}x\\end{document}" }, await stage()], "public");
    expect((await image(publicPaper, undefined, env.tokens.bob)).status).toBe(200);
    expect((await image(publicPaper, 1, env.tokens.bob)).status).toBe(404);
  });
});
