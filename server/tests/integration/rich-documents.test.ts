import { eq } from "drizzle-orm";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import * as documentsRoute from "@/app/api/v1/rich-documents/route";
import * as documentRoute from "@/app/api/v1/rich-documents/[id]/route";
import * as operationsRoute from "@/app/api/v1/rich-documents/[id]/operations/route";
import * as versionsRoute from "@/app/api/v1/summaries/[id]/versions/route";
import * as restoreRoute from "@/app/api/v1/summaries/[id]/versions/[version]/restore/route";
import { richDocuments, summaries } from "@/lib/db/schema";
import type { RichDocumentJson } from "@/lib/services/rich-documents";
import { apiRequest, params, setupTestEnv, type TestEnv } from "../helpers/setup";

let env: TestEnv;

beforeEach(async () => {
  env = await setupTestEnv();
});

afterEach(() => env.teardown());

const MARKDOWN = `# Trip report

We walked the old harbour at dawn.

## Photos

![Boats](https://cdn.example.com/boats.jpg "Morning boats")
![Gulls](https://cdn.example.com/gulls.jpg)
[Album](https://example.com/album)
`;

async function create(body: unknown, token = env.tokens.alice): Promise<RichDocumentJson> {
  const response = await documentsRoute.POST(apiRequest("POST", "/api/v1/rich-documents", { token, body }));
  expect(response.status).toBe(201);
  return (await response.json()).richDocument;
}

const get = (id: string, token = env.tokens.alice, query = "") => documentRoute.GET(apiRequest("GET", `/api/v1/rich-documents/${id}${query}`, { token }), params({ id }));
const operate = (id: string, body: unknown, token = env.tokens.alice) => operationsRoute.POST(apiRequest("POST", `/api/v1/rich-documents/${id}/operations`, { token, body }), params({ id }));

describe("rich documents", () => {
  it("creates a library item from Markdown", async () => {
    const created = await create({ markdown: MARKDOWN });
    expect(created).toMatchObject({ revision: 0, isOwner: true, visibility: "private" });
    expect(created.document.title).toBe("Trip report");
    expect(created.document.blocks).toMatchObject([
      { id: "b1", type: "text", columns: [{ markdown: "We walked the old harbour at dawn." }] },
      { id: "b2", type: "text" },
      { id: "b3", type: "image", columns: [{ caption: "Morning boats" }, { url: "https://cdn.example.com/gulls.jpg" }], children: [{ title: "Album" }] },
    ]);

    const [row] = await env.handle.db.select().from(summaries).where(eq(summaries.id, created.id));
    expect(row).toMatchObject({ kind: "rich_document", title: "Trip report", tags: ["document"], expiresAt: null, summary: "We walked the old harbour at dawn." });
    expect(row.highlights).toEqual(["Photos"]);
  });

  it("creates from a full document and exports Markdown", async () => {
    const created = await create({ document: { title: "Clip", blocks: [
      { id: "v", type: "video", align: "center", columns: [{ url: "https://cdn.example.com/a.mp4", posterUrl: "https://cdn.example.com/a.jpg" }] },
    ] }, visibility: "public" });
    expect(created.visibility).toBe("public");
    const response = await get(created.id, env.tokens.bob, "?format=markdown");
    expect(response.headers.get("content-type")).toContain("text/markdown");
    expect(await response.text()).toBe("# Clip\n\n::: center\n![](https://cdn.example.com/a.mp4)\n:::\n");
  });

  it.each([
    ["neither document nor markdown", { visibility: "private" }],
    ["both document and markdown", { markdown: "# x", document: { title: "x" } }],
    ["a text block without markdown", { document: { title: "x", blocks: [{ id: "a", type: "text", columns: [{ url: "https://x.com/a.jpg" }] }] } }],
    ["three columns", { document: { title: "x", blocks: [{ id: "a", type: "text", columns: [{ markdown: "1" }, { markdown: "2" }, { markdown: "3" }] }] } }],
    ["non-https media", { document: { title: "x", blocks: [{ id: "a", type: "image", columns: [{ url: "http://x.com/a.jpg" }] }] } }],
    ["duplicate block ids", { document: { title: "x", blocks: [{ id: "a", type: "text", columns: [{ markdown: "1" }] }, { id: "a", type: "text", columns: [{ markdown: "2" }] }] } }],
    ["a javascript link", { document: { title: "x", blocks: [{ id: "a", type: "text", columns: [{ markdown: "1" }], children: [{ type: "link", title: "x", url: "javascript:alert(1)" }] }] } }],
  ])("refuses %s", async (_, body) => {
    const response = await documentsRoute.POST(apiRequest("POST", "/api/v1/rich-documents", { token: env.tokens.alice, body }));
    expect(response.status).toBe(400);
  });

  it("refuses Markdown without a title", async () => {
    const response = await documentsRoute.POST(apiRequest("POST", "/api/v1/rich-documents", { token: env.tokens.alice, body: { markdown: "Just text" } }));
    expect(response.status).toBe(422);
  });

  it("inserts, changes, moves and removes blocks, each save a version, and restores", async () => {
    const created = await create({ markdown: MARKDOWN });
    const inserted = await operate(created.id, { operations: [
      { op: "insert_markdown", markdown: "## Sound\n\n![Waves](https://cdn.example.com/waves.mp3)", after: "b1" },
      { op: "update_block", id: "b3", changes: { align: "center" } },
      { op: "move_block", id: "b3", after: null },
    ] });
    expect(inserted.status).toBe(200);
    const saved = (await inserted.json()).richDocument as RichDocumentJson;
    expect(saved.revision).toBe(1);
    expect(saved.document.blocks.map((block) => `${block.id}:${block.type}`)).toEqual(["b3:image", "b1:text", "b4:text", "b5:audio", "b2:text"]);
    expect(saved.document.blocks[0].align).toBe("center");

    const removed = await operate(created.id, { operations: [{ op: "delete_block", id: "b5" }, { op: "set_meta", title: "Harbour" }] });
    const after = (await removed.json()).richDocument as RichDocumentJson;
    expect(after.document.title).toBe("Harbour");
    expect(after.document.blocks).toHaveLength(4);

    const history = await versionsRoute.GET(apiRequest("GET", `/api/v1/summaries/${created.id}/versions`, { token: env.tokens.alice }), params({ id: created.id }));
    const { items } = await history.json();
    expect(items).toHaveLength(3);
    expect(items[0]).toMatchObject({ kind: "rich_document", title: "Harbour", isCurrent: true });

    const restored = await restoreRoute.POST(apiRequest("POST", `/api/v1/summaries/${created.id}/versions/1/restore`, { token: env.tokens.alice }), params({ id: created.id, version: "1" }));
    expect(restored.status).toBe(200);
    expect((await restored.json()).richDocument.document.title).toBe("Trip report");
  });

  it("refuses a broken edit, a stale revision and other people's edits", async () => {
    const created = await create({ markdown: MARKDOWN });
    const missing = await operate(created.id, { operations: [{ op: "delete_block", id: "nope" }] });
    expect(missing.status).toBe(422);
    expect((await missing.json()).error.code).toBe("RICH_DOCUMENT_INVALID");
    const wrongType = await operate(created.id, { operations: [{ op: "update_block", id: "b1", changes: { type: "video" } }] });
    expect(wrongType.status).toBe(422);

    await operate(created.id, { operations: [{ op: "set_meta", description: "Notes" }] });
    const stale = await operate(created.id, { revision: 0, operations: [{ op: "set_meta", title: "x" }] });
    expect(stale.status).toBe(409);
    expect((await stale.json()).error.code).toBe("RICH_DOCUMENT_REVISION_CONFLICT");

    expect((await operate(created.id, { operations: [{ op: "set_meta", title: "x" }] }, env.tokens.bob)).status).toBe(404);
    expect((await get(created.id, env.tokens.bob)).status).toBe(404);
  });

  it("lists and deletes", async () => {
    const created = await create({ markdown: MARKDOWN });
    const list = await documentsRoute.GET(apiRequest("GET", "/api/v1/rich-documents", { token: env.tokens.alice }));
    expect((await list.json()).documents).toMatchObject([{ id: created.id, title: "Trip report", blockCount: 3 }]);

    const deleted = await documentRoute.DELETE(apiRequest("DELETE", `/api/v1/rich-documents/${created.id}`, { token: env.tokens.alice }), params({ id: created.id }));
    expect(deleted.status).toBe(204);
    expect(await env.handle.db.select().from(richDocuments).where(eq(richDocuments.summaryId, created.id))).toEqual([]);
    expect((await get(created.id)).status).toBe(404);
  });
});
