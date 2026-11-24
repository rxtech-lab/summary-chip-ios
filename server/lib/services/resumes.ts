import { randomUUID } from "node:crypto";
import { and, desc, eq, inArray, lte, sql } from "drizzle-orm";
import { z } from "zod";
import type { TranslationLanguage } from "@/lib/contracts/api";
import {
  commitResumeTranslationSchema,
  createResumeSchema,
  createResumeVariantSchema,
  editResumeSchema,
  previewResumeRestoreSchema,
  restoreResumeSchema,
  resumeDocumentSchema,
  resumeTargetSchema,
  saveResumeTranslationSchema,
  type ResumeDocument,
  type ResumeOperation,
} from "@/lib/contracts/resume";
import type { Database } from "@/lib/db/client";
import {
  resumeAssets,
  resumePreviews,
  resumeRenderLeases,
  resumeProposals,
  resumeEditions,
  resumeFamilies,
  resumeRevisions,
  resumeVariants,
  summaries,
  users,
} from "@/lib/db/schema";
import { ApiError } from "@/lib/http/errors";
import {
  applyEdits,
  assemble,
  captureDeleted,
  collectItemIds,
  diffResume,
  editOverlay,
  emptyEdition,
  emptyOverlay,
  invalid,
  isWordingPath,
  resolveOverlay,
  rulePath,
  splitWording,
  under,
  type Edition,
  type Overlay,
  valueAt,
} from "@/lib/resume/editing";

import { directTranslationEdits, type DirectTranslation, type ProposalTranslation } from "@/lib/resume/direct-translation";
import { mutateResume, stableResumeJson, type ResumeTransaction } from "@/lib/resume/mutation";
import { collectUnusedResumeOutputs } from "@/lib/resume/retention";
import { generateSlug } from "@/lib/slug";

export { resumeTranslationFields } from "@/lib/resume/direct-translation";

type Reader = Pick<Database, "select">;
type Target = z.infer<typeof resumeTargetSchema>;
type Current = { revision: number; value: unknown };
type Variant = { id: string; company: string; targetRole?: string; jobDescription?: string };
type Family = {
  id: string;
  source: TranslationLanguage;
  title: string;
  revision: number;
  components: Map<string, Current>;
  variants: Variant[];
};
const structureKey = "structure";
const editionKey = (lang: string) => "edition/" + lang;
const overlayKey = (variant: string) => "variant/" + variant;
const noResume = () => new ApiError(404, "NOT_FOUND", "Résumé not found");
const noEdition = () => new ApiError(404, "RESUME_EDITION_NOT_FOUND", "This language edition does not exist");
const noRevision = () => new ApiError(404, "RESUME_REVISION_NOT_FOUND", "The selected résumé revision does not exist");
const conflict = (revisionToken: string | null) =>
  new ApiError(409, "RESUME_REVISION_CONFLICT", "The résumé changed. Reload the current revision.", { revisionToken });
const copy = <T>(value: T): T => structuredClone(value);
const component = <T>(family: Family, key: string): T => family.components.get(key)?.value as T;
const edition = (f: Family, lang: string): Edition => component(f, editionKey(lang));
const overlay = (f: Family, id: string): Overlay => component(f, overlayKey(id));
const languages = (f: Family) =>
  [...f.components.keys()].filter((k) => k.startsWith("edition/")).map((k) => k.slice(8) as TranslationLanguage);
const variants = (f: Family) => f.variants.filter((v) => f.components.has(overlayKey(v.id)));

type RevisionKey = [string, string | null, TranslationLanguage, number, number, number, number];
function unpack(token: string): RevisionKey {
  try {
    const a = JSON.parse(Buffer.from(token, "base64url").toString());
    if (Array.isArray(a) && a.length === 7 && a.slice(3).every((n) => Number.isSafeInteger(n) && n >= 0))
      return a as RevisionKey;
  } catch {}
  throw noRevision();
}
function tokenFor(f: Family, id: string | null, lang: TranslationLanguage) {
  const rev = (key: string) => f.components.get(key)?.revision ?? 0;
  const a: RevisionKey = [
    f.id,
    id,
    lang,
    rev(structureKey),
    rev(editionKey(f.source)),
    rev(editionKey(lang)),
    id ? rev(overlayKey(id)) : 0,
  ];
  return Buffer.from(JSON.stringify(a)).toString("base64url");
}

/** The max(revision) is taken per component before reading its payload, even for old previews. */
async function load(db: Reader, owner: string, familyId: string, at?: number, scope?: Target): Promise<Family> {
  const [header] = await db
    .select({
      id: resumeFamilies.id,
      source: resumeFamilies.sourceLanguage,
      title: summaries.title,
      revision: resumeFamilies.revision,
    })
    .from(resumeFamilies)
    .innerJoin(summaries, eq(summaries.id, resumeFamilies.id))
    .where(and(eq(resumeFamilies.id, familyId), eq(summaries.ownerId, owner), eq(summaries.kind, "resume")));
  if (!header) throw noResume();
  const epoch = at ?? header.revision;
  const latest = db
    .select({
      component: resumeRevisions.component,
      revision: sql<number>`max(${resumeRevisions.revision})`.as("last_revision"),
    })
    .from(resumeRevisions)
    .where(and(eq(resumeRevisions.familyId, familyId), lte(resumeRevisions.revision, epoch)))
    .groupBy(resumeRevisions.component)
    .as("latest");
  // Library selectors need every edition/company identity. Fetch the large JSON snapshots
  // only for components participating in this read. Subtree deletion requests all components.
  const selectedKeys = [structureKey, editionKey(header.source), editionKey(scope?.language ?? header.source)];
  if (scope?.variantId) selectedKeys.push(overlayKey(scope.variantId));
  const payload = scope
    ? sql`case when ${inArray(resumeRevisions.component, selectedKeys)} then ${resumeRevisions.payload} end`.mapWith(
        resumeRevisions.payload,
      )
    : resumeRevisions.payload;
  const rows = await db
    .select({ key: resumeRevisions.component, revision: resumeRevisions.revision, value: payload })
    .from(resumeRevisions)
    .innerJoin(
      latest,
      and(eq(latest.component, resumeRevisions.component), eq(latest.revision, resumeRevisions.revision)),
    )
    .where(eq(resumeRevisions.familyId, familyId));
  const meta = await db.select().from(resumeVariants).where(eq(resumeVariants.familyId, familyId));
  return {
    ...header,
    source: header.source as TranslationLanguage,
    revision: epoch,
    components: new Map(rows.map((r) => [r.key, { revision: r.revision, value: r.value }])),
    variants: meta.map((v) => ({
      id: v.id,
      company: v.company,
      ...(v.targetRole && { targetRole: v.targetRole }),
      ...(v.jobDescription && { jobDescription: v.jobDescription }),
    })),
  };
}
function base(f: Family, lang: TranslationLanguage) {
  if (!edition(f, lang)) throw noEdition();
  return assemble(component(f, structureKey), edition(f, f.source).words, edition(f, lang).words);
}
function resolve(f: Family, id: string | null, lang: TranslationLanguage) {
  const baseDocument = base(f, lang);
  const changes = id ? overlay(f, id) : emptyOverlay();
  if (!changes) throw noResume();
  const result = resolveOverlay(baseDocument, changes, lang);
  const local = edition(f, lang);
  const translationBaselines = (id ? changes.baselines[lang] : local.baselines) ?? {};
  if (lang !== f.source) {
    const sourceWords = edition(f, f.source).words;
    for (const path of new Set([...Object.keys(sourceWords), ...Object.keys(local.baselines)])) {
      if (
        (Object.hasOwn(changes.authored, path) && !changes.inherited?.[lang]?.[path]) ||
        valueAt(result.document, path) === undefined
      )
        continue;
      const baseline = local.baselines[path];
      const needsTranslation = !Object.hasOwn(local.words, path) && !baseline;
      const expectedSource =
        baseline?.canonicalSourceValue !== undefined ? baseline.canonicalSourceValue : baseline?.sourceValue;
      if (needsTranslation || (baseline && expectedSource !== (sourceWords[path] ?? null)))
        result.missingTranslationPaths.push(path);
    }
  }
  const baseRevision = Math.max(f.components.get(structureKey)!.revision, f.components.get(editionKey(lang))!.revision);
  const revisionToken = tokenFor(f, id, lang);
  const overridePaths = [
    ...new Set([
      ...changes.rules.map(rulePath),
      ...Object.keys(changes.authored).filter((path) => !changes.inherited?.[lang]?.[path]),
      ...Object.keys(changes.recoveries),
    ]),
  ];
  return {
    ...result,
    document: resumeDocumentSchema.parse(result.document),
    familyId: f.id,
    variantId: id,
    language: lang,
    sourceLanguage: f.source,
    title: f.title,
    revisionToken,
    baseRevisionToken: tokenFor(f, null, lang),
    baseRevision,
    variants: variants(f),
    languages: languages(f),
    overrideCount: overridePaths.length,
    overridePaths,
    inheritedPaths: Object.keys(changes.inherited?.[lang] ?? {}),
    translationBaselines,
    localizedWording: id ? (changes.words[lang] ?? {}) : local.words,
    detachedWording: id ? {} : (local.detached ?? {}),
    overrideSources: changes.authored,
  };
}
export type ResolvedResume = ReturnType<typeof resolve>;

async function snapshot(db: Reader, owner: string, familyId: string, target: Target, allComponents = false) {
  const key = target.revisionToken ? unpack(target.revisionToken) : null;
  if (
    key &&
    (key[0] !== familyId ||
      (target.variantId !== undefined && target.variantId !== key[1]) ||
      (target.language && target.language !== key[2]))
  )
    throw noRevision();
  const scope = { variantId: target.variantId ?? key?.[1], language: target.language ?? key?.[2] };
  const family = await load(
    db,
    owner,
    familyId,
    key ? Math.max(...(key.slice(3) as number[])) : undefined,
    allComponents ? undefined : scope,
  );
  const lang = target.language ?? key?.[2] ?? family.source;
  const id = target.variantId ?? key?.[1] ?? null;
  const result = resolve(family, id, lang);
  if (key && result.revisionToken !== target.revisionToken) throw noRevision();
  return { family, result };
}

export async function getResume(db: Database, owner: string, familyId: string, target: Target = {}) {
  return (await snapshot(db, owner, familyId, resumeTargetSchema.parse(target))).result;
}
export async function listResumes(db: Database, owner: string) {
  const rows = await db
    .select({
      familyId: resumeFamilies.id,
      title: summaries.title,
      language: resumeFamilies.sourceLanguage,
      updatedAt: summaries.updatedAt,
    })
    .from(summaries)
    .innerJoin(resumeFamilies, eq(resumeFamilies.id, summaries.id))
    .where(eq(summaries.ownerId, owner))
    .orderBy(desc(summaries.updatedAt));
  return rows.map((r) => ({ ...r, updatedAt: r.updatedAt.toISOString() }));
}

async function validateAsset(tx: Reader, familyId: string, doc: ResumeDocument) {
  if (!doc.avatarAssetId) return;
  const [asset] = await tx
    .select({ id: resumeAssets.id })
    .from(resumeAssets)
    .where(and(eq(resumeAssets.id, doc.avatarAssetId), eq(resumeAssets.familyId, familyId)));
  if (!asset) invalid("The selected avatar does not belong to this résumé");
}
async function writeComponent(
  tx: ResumeTransaction,
  f: Family,
  key: string,
  value: unknown,
  origin: "base" | "company",
  language: TranslationLanguage,
) {
  if (stableResumeJson(f.components.get(key)?.value) === stableResumeJson(value)) return;
  const revision = f.revision + 1;
  await tx
    .insert(resumeRevisions)
    .values({ familyId: f.id, component: key, revision, payload: value, origin, language });
  f.components.set(key, { revision, value });
}
async function finish(tx: ResumeTransaction, f: Family, id: string | null, lang: TranslationLanguage) {
  const result = resolve(f, id, lang);
  await validateAsset(tx, f.id, result.document);
  if ([...f.components.values()].some((c) => c.revision === f.revision + 1)) {
    await tx
      .update(resumeFamilies)
      .set({ revision: f.revision + 1 })
      .where(eq(resumeFamilies.id, f.id));
    await tx.update(summaries).set({ updatedAt: new Date() }).where(eq(summaries.id, f.id));
    if (f.revision >= 100) await pruneResumeRevisions(tx, f.id, f.source);
    else await collectUnusedResumeOutputs(tx, f.id);
  }
  return result;
}
export async function createResume(db: Database, owner: string, raw: z.input<typeof createResumeSchema>) {
  const input = createResumeSchema.parse(raw);
  return mutateResume(db, owner, input.idempotencyKey, ["create", input], async (tx) => {
    const id = randomUUID();
    await tx.insert(users).values({ id: owner }).onConflictDoNothing();
    await tx.insert(summaries).values({
      id,
      ownerId: owner,
      slug: generateSlug(),
      title: input.title,
      kind: "resume",
      visibility: "private",
      sourceType: "text",
      source: "text",
      summary: "",
      highlights: [],
      category: "Other",
      tags: [],
      keywords: [],
      language: input.language,
      theme: { colors: ["#283746", "#F1F3F4"], accent: "#283746", emoji: "📄", mode: "light" },
    });
    await tx.insert(resumeFamilies).values({ id, sourceLanguage: input.language, revision: 0 });
    await tx.insert(resumeEditions).values({ familyId: id, language: input.language });
    const f: Family = {
      id,
      source: input.language,
      revision: 0,
      title: input.title,
      components: new Map(),
      variants: [],
    };
    const parts = splitWording(input.document);
    await writeComponent(tx, f, structureKey, parts.structure, "base", input.language);
    await writeComponent(
      tx,
      f,
      editionKey(input.language),
      { words: parts.words, baselines: {} },
      "base",
      input.language,
    );
    return finish(tx, f, null, input.language);
  });
}
function verifyToken(f: Family, id: string | null, lang: TranslationLanguage, expected: string) {
  const current = resolve(f, id, lang);
  if (current.revisionToken !== expected) throw conflict(current.revisionToken);
}
async function applyBase(
  tx: ResumeTransaction,
  f: Family,
  lang: TranslationLanguage,
  ops: ResumeOperation[],
  baselines?: Edition["baselines"],
  restoring = false,
) {
  const before = base(f, lang);
  const document = applyEdits(before, ops);
  const old = splitWording(before),
    next = splitWording(document);
  const current = copy(edition(f, lang));
  const sourceEdition = copy(edition(f, f.source));
  for (const path of new Set([
    ...Object.keys(old.words),
    ...Object.keys(next.words),
    ...Object.keys(baselines ?? {}),
  ])) {
    if (next.words[path] !== old.words[path] || (baselines && Object.hasOwn(baselines, path)))
      current.words[path] = next.words[path] ?? null;
    if (
      lang !== f.source &&
      next.words[path] !== undefined &&
      !Object.hasOwn(sourceEdition.words, path) &&
      !Object.hasOwn(old.words, path)
    ) {
      sourceEdition.words[path] = next.words[path];
    }
  }
  Object.assign(current.baselines, baselines);
  for (const [path, baseline] of Object.entries(baselines ?? {})) {
    if (current.detached && Object.hasOwn(current.detached, path)) {
      if (baseline.acceptedValue === null) delete current.detached[path];
      else current.detached[path] = baseline.acceptedValue;
      delete current.words[path];
    }
  }
  const structuralChanges = diffResume(before, document);
  const removed = structuralChanges.filter((op) => op.op === "remove").map((op) => op.path);
  const added = structuralChanges.filter((op) => op.op === "insert").map((op) => op.path + "/" + op.value.id);
  if (removed.length || added.length) {
    const bases = Object.fromEntries(languages(f).map((l) => [l, base(f, l)]));
    const newIds = collectItemIds(added.map((path) => valueAt(document, path)));
    for (const variant of variants(f)) {
      const changes = copy(overlay(f, variant.id));
      for (const rule of changes.rules) {
        if (rule.edit.op !== "insert") continue;
        if ([...collectItemIds(rule.edit.value)].some((id) => newIds.has(id)))
          invalid("A new ID is already used by a company-only item in " + variant.company);
      }
      for (const [path, recovery] of Object.entries(changes.recoveries)) {
        const collides = [...collectItemIds(Object.values(recovery.values)[0])].some((id) => newIds.has(id));
        if (!collides) continue;
        if (restoring && added.some((root) => under(path, root))) delete changes.recoveries[path];
        else invalid("A new ID belongs to a recovered item in " + variant.company);
      }
      for (const path of removed) captureDeleted(changes, path, bases);
      await writeComponent(tx, f, overlayKey(variant.id), changes, "base", lang);
    }
  }
  if (removed.length || added.length) {
    for (const l of languages(f)) {
      const ed = l === lang ? current : l === f.source ? sourceEdition : copy(edition(f, l));
      const previous = edition(f, l);
      // A removed job immediately disappears in every edition. Preserve its target wording
      // outside the printable document until the next translation refresh resolves the deletion.
      for (const path of Object.keys(ed.words)) {
        if (!removed.some((root) => under(path, root))) continue;
        if (l !== f.source && Object.hasOwn(previous.words, path)) (ed.detached ??= {})[path] = previous.words[path];
        delete ed.words[path];
      }
      // A replacement reusing a former subtree ID may never acquire its old target text.
      for (const path of Object.keys(ed.detached ?? {})) {
        if (added.some((root) => under(path, root))) delete ed.detached![path];
      }
      for (const path of Object.keys(ed.baselines)) {
        if (added.some((root) => under(path, root))) delete ed.baselines[path];
      }
      if (l !== lang && l !== f.source) await writeComponent(tx, f, editionKey(l), ed, "base", lang);
    }
  }
  await writeComponent(tx, f, structureKey, next.structure, "base", lang);
  if (lang !== f.source) await writeComponent(tx, f, editionKey(f.source), sourceEdition, "base", lang);
  await writeComponent(tx, f, editionKey(lang), current, "base", lang);
  if (added.length || removed.length) {
    for (const language of languages(f)) {
      const baseDocument = base(f, language);
      for (const variant of variants(f)) {
        const merged = resolveOverlay(baseDocument, overlay(f, variant.id), language);
        if (!resumeDocumentSchema.safeParse(merged.document).success)
          invalid("The structural change exceeds document limits in " + variant.company + " (" + language + ")");
      }
    }
  }
}

export async function editResume(db: Database, owner: string, familyId: string, raw: z.input<typeof editResumeSchema>) {
  const input = editResumeSchema.parse(raw);
  return mutateResume(db, owner, input.idempotencyKey, ["edit", familyId, input], async (tx) => {
    const allComponents = !input.variantId && input.operations.some((op) => op.op === "remove" || op.op === "insert");
    const f = await load(tx, owner, familyId, undefined, allComponents ? undefined : input),
      id = input.variantId ?? null,
      lang = input.language ?? f.source;
    verifyToken(f, id, lang, input.expectedRevisionToken);
    if (id) {
      const changes = copy(overlay(f, id));
      editOverlay(base(f, lang), changes, lang, input.operations);
      await writeComponent(tx, f, overlayKey(id), changes, "company", lang);
    } else await applyBase(tx, f, lang, input.operations);
    return finish(tx, f, id, lang);
  });
}
export async function previewResumeVariant(
  db: Database,
  owner: string,
  familyId: string,
  target: { sourceRevisionToken: string; language?: TranslationLanguage },
) {
  const source = await snapshot(db, owner, familyId, {
    revisionToken: target.sourceRevisionToken,
    language: target.language,
  });
  const current = await load(db, owner, familyId);
  const working = resolve(current, null, source.result.language);
  return {
    familyId,
    variantId: working.variantId,
    language: working.language,
    revisionToken: working.revisionToken,
    operations: diffResume(working.document, source.result.document),
  };
}
export async function createResumeVariant(
  db: Database,
  owner: string,
  familyId: string,
  raw: z.input<typeof createResumeVariantSchema>,
) {
  const input = createResumeVariantSchema.parse(raw);
  return mutateResume(db, owner, input.idempotencyKey, ["variant", familyId, input], async (tx) => {
    const f = await load(tx, owner, familyId),
      lang = input.language ?? (input.sourceRevisionToken ? unpack(input.sourceRevisionToken)[2] : f.source);
    verifyToken(f, null, lang, input.expectedRevisionToken);
    const changes = emptyOverlay();
    if (input.sourceRevisionToken) {
      const source = await snapshot(tx, owner, familyId, { language: lang, revisionToken: input.sourceRevisionToken });
      const baseDoc = base(f, lang);
      const selected = new Set(input.acceptedPaths ?? []);
      const ops = diffResume(baseDoc, source.result.document).filter((op) =>
        selected.has(op.op === "insert" ? op.path + "/" + op.value.id : op.path),
      );
      editOverlay(baseDoc, changes, lang, ops);
    } else if (input.acceptedPaths?.length) invalid("Selecting differences requires a source revision");
    const variant = {
      id: randomUUID(),
      company: input.company,
      targetRole: input.targetRole,
      jobDescription: input.jobDescription,
    };
    await tx.insert(resumeVariants).values({ ...variant, familyId });
    f.variants.push(variant);
    await writeComponent(tx, f, overlayKey(variant.id), changes, "company", lang);
    return finish(tx, f, variant.id, lang);
  });
}

export async function listResumeHistory(db: Database, owner: string, familyId: string, target: Target = {}) {
  const { family: f, result } = await snapshot(db, owner, familyId, resumeTargetSchema.parse(target));
  const keys = [structureKey, editionKey(result.language), editionKey(f.source)];
  if (result.variantId) keys.push(overlayKey(result.variantId));
  const rows = await db
    .select({
      revision: resumeRevisions.revision,
      key: resumeRevisions.component,
      origin: resumeRevisions.origin,
      language: resumeRevisions.language,
      createdAt: resumeRevisions.createdAt,
    })
    .from(resumeRevisions)
    .where(
      and(
        eq(resumeRevisions.familyId, familyId),
        inArray(resumeRevisions.component, keys),
        lte(resumeRevisions.revision, f.revision),
      ),
    )
    .orderBy(resumeRevisions.revision);
  const components = new Map<string, Current>();
  const history = new Map<
    number,
    { revision: number; revisionToken: string; origin: string; language: string; createdAt: string }
  >();
  for (const r of rows) {
    components.set(r.key, { revision: r.revision, value: null });
    if (
      !components.has(structureKey) ||
      !components.has(editionKey(result.language)) ||
      (result.variantId && !components.has(overlayKey(result.variantId)))
    )
      continue;
    history.set(r.revision, {
      revision: r.revision,
      revisionToken: tokenFor({ ...f, components }, result.variantId, result.language),
      origin: r.origin,
      language: r.language,
      createdAt: r.createdAt.toISOString(),
    });
  }
  return [...history.values()].reverse().slice(0, 100);
}
async function restorePreview(
  tx: Reader,
  owner: string,
  familyId: string,
  input: z.infer<typeof previewResumeRestoreSchema>,
) {
  const historicalTarget = unpack(input.revisionToken);
  const f = await load(tx, owner, familyId),
    lang = input.language ?? historicalTarget[2],
    id = input.variantId === undefined ? historicalTarget[1] : input.variantId;
  const old = await snapshot(
    tx,
    owner,
    familyId,
    { language: lang, variantId: id, revisionToken: input.revisionToken },
    true,
  );
  const current = resolve(f, id, lang);
  const restored = id ? copy(overlay(old.family, id)) : undefined;
  if (restored) {
    const originalBases = Object.fromEntries(languages(old.family).map((l) => [l, base(old.family, l)]));
    for (const op of diffResume(originalBases[lang], base(f, lang))) {
      if (op.op === "remove") captureDeleted(restored, op.path, originalBases);
    }
  }
  const proposed = restored ? resolveOverlay(base(f, lang), restored, lang).document : old.result.document;
  const changes = diffResume(current.document, proposed);
  return { f, id, lang, current, restored, proposed, changes };
}
export async function previewResumeRestore(
  db: Database,
  owner: string,
  familyId: string,
  raw: z.infer<typeof previewResumeRestoreSchema>,
) {
  const { f, id, current, proposed, changes } = await restorePreview(
    db,
    owner,
    familyId,
    previewResumeRestoreSchema.parse(raw),
  );
  const affectedVariants = [];
  if (!id) {
    const bases = Object.fromEntries(languages(f).map((language) => [language, base(f, language)]));
    for (const variant of variants(f)) {
      const inherited = overlay(f, variant.id);
      const projected = copy(inherited);
      for (const change of changes) if (change.op === "remove") captureDeleted(projected, change.path, bases);
      const before = resolveOverlay(current.document, inherited, current.language);
      const after = resolveOverlay(proposed, projected, current.language);
      const operations = diffResume(before.document, after.document);
      const newlyFlagged = after.reviewPaths.filter((path) => !before.reviewPaths.includes(path));
      const recoverablePaths = after.recoverablePaths.filter((path) => !before.recoverablePaths.includes(path));
      if (operations.length || newlyFlagged.length || recoverablePaths.length) {
        affectedVariants.push({
          ...variant,
          language: current.language,
          operations,
          reviewPaths: newlyFlagged,
          recoverablePaths,
        });
      }
    }
  }
  return {
    familyId,
    variantId: id,
    language: current.language,
    document: proposed,
    operations: changes,
    revisionToken: current.revisionToken,
    affectedVariants,
  };
}
export async function restoreResume(
  db: Database,
  owner: string,
  familyId: string,
  raw: z.infer<typeof restoreResumeSchema>,
) {
  const input = restoreResumeSchema.parse(raw);
  return mutateResume(db, owner, input.idempotencyKey, ["restore", familyId, input], async (tx) => {
    const { f, id, lang, restored, current, changes } = await restorePreview(tx, owner, familyId, input);
    if (current.revisionToken !== input.expectedRevisionToken) throw conflict(current.revisionToken);
    if (id && restored) await writeComponent(tx, f, overlayKey(id), restored, "company", lang);
    else await applyBase(tx, f, lang, changes, undefined, true);
    return finish(tx, f, id, lang);
  });
}

export async function saveResumeTranslation(db: Database, owner: string, familyId: string, raw: DirectTranslation) {
  return persistTranslation(db, owner, familyId, saveResumeTranslationSchema.parse(raw));
}

export async function commitResumeTranslation(
  db: Database,
  owner: string,
  familyId: string,
  raw: ProposalTranslation,
) {
  return persistTranslation(db, owner, familyId, commitResumeTranslationSchema.parse(raw));
}

function persistTranslation(
  db: Database,
  owner: string,
  familyId: string,
  request: DirectTranslation | ProposalTranslation,
) {
  const kind = "translations" in request ? "direct-translation" : "translation";
  return mutateResume(db, owner, request.idempotencyKey, [kind, familyId, request], async (tx) => {
    const f = await load(tx, owner, familyId);
    const id = request.variantId ?? null;
    const lang = request.language;
    if (lang === request.sourceLanguage) invalid("Choose a different target language");
    const source = resolve(f, id, request.sourceLanguage);
    if (source.revisionToken !== request.sourceRevisionToken) throw conflict(source.revisionToken);
    const exists = !!edition(f, lang);
    const current = exists ? resolve(f, id, lang).revisionToken : null;
    if (request.expectedRevisionToken !== current) throw conflict(current);
    const input =
      "translations" in request
        ? directTranslationEdits(
            request,
            source,
            edition(f, f.source).words,
            id && !exists ? resolve(f, null, request.sourceLanguage) : undefined,
          )
        : request;
    if (!exists) {
      if (id && !input.baseOperations) invalid("A new company translation requires base wording");
      await tx.insert(resumeEditions).values({ familyId, language: lang });
      f.components.set(editionKey(lang), { revision: 0, value: emptyEdition() });
    }
    const allOps = [...input.operations, ...(input.baseOperations ?? [])];
    if (allOps.some((op) => op.op !== "set" || !isWordingPath(op.path)))
      invalid("Translations may only change wording");
    if (exists && input.baseOperations?.length) invalid("The base edition already exists");
    // A source deletion can remove the entire structural parent before translation refresh.
    const applicable = (doc: ResumeDocument, ops: ResumeOperation[]) =>
      ops.filter((op) => !(op.op === "set" && op.value === null && valueAt(doc, op.path) === undefined));
    if (!id || !exists) {
      const ops = id ? (input.baseOperations ?? []) : input.operations;
      await applyBase(tx, f, lang, applicable(base(f, lang), ops), id ? input.baseBaselines : input.baselines);
      if (!exists && f.components.get(editionKey(lang))?.revision === 0) {
        f.components.delete(editionKey(lang));
        await writeComponent(tx, f, editionKey(lang), emptyEdition(), "base", lang);
      }
    }
    if (id) {
      const changes = copy(overlay(f, id));
      const baseDoc = base(f, lang);
      if (!exists && "translations" in request && source.inheritedPaths.length) {
        (changes.inherited ??= {})[lang] = Object.fromEntries(source.inheritedPaths.map((path) => [path, true]));
      }
      editOverlay(
        baseDoc,
        changes,
        lang,
        applicable(resolveOverlay(baseDoc, changes, lang).document, input.operations),
        true,
      );
      if (input.baselines) Object.assign((changes.baselines[lang] ??= {}), input.baselines);
      await writeComponent(tx, f, overlayKey(id), changes, "company", lang);
    }
    return finish(tx, f, id, lang);
  });
}

/** Keep independently resolvable history even when one component changes far more often than others. */
export async function pruneResumeRevisions(tx: ResumeTransaction, familyId: string, sourceLanguage: TranslationLanguage) {
  await collectUnusedResumeOutputs(tx, familyId);
  const rows = await tx
    .select({
      key: resumeRevisions.component,
      revision: resumeRevisions.revision,
      sourceTokens: sql<string>`(select json_group_array(distinct atom)
        from json_tree(${resumeRevisions.payload}, '$.baselines') where key='sourceRevisionToken')`,
    })
    .from(resumeRevisions)
    .where(eq(resumeRevisions.familyId, familyId))
    .orderBy(resumeRevisions.revision);
  const streams = new Map<string, typeof rows>();
  for (const row of rows) {
    const stream = streams.get(row.key) ?? [];
    stream.push(row);
    streams.set(row.key, stream);
  }
  if ([...streams.values()].every((rows) => rows.length <= 100)) return;
  const keep = new Set<(typeof rows)[number]>();
  const epochs = new Set([...streams.values()].flatMap((stream) => stream.slice(-100).map((r) => r.revision)));
  // Every retained event can be viewed in a company and language that existed at the time.
  const orderedEpochs = [...epochs].sort((a, b) => a - b);
  for (const stream of streams.values()) {
    let i = -1;
    for (const epoch of orderedEpochs) {
      while (i + 1 < stream.length && stream[i + 1].revision <= epoch) i++;
      if (i >= 0) keep.add(stream[i]);
    }
  }
  const processedTokens = new Set<string>();
  function retainToken(token: string) {
    if (processedTokens.has(token)) return;
    processedTokens.add(token);
    // A render lease can briefly exist for a token that the resolver will reject.
    let key: RevisionKey;
    try {
      key = unpack(token);
    } catch {
      return;
    }
    const [family, id, lang, s, b, e, v] = key;
    if (family !== familyId) return;
    const pairs: Array<[string, number]> = [
      [structureKey, s],
      [editionKey(sourceLanguage), b],
      [editionKey(lang), e],
    ];
    if (id) pairs.push([overlayKey(id), v]);
    for (const [key, revision] of pairs) {
      const row = streams.get(key)?.find((r) => r.revision === revision);
      if (row) keep.add(row);
    }
  }
  const previews = await tx
    .select({ token: resumePreviews.revisionToken })
    .from(resumePreviews)
    .where(eq(resumePreviews.familyId, familyId));
  for (const preview of previews) retainToken(preview.token);
  const leases = await tx
    .select({ token: resumeRenderLeases.revisionToken })
    .from(resumeRenderLeases)
    .where(eq(resumeRenderLeases.familyId, familyId));
  for (const lease of leases) retainToken(lease.token);
  const proposals = await tx
    .select({ input: resumeProposals.input, target: resumeProposals.targetToken })
    .from(resumeProposals)
    .where(
      and(eq(resumeProposals.familyId, familyId), inArray(resumeProposals.status, ["queued", "running", "ready"])),
    );
  for (const proposal of proposals) {
    retainToken(proposal.input.expectedRevisionToken);
    if (proposal.target) retainToken(proposal.target);
  }
  // Set iteration visits newly added rows and follows translation dependencies transitively.
  for (const row of keep) {
    for (const token of JSON.parse(row.sourceTokens) as string[]) retainToken(token);
  }
  for (const [key, stream] of streams) {
    const discard = stream.filter((r) => !keep.has(r)).map((r) => r.revision);
    for (let i = 0; i < discard.length; i += 100) {
      await tx
        .delete(resumeRevisions)
        .where(
          and(
            eq(resumeRevisions.familyId, familyId),
            eq(resumeRevisions.component, key),
            inArray(resumeRevisions.revision, discard.slice(i, i + 100)),
          ),
        );
    }
  }
}
