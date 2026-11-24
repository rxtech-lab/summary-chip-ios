import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { eq, sql } from "drizzle-orm";
import { unzipSync, strFromU8 } from "fflate";
import sharp from "sharp";
import { readFileSync } from "node:fs";
import { resumeDocumentSchema } from "@/lib/contracts/resume";
import { resumeAssets, resumePreviews, resumePublications, shareLinks, summaries } from "@/lib/db/schema";
import { createResume, editResume } from "@/lib/services/resumes";
import { createShareLink, deleteShareLink } from "@/lib/services/share-links";
import {
  prepareResumePreview,
  publishResumePreview,
  stageResumeAvatar,
  importResumeAvatar,
  ownerArtifact,
  resolveResumePublication,
  listViewedPublications,
} from "@/lib/services/resume-outputs";
import { readPublishedResume } from "@/lib/http/resume-recipient";
import { runCleanup } from "@/lib/services/cleanup";
import { getCompletedUpload } from "@/lib/services/uploads";
import { resolveShareKey } from "@/lib/services/share-access";
import { apiRequest, setupTestEnv, buildPdf, signToken, type TestEnv } from "../helpers/setup";

vi.mock("@/lib/pdf/browser-pdf", () => ({ renderPdf: vi.fn() }));
import { renderPdf } from "@/lib/pdf/browser-pdf";

const doc = resumeDocumentSchema.parse(
  JSON.parse(readFileSync("../Packages/SummaryKit/Tests/SummaryKitTests/Fixtures/resume.json", "utf8")),
);
let env: TestEnv;
const owner = "user-alice",
  viewer = "user-bob",
  color = "#506070";
const pres = { template: "profile-v1", paperSize: "A4", showAvatar: true } as const;
const create = () =>
  createResume(env.handle.db, owner, {
    title: "Working title",
    language: "fr",
    document: doc,
    idempotencyKey: crypto.randomUUID(),
  });
const preview = (r: Awaited<ReturnType<typeof create>>) =>
  prepareResumePreview(env.handle.db, owner, r.familyId, {
    revisionToken: r.revisionToken,
    language: r.language,
    variantId: r.variantId,
    presentation: pres,
  });
async function avatar(familyId: string, background: string) {
  const bytes = await sharp({ create: { width: 24, height: 30, channels: 3, background } })
    .png()
    .withMetadata()
    .toBuffer();
  const stage = await stageResumeAvatar(env.handle.db, owner, familyId, {
    mimeType: "image/png",
    byteSize: bytes.length,
    filename: "portrait.png",
  });
  await env.store.put(stage.key, { contentType: "image/png", bytes });
  return (await importResumeAvatar(env.handle.db, owner, familyId, stage.key)).id;
}
beforeEach(async () => {
  env = await setupTestEnv();
  vi.mocked(renderPdf).mockImplementation(async (html) =>
    buildPdf(html.match(/<h1[^>]*>(.*?)<\/h1>/)?.[1] ?? "resume"),
  );
});
afterEach(() => env.teardown());

describe("résumé publication boundaries", () => {
  it("pins the previewed PDF, editable Word structure and avatar through replacement, pruning and expiry", async () => {
    const db = env.handle.db;
    let r = await create();
    const familyId = r.familyId;
    const assetA = await avatar(familyId, color);
    const edit = (path: string, value: string) =>
      editResume(db, owner, familyId, {
        expectedRevisionToken: r.revisionToken,
        idempotencyKey: crypto.randomUUID(),
        operations: [{ op: "set", path, value }],
      });
    r = await edit("/avatarAssetId", assetA);
    const p = await preview(r);
    const input = { previewId: p.id, access: "anyone" as const, ttlDays: 7, idempotencyKey: "publish-one" };
    const first = await publishResumePreview(db, owner, familyId, input);
    expect(await publishResumePreview(db, owner, familyId, input)).toEqual(first);
    const slug = first.url.split("/").at(-1)!;
    const [summary] = await db.select().from(summaries).where(eq(summaries.id, familyId));
    expect(await resolveShareKey(db, slug, { id: owner })).toEqual({ status: "missing" });
    expect((await resolveResumePublication(db, summary.slug, { id: owner })).status).toBe("missing");
    await expect(createShareLink(db, owner, familyId, { access: "anyone", emails: [] })).rejects.toMatchObject({
      code: "RESUME_PREVIEW_REQUIRED",
    });
    const pdf = await ownerArtifact(db, owner, familyId, p.id, "pdf");
    const files = unzipSync(await ownerArtifact(db, owner, familyId, p.id, "docx"));
    expect(strFromU8(files["word/document.xml"])).toContain("<w:hyperlink");
    expect(strFromU8(files["word/document.xml"])).toContain("<w:numPr>");
    expect(files["word/media/avatar.jpg"]).toBeDefined();
    await expect(ownerArtifact(db, viewer, familyId, p.id, "pdf")).rejects.toMatchObject({ status: 404 });
    const assetB = await avatar(familyId, "#fff");
    r = await edit("/avatarAssetId", assetB);
    for (let i = 0; i < 101; i++) r = await edit("/headline", "Headline " + i);
    const [asset] = await db.select().from(resumeAssets).where(eq(resumeAssets.id, assetA));
    expect((await sharp(asset.bytes).metadata()).exif).toBeUndefined();
    const next = await preview(r);
    const second = await publishResumePreview(db, owner, familyId, {
      ...input,
      previewId: next.id,
      idempotencyKey: "other",
    });
    const read = (format: "json" | "pdf" | "avatar" | "html", key?: string) =>
      readPublishedResume(apiRequest("GET", "/"), slug, format, key);
    const json = await (await read("json")).json();
    expect(json.document).toMatchObject({ headline: doc.headline, avatarAssetId: assetA });
    expect(await (await read("html")).text()).toContain(doc.headline);
    expect(await (await read("pdf")).bytes()).toEqual(new Uint8Array(pdf));
    expect(await (await read("avatar", assetA)).bytes()).toEqual(new Uint8Array(asset.bytes));
    expect((await read("avatar", assetB)).status).toBe(404);
    const beforeExpiry = new Date(new Date(first.expiresAt!).getTime() - 1);
    expect((await resolveResumePublication(db, slug, null, beforeExpiry)).status).toBe("ok");
    expect((await resolveResumePublication(db, slug, null, new Date(first.expiresAt!))).status).toBe("missing");
    await deleteShareLink(db, owner, familyId, first.id);
    for (const format of ["pdf", "json", "avatar", "html"] as const) {
      const response = await read(format, assetA);
      expect(response.status).toBe(404);
      expect(response.headers.get("cache-control")).toBe("private, no-store");
    }
    expect((await resolveResumePublication(db, second.url.split("/").at(-1)!, null)).status).toBe("ok");
  }, 30000);

  it("checks invitations, isolated history, publication freshness and explicit wording selection", async () => {
    const db = env.handle.db,
      r = await create(),
      p = await preview(r);
    await db
      .update(resumePreviews)
      .set({ missingTranslationPaths: ["/headline"] })
      .where(eq(resumePreviews.id, p.id));
    const input = {
      idempotencyKey: "invited-link",
      previewId: p.id,
      access: "invited" as const,
      emails: ["bob@example.org"],
    };
    await expect(publishResumePreview(db, owner, r.familyId, input)).rejects.toMatchObject({
      code: "RESUME_WORDING_REVIEW_REQUIRED",
    });
    const acceptedWordingPaths = ["/headline"];
    const link = await publishResumePreview(db, owner, r.familyId, { ...input, acceptedWordingPaths });
    const slug = link.url.split("/").at(-1)!;
    expect((await resolveResumePublication(db, slug, null)).status).toBe("sign-in");
    expect((await resolveResumePublication(db, slug, { id: owner, email: "wrong@example.org" })).status).toBe(
      "forbidden",
    );
    const token = await signToken(viewer, { email: "bob@example.org" });
    const request = apiRequest("GET", "/", { token });
    expect((await readPublishedResume(request, slug, "json")).status).toBe(200);
    const open = await publishResumePreview(db, owner, r.familyId, {
      ...input,
      idempotencyKey: "open",
      access: "anyone",
      acceptedWordingPaths,
    });
    expect((await readPublishedResume(request, open.url.split("/").at(-1)!, "json")).status).toBe(200);
    expect(
      (await listViewedPublications(db, { id: viewer, email: "bob@example.org" })).items.map((i) => i.slug).sort(),
    ).toEqual([slug, open.url.split("/").at(-1)!].sort());
    await expect(
      publishResumePreview(db, owner, r.familyId, {
        ...input,
        acceptedWordingPaths,
        idempotencyKey: "republish",
        linkId: link.id,
        expectedPreviewId: "stale",
      }),
    ).rejects.toMatchObject({ status: 409 });
    expect((await resolveResumePublication(db, slug, { id: viewer, email: "bob@example.org" })).status).toBe("ok");
  });

  it("republishes only the preview and preserves invitation policy and expiry unless changed", async () => {
    const db = env.handle.db,
      family = await create(),
      first = await preview(family);
    const link = await publishResumePreview(db, owner, family.familyId, {
      previewId: first.id,
      idempotencyKey: "publish",
      access: "invited",
      ttlDays: 1,
      emails: ["bob@example.org"],
    });
    const revised = await editResume(db, owner, family.familyId, {
      expectedRevisionToken: family.revisionToken,
      idempotencyKey: "modify",
      operations: [{ op: "set", path: "/headline", value: "New headline" }],
    });
    const updated = await preview(revised);
    const republished = await publishResumePreview(db, owner, family.familyId, {
      previewId: updated.id,
      idempotencyKey: "republish",
      linkId: link.id,
      expectedPreviewId: first.id,
    });
    expect(republished).toMatchObject({
      url: link.url,
      expiresAt: link.expiresAt,
      access: "invited",
      emails: link.emails,
      previewId: updated.id,
    });
    const resolved = await resolveResumePublication(db, link.url.split("/").at(-1)!, {
      id: viewer,
      email: "bob@example.org",
    });
    expect(resolved.status === "ok" && resolved.preview.document.headline).toBe("New headline");
  });

  it("enforces twenty links under concurrent publication and leaves no unbound link", async () => {
    const db = env.handle.db,
      r = await create(),
      p = await preview(r);
    const publish = (idempotencyKey: string) =>
      publishResumePreview(db, owner, r.familyId, { previewId: p.id, idempotencyKey });
    for (let i = 0; i < 19; i++) await publish(String(i));
    const results = await Promise.allSettled([publish("left"), publish("right")]);
    expect(results.filter((x) => x.status === "fulfilled")).toHaveLength(1);
    expect(results.find((x) => x.status === "rejected")?.reason).toMatchObject({ code: "TOO_MANY_SHARE_LINKS" });
    expect((await db.select({ count: sql<number>`count(*)` }).from(shareLinks))[0].count).toBe(20);
    expect((await db.select({ count: sql<number>`count(*)` }).from(resumePublications))[0].count).toBe(20);
  });
  it("scopes presigned staging, rejects invalid bytes and cleans abandoned objects and unused previews", async () => {
    const db = env.handle.db,
      family = await create();
    const bytes = Buffer.from("invalid image");
    const upload = await stageResumeAvatar(db, owner, family.familyId, {
      filename: "fake.png",
      mimeType: "image/png",
      byteSize: bytes.length,
    });
    expect(upload.key.startsWith("resume-uploads/")).toBe(true);
    await env.store.put(upload.key, { contentType: "image/png", bytes });
    await expect(getCompletedUpload(db, owner, upload.key)).rejects.toMatchObject({ code: "UPLOAD_FORBIDDEN" });
    await expect(importResumeAvatar(db, owner, family.familyId, upload.key)).rejects.toMatchObject({
      code: "INVALID_AVATAR",
    });
    const other = await createResume(db, viewer, {
      title: "Other",
      language: "fr",
      document: doc,
      idempotencyKey: crypto.randomUUID(),
    });
    await expect(importResumeAvatar(db, viewer, other.familyId, upload.key)).rejects.toMatchObject({
      code: "UPLOAD_FORBIDDEN",
    });
    const orphan = await avatar(family.familyId, color);
    await expect(
      editResume(db, viewer, other.familyId, {
        idempotencyKey: crypto.randomUUID(),
        expectedRevisionToken: other.revisionToken,
        operations: [{ op: "set", path: "/avatarAssetId", value: orphan }],
      }),
    ).rejects.toMatchObject({ status: 422 });
    const saved = await preview(family);
    await runCleanup(db, { now: new Date(Date.now() + 2 * 86400_000) });
    expect(await env.store.head(upload.key)).toBeNull();
    expect(await db.select().from(resumeAssets).where(eq(resumeAssets.id, orphan))).toHaveLength(0);
    expect(await db.select().from(resumePreviews).where(eq(resumePreviews.id, saved.id))).toHaveLength(0);
  });
});
