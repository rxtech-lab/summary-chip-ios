import { createHash } from "node:crypto";
import { and, asc, desc, eq, or, exists } from "drizzle-orm";
import sharp from "sharp";
import { z } from "zod";
import { patchShareLinkSchema, createUploadSchema, TRANSLATION_LANGUAGES } from "@/lib/contracts/api";
import { expiresAtFor } from "@/lib/config";
import type { Database } from "@/lib/db/client";
import {
  resumeRenderLeases,
  resumeAssets,
  resumeArtifactChunks,
  resumePreviews,
  resumePublications,
  resumePublicationWrites,
  resumePublicationViews,
  shareLinks,
  shareLinkEmails,
  type ShareLinkRow,
} from "@/lib/db/schema";
import { ApiError, notFound } from "@/lib/http/errors";
import { renderPdf } from "@/lib/pdf/browser-pdf";
import { displaysAvatar, presentationSchema, renderResumeHtml, renderResumeDocx } from "@/lib/resume/render";
import { getObjectStore } from "@/lib/storage/r2";
import { freshToken, listShareLinks, mapShareLimit, toShareLinkJson, type ShareLinkJson } from "./share-links";
import { shareViewerEmail, isShareLinkLive, type ShareViewer } from "./share-access";
import { getResume } from "./resumes";
import { getOwnedSummary } from "./summaries";
import { createUpload, getCompletedUpload } from "./uploads";

export const resumePreviewSchema = z
  .object({
    variantId: z.string().nullish(),
    language: z.enum(TRANSLATION_LANGUAGES),
    revisionToken: z.string().min(1).max(4096),
    presentation: presentationSchema,
  })
  .strict();
export const resumePublicationSchema = patchShareLinkSchema
  .safeExtend({
    previewId: z.string().min(1),
    linkId: z.string().min(1).optional(),
    expectedPreviewId: z.string().min(1).optional(),
    acceptedWordingPaths: z.array(z.string().min(1).max(1024)).max(10000).default([]),
    idempotencyKey: z.string().min(1).max(128),
  })
  .refine((x) => x.linkId || x.access !== "invited" || x.emails?.length, "An invited link requires at least one email")
  .refine((x) => x.ttlDays !== null, "Résumé links require an expiry")
  .refine((x) => !x.linkId || x.expectedPreviewId, "Republishing requires the currently published preview ID");

async function ownedFamily(db: Database, ownerId: string, familyId: string) {
  const row = await getOwnedSummary(db, familyId, ownerId);
  if (row.kind !== "resume") throw notFound("Résumé not found");
}
export async function avatarBytes(db: Database, familyId: string, id: string) {
  const [asset] = await db
    .select({ bytes: resumeAssets.bytes })
    .from(resumeAssets)
    .where(and(eq(resumeAssets.id, id), eq(resumeAssets.familyId, familyId)))
    .limit(1);
  if (!asset) throw notFound("Avatar not found");
  return asset.bytes;
}
export async function getOwnerAvatar(db: Database, ownerId: string, familyId: string, id: string) {
  await ownedFamily(db, ownerId, familyId);
  return avatarBytes(db, familyId, id);
}

export const avatarUploadSchema = createUploadSchema
  .extend({
    mimeType: z.enum(["image/jpeg", "image/png"]),
    byteSize: z
      .number()
      .int()
      .positive()
      .max(4 * 1024 * 1024),
  })
  .strict();

export async function stageResumeAvatar(
  db: Database,
  ownerId: string,
  familyId: string,
  input: z.input<typeof avatarUploadSchema>,
) {
  await ownedFamily(db, ownerId, familyId);
  return createUpload(db, ownerId, avatarUploadSchema.parse(input), getObjectStore(), "resume-uploads");
}
export async function importResumeAvatar(db: Database, ownerId: string, familyId: string, key: string) {
  await ownedFamily(db, ownerId, familyId);
  const existing = () =>
    db
      .select({ id: resumeAssets.id })
      .from(resumeAssets)
      .where(and(eq(resumeAssets.familyId, familyId), eq(resumeAssets.sourceKey, key)))
      .limit(1);
  const [found] = await existing();
  if (found) return found;
  const store = getObjectStore();
  const limit = 4 * 1024 * 1024;
  const { upload, mimeType } = await getCompletedUpload(db, ownerId, key, store, limit, "resume-uploads");
  const { bytes } = await store.get(key);
  if (bytes.length !== upload.byteSize || bytes.length > limit)
    throw new ApiError(400, "INVALID_AVATAR", "Invalid image size");
  let jpeg: Buffer;
  try {
    const decoder = sharp(bytes, { limitInputPixels: 16_000_000, failOn: "warning" });
    const meta = await decoder.metadata();
    if (
      !["jpeg", "png"].includes(meta.format) ||
      mimeType !== "image/" + meta.format ||
      !meta.width ||
      !meta.height ||
      meta.width * meta.height > 16_000_000 ||
      (meta.pages ?? 1) > 1
    )
      throw new Error();
    jpeg = await decoder
      .rotate()
      .resize(512, 512, { fit: "cover" })
      .flatten({ background: "#ffffff" })
      .jpeg({ quality: 84 })
      .toBuffer();
  } catch {
    throw new ApiError(422, "INVALID_AVATAR", "Choose a JPEG or PNG image up to 4 MB and 16 megapixels");
  }
  const id = crypto.randomUUID();
  await db
    .insert(resumeAssets)
    .values({ id, familyId, sourceKey: key, bytes: jpeg, mimeType: "image/jpeg" })
    .onConflictDoNothing();
  const result = (await existing())[0];
  await store.delete(key);
  return result;
}

type Preview = typeof resumePreviews.$inferSelect;
function handles(
  p: Pick<Preview, "id" | "familyId" | "revisionToken" | "language" | "variantId" | "missingTranslationPaths">,
) {
  const base = "/api/v1/resumes/" + encodeURIComponent(p.familyId) + "/artifacts/" + encodeURIComponent(p.id);
  return {
    id: p.id,
    familyId: p.familyId,
    revisionToken: p.revisionToken,
    variantId: p.variantId,
    language: p.language,
    missingTranslationPaths: p.missingTranslationPaths,
    pdfUrl: base + "/pdf",
    docxUrl: base + "/docx",
  };
}
const hash = (value: unknown) => createHash("sha256").update(JSON.stringify(value)).digest("hex");
async function previewById(db: Database, familyId: string, id: string) {
  const [preview] = await db
    .select()
    .from(resumePreviews)
    .where(and(eq(resumePreviews.familyId, familyId), eq(resumePreviews.id, id)))
    .limit(1);
  return preview;
}

export async function prepareResumePreview(
  db: Database,
  ownerId: string,
  familyId: string,
  input: z.input<typeof resumePreviewSchema>,
) {
  const options = resumePreviewSchema.parse(input);
  await ownedFamily(db, ownerId, familyId);
  const id = hash([familyId, options.variantId ?? null, options.language, options.revisionToken, options.presentation]);
  const cached = await previewById(db, familyId, id);
  if (cached) return handles(cached);
  const leaseId = crypto.randomUUID();
  await db.insert(resumeRenderLeases).values({
    id: leaseId,
    familyId,
    revisionToken: options.revisionToken,
    expiresAt: new Date(Date.now() + 5 * 60_000),
  });
  try {
    return await renderPreview(db, ownerId, familyId, id, leaseId, options);
  } finally {
    await db.delete(resumeRenderLeases).where(eq(resumeRenderLeases.id, leaseId));
  }
}
async function renderPreview(
  db: Database,
  ownerId: string,
  familyId: string,
  id: string,
  leaseId: string,
  options: z.infer<typeof resumePreviewSchema>,
) {
  const state = await getResume(db, ownerId, familyId, {
    variantId: options.variantId ?? null,
    language: options.language,
    revisionToken: options.revisionToken,
  });
  const { document, revisionToken, language, variantId, missingTranslationPaths } = state;
  const presentation = options.presentation;
  const assetId = displaysAvatar(presentation) ? (document.avatarAssetId ?? null) : null;
  if (assetId) await db.update(resumeRenderLeases).set({ assetId }).where(eq(resumeRenderLeases.id, leaseId));
  const avatar = assetId ? await avatarBytes(db, familyId, assetId) : undefined;
  const html = renderResumeHtml(
    document,
    presentation,
    language,
    avatar && "data:image/jpeg;base64," + avatar.toString("base64"),
  );
  const pdf = await renderPdf(html, {
    margin: { top: "18mm", bottom: "18mm", left: "18mm", right: "18mm" },
    paperSize: presentation.paperSize,
    headerTemplate: "",
    footerTemplate: "",
    displayHeaderFooter: false,
    serverInlinedImages: true,
  });
  const docx = renderResumeDocx(document, presentation, language, avatar);
  const preview = {
    id,
    familyId,
    language,
    revisionToken,
    variantId,
    document,
    presentation,
    assetId,
    missingTranslationPaths,
    html: renderResumeHtml(document, presentation, language, assetId ? "__resume_avatar__" : undefined),
    createdAt: new Date(),
  };
  const operations = [];
  for (const [format, bytes] of [
    ["pdf", pdf],
    ["docx", docx],
  ] as const) {
    for (let offset = 0; offset < bytes.length; offset += 256 * 1024) {
      operations.push(
        db.insert(resumeArtifactChunks).values({
          previewId: id,
          format,
          ordinal: offset,
          bytes: Buffer.from(bytes.subarray(offset, offset + 256 * 1024)),
        }),
      );
    }
  }
  try {
    await db.batch([db.insert(resumePreviews).values(preview), ...operations]);
  } catch (error) {
    const concurrent = await previewById(db, familyId, id);
    if (concurrent) return handles(concurrent);
    throw error;
  }
  return handles(preview);
}

export const artifactMime = {
  pdf: "application/pdf",
  docx: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
};
export async function artifactBytes(db: Database, id: string, format: "pdf" | "docx") {
  const chunks = await db
    .select({ bytes: resumeArtifactChunks.bytes })
    .from(resumeArtifactChunks)
    .where(and(eq(resumeArtifactChunks.previewId, id), eq(resumeArtifactChunks.format, format)))
    .orderBy(asc(resumeArtifactChunks.ordinal));
  if (!chunks.length) throw notFound("Artifact not found");
  return Buffer.concat(chunks.map((c) => c.bytes));
}
export async function ownerArtifact(
  db: Database,
  ownerId: string,
  familyId: string,
  id: string,
  format: "pdf" | "docx",
) {
  await ownedFamily(db, ownerId, familyId);
  if (!(await previewById(db, familyId, id))) throw notFound();
  return artifactBytes(db, id, format);
}

type PublicationResult = ShareLinkJson & {
  previewId: string;
  familyId: string;
  variantId: string | null;
  language: string;
  revisionToken: string;
};
const publicationQueue = new WeakMap<Database, Promise<unknown>>();

export async function publishResumePreview(
  db: Database,
  ownerId: string,
  familyId: string,
  input: z.input<typeof resumePublicationSchema>,
  now = new Date(),
): Promise<PublicationResult> {
  const prior = publicationQueue.get(db) ?? Promise.resolve();
  const task = prior
    .catch(() => {})
    .then(async () => {
      for (let attempt = 0; ; attempt++) {
        try {
          return await commitPublication(db, ownerId, familyId, input, now);
        } catch (error) {
          const cause = error as { code?: string; cause?: { code?: string } };
          if (attempt >= 4 || ![cause.code, cause.cause?.code].includes("SQLITE_BUSY")) throw error;
          await new Promise((done) => setTimeout(done, 25 * (attempt + 1)));
        }
      }
    });
  publicationQueue.set(db, task);
  try {
    return await task;
  } finally {
    if (publicationQueue.get(db) === task) publicationQueue.delete(db);
  }
}

async function commitPublication(
  db: Database,
  ownerId: string,
  familyId: string,
  input: z.input<typeof resumePublicationSchema>,
  now: Date,
): Promise<PublicationResult> {
  const options = resumePublicationSchema.parse(input);
  await ownedFamily(db, ownerId, familyId);
  const digest = hash(options);
  const key = and(
    eq(resumePublicationWrites.familyId, familyId),
    eq(resumePublicationWrites.key, options.idempotencyKey),
  );
  async function replay() {
    const [prior] = await db.select().from(resumePublicationWrites).where(key).limit(1);
    if (!prior) return null;
    if (prior.digest !== digest)
      throw new ApiError(409, "IDEMPOTENCY_CONFLICT", "This key was used for another publication");
    return JSON.parse(prior.result) as PublicationResult;
  }
  const prior = await replay();
  if (prior) return prior;
  const preview = await previewById(db, familyId, options.previewId);
  if (!preview) throw notFound("Preview not found");
  const missing = new Set(preview.missingTranslationPaths);
  const accepted = new Set(options.acceptedWordingPaths);
  if (accepted.size !== missing.size || [...missing].some((path) => !accepted.has(path))) {
    throw new ApiError(
      409,
      "RESUME_WORDING_REVIEW_REQUIRED",
      "Approve the displayed wording for each untranslated field before publishing",
      { paths: [...missing] },
    );
  }
  const ttlDays = options.ttlDays ?? 7;
  const link: ShareLinkRow = {
    id: options.linkId ?? crypto.randomUUID(),
    summaryId: familyId,
    token: "",
    ttlDays,
    expiresAt: expiresAtFor(ttlDays, now),
    access: options.access ?? "anyone",
    label: options.label ?? null,
    updatedAt: now,
    createdAt: now,
  };
  if (!options.linkId) link.token = await freshToken(db, "resume");
  let emails = (options.emails ?? []).map((email) => ({ linkId: link.id, email, addedAt: now }));
  try {
    return await db.transaction(
      async (tx) => {
        if (options.linkId) {
          const [found] = await tx
            .select({ link: shareLinks, previewId: resumePublications.previewId })
            .from(shareLinks)
            .innerJoin(resumePublications, eq(resumePublications.linkId, shareLinks.id))
            .where(and(eq(shareLinks.id, link.id), eq(shareLinks.summaryId, familyId)))
            .limit(1);
          if (!found) throw notFound("Published link not found");
          if (found.previewId !== options.expectedPreviewId)
            throw new ApiError(409, "PUBLICATION_CONFLICT", "The link has been republished", {
              previewId: found.previewId,
            });
          link.access = options.access ?? found.link.access;
          if (options.label === undefined) link.label = found.link.label;
          if (options.ttlDays === undefined) {
            link.ttlDays = found.link.ttlDays;
            link.expiresAt = found.link.expiresAt;
          }
          if (options.emails === undefined) {
            emails = await tx.select().from(shareLinkEmails).where(eq(shareLinkEmails.linkId, link.id));
          }
          if (link.access === "invited" && !emails.length)
            throw new ApiError(400, "INVITATION_REQUIRED", "An invited link requires at least one email");
          link.token = found.link.token;
          link.createdAt = found.link.createdAt;
          await tx
            .update(resumePublications)
            .set({ previewId: preview.id })
            .where(eq(resumePublications.linkId, link.id));
          await tx
            .update(shareLinks)
            .set({
              ttlDays: link.ttlDays,
              expiresAt: link.expiresAt,
              label: link.label,
              access: link.access,
              updatedAt: now,
            })
            .where(eq(shareLinks.id, link.id));
          await tx.delete(shareLinkEmails).where(eq(shareLinkEmails.linkId, link.id));
        } else {
          await tx.insert(shareLinks).values(link);
          await tx.insert(resumePublications).values({ linkId: link.id, previewId: preview.id });
        }
        if (emails.length) await tx.insert(shareLinkEmails).values(emails);
        const result = {
          ...toShareLinkJson(link, emails, now),
          previewId: preview.id,
          familyId,
          language: preview.language,
          variantId: preview.variantId,
          revisionToken: preview.revisionToken,
        };
        await tx
          .insert(resumePublicationWrites)
          .values({ familyId, key: options.idempotencyKey, digest, result: JSON.stringify(result) });
        return result;
      },
      { behavior: "immediate" },
    );
  } catch (error) {
    const concurrent = await replay();
    if (concurrent) return concurrent;
    throw mapShareLimit(error);
  }
}

/** Bound link only. Generic share access deliberately declines every résumé family. */
export async function resolveResumePublication(db: Database, token: string, viewer: ShareViewer | null, now?: Date) {
  const binding = (invitedEmail?: string) =>
    db
      .select({ link: shareLinks, preview: resumePreviews })
      .from(shareLinks)
      .innerJoin(resumePublications, eq(shareLinks.id, resumePublications.linkId))
      .innerJoin(
        resumePreviews,
        and(eq(resumePublications.previewId, resumePreviews.id), eq(shareLinks.summaryId, resumePreviews.familyId)),
      )
      .where(
        and(
          eq(shareLinks.token, token),
          invitedEmail === undefined
            ? undefined
            : or(
                eq(shareLinks.access, "anyone"),
                exists(
                  db
                    .select({ id: shareLinkEmails.linkId })
                    .from(shareLinkEmails)
                    .where(and(eq(shareLinkEmails.linkId, shareLinks.id), eq(shareLinkEmails.email, invitedEmail))),
                ),
              ),
        ),
      )
      .limit(1);
  const [bound] = await binding();
  if (!bound || !isShareLinkLive(bound.link, now)) return { status: "missing" } as const;
  if (bound.link.access === "invited") {
    if (!viewer) return { status: "sign-in" } as const;
    const email = await shareViewerEmail(db, viewer);
    if (!email) return { status: "forbidden" } as const;
    // Identity-provider lookups can take time. Read the live binding and invitation together
    // afterwards, so a concurrent revocation or republish takes effect before returning content.
    const [authorized] = await binding(email);
    if (!authorized) return { status: "forbidden" } as const;
    if (!isShareLinkLive(authorized.link, now)) return { status: "missing" } as const;
    return { status: "ok", ...authorized } as const;
  }
  return { status: "ok", ...bound } as const;
}

export function recipientDocument(preview: Preview, slug: string) {
  const base = "/s/" + encodeURIComponent(slug);
  const document = { ...preview.document };
  if (!preview.assetId) delete document.avatarAssetId;
  return {
    familyId: preview.familyId,
    variantId: preview.variantId,
    language: preview.language,
    revisionToken: preview.revisionToken,
    document,
    presentation: preview.presentation,
    pdfUrl: base + "/resume.pdf",
    avatarUrl: preview.assetId ? base + "/avatar/" + encodeURIComponent(preview.assetId) : null,
  };
}

export async function rememberPublication(db: Database, userId: string, linkId: string) {
  const viewedAt = new Date();
  await db
    .insert(resumePublicationViews)
    .values({ userId, linkId, viewedAt })
    .onConflictDoUpdate({
      target: [resumePublicationViews.userId, resumePublicationViews.linkId],
      set: { viewedAt },
    });
}

export async function listViewedPublications(db: Database, viewer: ShareViewer) {
  const rows = await db
    .select({ token: shareLinks.token, viewedAt: resumePublicationViews.viewedAt })
    .from(resumePublicationViews)
    .innerJoin(shareLinks, eq(shareLinks.id, resumePublicationViews.linkId))
    .where(eq(resumePublicationViews.userId, viewer.id))
    .orderBy(desc(resumePublicationViews.viewedAt));
  const items = [];
  for (const row of rows) {
    const bound = await resolveResumePublication(db, row.token, viewer);
    if (bound.status !== "ok") continue;
    const p = bound.preview;
    items.push({
      slug: row.token,
      familyId: p.familyId,
      variantId: p.variantId,
      language: p.language,
      revisionToken: p.revisionToken,
      title: p.document.candidateName,
      viewedAt: row.viewedAt.toISOString(),
      pdfUrl: "/s/" + row.token + "/resume.pdf",
    });
  }
  return { items };
}

export async function listResumePublications(db: Database, ownerId: string, familyId: string) {
  await ownedFamily(db, ownerId, familyId);
  const { items } = await listShareLinks(db, ownerId, familyId);
  const rows = await db
    .select({
      linkId: resumePublications.linkId,
      previewId: resumePreviews.id,
      revisionToken: resumePreviews.revisionToken,
      language: resumePreviews.language,
      variantId: resumePreviews.variantId,
    })
    .from(resumePublications)
    .innerJoin(resumePreviews, eq(resumePreviews.id, resumePublications.previewId))
    .where(eq(resumePreviews.familyId, familyId));
  const byLink = new Map(rows.map((r) => [r.linkId, r]));
  return {
    items: items.flatMap((item) => (byLink.has(item.id) ? [{ ...item, ...byLink.get(item.id), familyId }] : [])),
  };
}
