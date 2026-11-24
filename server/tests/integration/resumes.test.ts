import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { eq } from "drizzle-orm";
import { createDatabase } from "@/lib/db/client";
import { resumeDocumentSchema, type ResumeOperation } from "@/lib/contracts/resume";
import {
  commitResumeTranslation,
  createResume,
  createResumeVariant,
  editResume,
  getResume,
  listResumeHistory,
  listResumes,
  previewResumeRestore,
  previewResumeVariant,
  restoreResume,
  type ResolvedResume,
} from "@/lib/services/resumes";
import { resumeAssets, resumeRevisions, summaries } from "@/lib/db/schema";
import { setupTestEnv, type TestEnv } from "../helpers/setup";

const fixture = JSON.parse(readFileSync("../Packages/SummaryKit/Tests/SummaryKitTests/Fixtures/resume.json", "utf8"));
const owner = "alice",
  entry = "/sections/work/entries/job1",
  title = entry + "/title",
  bullet = entry + "/bullets/bullet1/text";
let env: TestEnv;
beforeEach(async () => {
  env = await setupTestEnv();
});
afterEach(() => env.teardown());
function create() {
  return createResume(env.handle.db, owner, {
    title: "CV",
    language: "fr",
    document: fixture,
    idempotencyKey: randomUUID(),
  });
}
function edit(current: ResolvedResume, operations: ResumeOperation[], idempotencyKey = randomUUID()) {
  return editResume(env.handle.db, owner, current.familyId, {
    variantId: current.variantId,
    language: current.language,
    expectedRevisionToken: current.revisionToken,
    idempotencyKey,
    operations,
  });
}
function get(current: ResolvedResume) {
  return getResume(env.handle.db, owner, current.familyId, {
    variantId: current.variantId,
    language: current.language,
  });
}
function variant(current: ResolvedResume, company: string) {
  return createResumeVariant(env.handle.db, owner, current.familyId, {
    company,
    language: current.language,
    expectedRevisionToken: current.revisionToken,
    idempotencyKey: randomUUID(),
  });
}

describe("private structured résumés", () => {
  it("round-trips the shared multilingual fixture, rejects ambiguous IDs and invalid URLs", async () => {
    expect(resumeDocumentSchema.parse(fixture)).toEqual(fixture);
    const base = await create();
    expect(base.document).toEqual(fixture);
    expect(base.document.avatarAssetId).toBeUndefined();
    expect(await listResumes(env.handle.db, owner)).toHaveLength(1);
    expect(await listResumes(env.handle.db, "other")).toEqual([]);
    expect((await env.handle.db.select().from(summaries).where(eq(summaries.id, base.familyId)))[0].visibility).toBe(
      "private",
    );
    await expect(getResume(env.handle.db, "other", base.familyId)).rejects.toMatchObject({ status: 404 });
    await expect(edit(base, [{ op: "set", path: "/links/link1/url", value: "javascript:alert(1)" }])).rejects.toThrow();
    await expect(
      edit(base, [{ op: "insert", path: "/sections/work/entries", value: { id: "job1", bullets: [] } }]),
    ).rejects.toThrow();
    await expect(edit(base, [{ op: "set", path: "/constructor/prototype/title", value: "no" }])).rejects.toThrow();
  });
  it("inherits new jobs and preserves a removed customized subtree, including company inserts", async () => {
    let b = await create(),
      a = await variant(b, "A"),
      other = await variant(b, "B");
    a = await edit(a, [
      { op: "set", path: bullet, value: "Acme bullet" },
      { op: "set", path: title, value: "Acme engineering" },
      { op: "insert", path: entry + "/bullets", value: { id: "extra", text: "One more result" } },
    ]);
    const saved = a.revisionToken;
    other = await edit(other, [{ op: "remove", path: entry }]);
    b = await edit(b, [
      { op: "insert", path: "/sections/work/entries", value: { id: "new", title: "New base job", bullets: [] } },
    ]);
    expect((await get(a)).document.sections[0].entries.at(-1)?.id).toBe("new");
    expect((await get(other)).document.sections[0].entries.map((e) => e.id)).toEqual(["job2", "new"]);
    b = await edit(b, [{ op: "set", path: title, value: "Staff engineer" }]);
    expect((await get(a)).reviewPaths).toContain(title);
    b = await edit(b, [{ op: "remove", path: entry }]);
    a = await get(a);
    expect(a.recoverablePaths).toEqual([entry]);
    expect(a.document.sections[0].entries[0]).toMatchObject({
      id: "job1",
      title: "Acme engineering",
      bullets: [{ text: "Acme bullet" }, { text: "One more result" }],
    });
    a = await edit(a, [{ op: "discard", path: entry }]);
    expect(a.document.sections[0].entries.map((e) => e.id)).toEqual(["job2", "new"]);
    const old = await getResume(env.handle.db, owner, b.familyId, { variantId: a.variantId, revisionToken: saved });
    expect(old.document.sections[0].entries).toHaveLength(2);
    const preview = await previewResumeRestore(env.handle.db, owner, b.familyId, {
      variantId: a.variantId,
      revisionToken: saved,
    });
    expect(preview.document.sections[0].entries).toHaveLength(3);
    a = await restoreResume(env.handle.db, owner, b.familyId, {
      variantId: a.variantId,
      revisionToken: saved,
      expectedRevisionToken: a.revisionToken,
      idempotencyKey: randomUUID(),
    });
    a = await edit(a, [{ op: "keep", path: entry }]);
    expect(a.recoverablePaths).toEqual([]);
    expect(a.document.sections[0].entries[0].bullets[1].text).toBe("One more result");
    const history = await listResumeHistory(env.handle.db, owner, b.familyId, { variantId: a.variantId });
    expect(new Set(history.map((h) => h.origin))).toEqual(new Set(["base", "company"]));
    for (const h of history)
      expect(
        (await getResume(env.handle.db, owner, b.familyId, { revisionToken: h.revisionToken })).revisionToken,
      ).toBe(h.revisionToken);
  });
  it("commits concurrent edits once, rejects stale updates, deduplicates retries and skips no-ops", async () => {
    const b = await create(),
      key = randomUUID(),
      ops: ResumeOperation[] = [{ op: "set", path: "/headline", value: "A" }];
    const results = await Promise.allSettled([
      edit(b, ops, key),
      edit(b, [{ op: "set", path: "/headline", value: "B" }]),
    ]);
    expect(results[0].status).toBe("fulfilled");
    expect(results[1]).toMatchObject({ status: "rejected", reason: { code: "RESUME_REVISION_CONFLICT" } });
    const saved = await get(b);
    expect((await edit(b, ops, key)).revisionToken).toBe(saved.revisionToken);
    expect((await edit(saved, ops)).revisionToken).toBe(saved.revisionToken);
    const a = await variant(saved, "A");
    expect((await edit(a, ops)).revisionToken).toBe(a.revisionToken);
    expect(await env.handle.db.select().from(resumeRevisions)).toHaveLength(4);
  });
  it("preserves the edited language when creating a company, checks proposal tokens and validates private assets", async () => {
    let b = await create();
    const db = env.handle.db;
    const english = await commitResumeTranslation(db, owner, b.familyId, {
      sourceLanguage: "fr",
      language: "en",
      sourceRevisionToken: b.revisionToken,
      expectedRevisionToken: null,
      idempotencyKey: randomUUID(),
      operations: [{ op: "set", path: title, value: "Engineer" }],
      baselines: {
        [title]: { sourceValue: "Ingénieure", acceptedValue: "Engineer", sourceRevisionToken: b.revisionToken },
      },
    });
    const manual = await edit(english, [{ op: "set", path: title, value: "Lead engineer" }]);
    const a = await variant(manual, "Company");
    expect(a.document.sections[0].entries[0].title).toBe("Lead engineer");
    const tailored = await edit(a, [{ op: "set", path: title, value: "Tailored lead" }]);
    const fr = await getResume(db, owner, b.familyId, { variantId: a.variantId, language: "fr" });
    expect(fr.missingTranslationPaths).toContain(title);
    expect(fr.overrideSources[title]).toEqual({ language: "en", value: "Tailored lead" });
    const translated = await commitResumeTranslation(db, owner, b.familyId, {
      sourceLanguage: "en",
      language: "fr",
      variantId: a.variantId,
      sourceRevisionToken: tailored.revisionToken,
      expectedRevisionToken: fr.revisionToken,
      idempotencyKey: randomUUID(),
      operations: [{ op: "set", path: title, value: "Cheffe" }],
      baselines: {
        [title]: { sourceRevisionToken: tailored.revisionToken, sourceValue: "Tailored lead", acceptedValue: "Cheffe" },
      },
    });
    expect(translated.missingTranslationPaths).toEqual([]);
    await expect(
      commitResumeTranslation(db, owner, b.familyId, {
        sourceLanguage: "fr",
        language: "en",
        sourceRevisionToken: b.revisionToken,
        expectedRevisionToken: english.revisionToken,
        idempotencyKey: randomUUID(),
        operations: [],
      }),
    ).rejects.toMatchObject({ status: 409 });
    const av = randomUUID();
    await db
      .insert(resumeAssets)
      .values({ id: av, familyId: b.familyId, bytes: Buffer.from([1]), mimeType: "image/png", sourceKey: "k" });
    await expect(edit(await create(), [{ op: "set", path: "/avatarAssetId", value: av }])).rejects.toMatchObject({
      status: 422,
    });
    b = await edit(await get(b), [{ op: "set", path: "/avatarAssetId", value: av }]);
    await edit(b, [{ op: "set", path: "/avatarAssetId", value: null }]);
    expect((await getResume(db, owner, b.familyId, { revisionToken: b.revisionToken })).document.avatarAssetId).toBe(
      av,
    );
  });
  it("imports only selected differences and resets inherited values", async () => {
    const db = env.handle.db;
    const b = await create();
    let a = await variant(b, "Acme");
    a = await edit(a, [
      { op: "set", path: title, value: "Custom title" },
      { op: "set", path: bullet, value: "Custom bullet" },
    ]);
    const preview = await previewResumeVariant(db, owner, b.familyId, { sourceRevisionToken: a.revisionToken });
    expect(preview.operations.map((o) => o.path).sort()).toEqual([title, bullet].sort());
    let copied = await createResumeVariant(db, owner, b.familyId, {
      language: "fr",
      company: "Second company",
      sourceRevisionToken: a.revisionToken,
      expectedRevisionToken: preview.revisionToken,
      acceptedPaths: [title],
      idempotencyKey: randomUUID(),
    });
    expect(copied.overrideCount).toBe(1);
    expect(copied.document.sections[0].entries[0].bullets[0].text).toBe(fixture.sections[0].entries[0].bullets[0].text);
    copied = await edit(copied, [{ op: "reset", path: title }]);
    expect(copied.document).toEqual(b.document);
  });
  it("uses surviving neighbors and keeps translated company wording across manual target edits", async () => {
    const db = env.handle.db;
    let b = await create();
    b = await edit(
      b,
      ["x", "y", "z"].map((id) => ({ op: "insert", path: "/sections/work/entries", value: { id, bullets: [] } })),
    );
    let a = await variant(b, "A");
    a = await edit(a, [
      { op: "move", path: "/sections/work/entries/job1", after: "x" },
      { op: "set", path: title, value: "Acme rôle" },
    ]);
    b = await edit(b, [
      { op: "remove", path: "/sections/work/entries/job2" },
      { op: "remove", path: "/sections/work/entries/x" },
    ]);
    a = await get(a);
    expect(a.document.sections[0].entries.map((e) => e.id)).toEqual(["job1", "y", "z"]);
    const src = a.revisionToken;
    const english = await commitResumeTranslation(db, owner, b.familyId, {
      sourceLanguage: "fr",
      language: "en",
      variantId: a.variantId,
      sourceRevisionToken: src,
      expectedRevisionToken: null,
      idempotencyKey: randomUUID(),
      baseOperations: [{ op: "set", path: title, value: "Base role" }],
      baseBaselines: {
        [title]: { sourceRevisionToken: b.revisionToken, sourceValue: "Ingénieure", acceptedValue: "Base role" },
      },
      operations: [{ op: "set", path: title, value: "Acme role" }],
      baselines: { [title]: { sourceRevisionToken: src, sourceValue: "Acme rôle", acceptedValue: "Acme role" } },
    });
    expect((await getResume(db, owner, b.familyId, { language: "en" })).document.sections[0].entries[0].title).toBe(
      "Base role",
    );
    expect(english.document.sections[0].entries[0].title).toBe("Acme role");
    const manual = await edit(english, [{ op: "set", path: title, value: "Manually refined" }]);
    expect(manual.overrideSources[title].language).toBe("fr");
    a = await edit(await get(a), [{ op: "set", path: title, value: "Nouveau rôle" }]);
    const stale = await get(manual);
    expect(stale.document.sections[0].entries[0].title).toBe("Manually refined");
    expect(stale.missingTranslationPaths).toContain(title);
    const reset = await edit(stale, [{ op: "reset", path: title }]);
    expect(reset.document.sections[0].entries[0].title).toBe("Base role");
    expect(reset.overridePaths).not.toContain(title);
    expect((await get(a)).document.sections[0].entries[0].title).toBe("Nouveau rôle");
  });
  it("prunes old unreferenced versions and retains a translation's exact source revision", async () => {
    const db = env.handle.db;
    let b = await create();
    b = await edit(b, [{ op: "set", path: title, value: "Pinned source" }]);
    const pinned = b.revisionToken;
    await commitResumeTranslation(db, owner, b.familyId, {
      sourceLanguage: "fr",
      language: "en",
      sourceRevisionToken: pinned,
      expectedRevisionToken: null,
      idempotencyKey: randomUUID(),
      operations: [{ op: "set", path: title, value: "Pinned translation" }],
      baselines: {
        [title]: { sourceRevisionToken: pinned, sourceValue: "Pinned source", acceptedValue: "Pinned translation" },
      },
    });
    b = await edit(b, [{ op: "set", path: title, value: "Obsolete" }]);
    const pruned = b.revisionToken;
    for (let i = 0; i < 102; i++) b = await edit(b, [{ op: "set", path: title, value: "Revision " + i }]);
    expect(await listResumeHistory(db, owner, b.familyId)).toHaveLength(100);
    expect(
      (await getResume(db, owner, b.familyId, { revisionToken: pinned })).document.sections[0].entries[0].title,
    ).toBe("Pinned source");
    await expect(getResume(db, owner, b.familyId, { revisionToken: pruned })).rejects.toMatchObject({
      code: "RESUME_REVISION_NOT_FOUND",
    });
  });
  it("preserves the manual value of a deleted translated field for review and clears it on ID reuse", async () => {
    const db = env.handle.db;
    let b = await create();
    const translated = await commitResumeTranslation(db, owner, b.familyId, {
      sourceLanguage: "fr",
      language: "en",
      sourceRevisionToken: b.revisionToken,
      expectedRevisionToken: null,
      idempotencyKey: randomUUID(),
      operations: [{ op: "set", path: title, value: "Engineer" }],
      baselines: {
        [title]: { sourceRevisionToken: b.revisionToken, sourceValue: "Ingénieure", acceptedValue: "Engineer" },
      },
    });
    await edit(translated, [{ op: "set", path: title, value: "Manual title" }]);
    b = await edit(b, [{ op: "remove", path: entry }]);
    const detached = await get(translated);
    expect(detached.detachedWording[title]).toEqual("Manual title");
    expect(detached.document.sections[0].entries.some((e) => e.id === "job1")).toBe(false);
    b = await edit(b, [
      { op: "insert", path: "/sections/work/entries", value: { id: "job1", title: "Replacement", bullets: [] } },
    ]);
    const fresh = await get(translated);
    expect(fresh.detachedWording[title]).toBeUndefined();
    expect(fresh.translationBaselines[title]).toBeUndefined();
    expect(fresh.document.sections[0].entries.find((e) => e.id === "job1")?.title).toBe("Replacement");
    expect(
      (await getResume(db, owner, b.familyId, { language: "en", revisionToken: detached.revisionToken }))
        .detachedWording[title],
    ).toBe("Manual title");
  });
  it("compares and swaps a revision across independent database connections", async () => {
    const initial = await create();
    const info = await env.handle.client.execute("PRAGMA database_list");
    const other = createDatabase("file:" + info.rows[0].file);
    try {
      const writes = await Promise.allSettled(
        [env.handle.db, other.db].map((db, index) =>
          editResume(db, owner, initial.familyId, {
            expectedRevisionToken: initial.revisionToken,
            idempotencyKey: randomUUID(),
            operations: [{ op: "set", path: title, value: "Title " + index }],
          }),
        ),
      );
      expect(writes.map((w) => w.status).sort()).toEqual(["fulfilled", "rejected"]);
      expect(writes.find((w) => w.status === "rejected")).toMatchObject({
        reason: { code: "RESUME_REVISION_CONFLICT" },
      });
    } finally {
      other.close();
    }
  });
});
