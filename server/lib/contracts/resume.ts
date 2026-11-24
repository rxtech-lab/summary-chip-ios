import { z } from "zod";
import { httpUrl, TRANSLATION_LANGUAGES } from "./api";

export const resumeLanguageSchema = z.enum(TRANSLATION_LANGUAGES);
export const resumeIdSchema = z
  .string()
  .min(1)
  .max(100)
  .regex(/^[a-zA-Z0-9_-]+$/)
  .refine((id) => !["__proto__", "constructor", "prototype"].includes(id), "Reserved ID");
const label = z.string().max(500);
const body = z.string().max(12_000);
const partialDate = z
  .string()
  .regex(/^\d{4}(?:-(?:0[1-9]|1[0-2])(?:-(?:0[1-9]|[12]\d|3[01]))?)?$/)
  .refine((date) => {
    if (date.length < 10) return true;
    const instant = new Date(date + "T00:00:00Z");
    return Number.isFinite(instant.getTime()) && instant.toISOString().startsWith(date);
  }, "Invalid calendar date");
export const resumeBulletSchema = z.strictObject({ id: resumeIdSchema, text: body });
export const resumeLinkSchema = z.strictObject({ id: resumeIdSchema, label, url: httpUrl });
export const resumeEntrySchema = z.strictObject({
  id: resumeIdSchema,
  title: label.optional(),
  organization: label.optional(),
  location: label.optional(),
  startDate: partialDate.optional(),
  endDate: partialDate.optional(),
  current: z.boolean().optional(),
  description: body.optional(),
  url: httpUrl.optional(),
  bullets: z.array(resumeBulletSchema).max(100),
});
export const resumeSectionSchema = z.strictObject({
  id: resumeIdSchema,
  kind: z.enum(["profile", "experience", "education", "skills", "projects", "certifications", "custom"]),
  title: label,
  entries: z.array(resumeEntrySchema).max(150),
});
export const resumeDocumentSchema = z
  .strictObject({
    version: z.literal(1),
    candidateName: label.min(1),
    headline: label.optional(),
    contact: z
      .strictObject({ email: z.email().max(320).optional(), phone: label.optional(), location: label.optional() })
      .optional(),
    links: z.array(resumeLinkSchema).max(40),
    avatarAssetId: resumeIdSchema.optional(),
    sections: z.array(resumeSectionSchema).max(50),
  })
  .superRefine((doc, ctx) => {
    const ids = new Set<string>();
    function check(id: string) {
      if (ids.has(id)) ctx.addIssue({ code: "custom", message: "Duplicate document ID " + id });
      ids.add(id);
    }
    doc.links.forEach((link) => check(link.id));
    for (const section of doc.sections) {
      check(section.id);
      for (const entry of section.entries) {
        check(entry.id);
        entry.bullets.forEach((bullet) => check(bullet.id));
      }
    }
    if (new TextEncoder().encode(JSON.stringify(doc)).byteLength > 400_000)
      ctx.addIssue({ code: "custom", message: "Résumé exceeds 400 KB" });
  });
export type ResumeDocument = z.infer<typeof resumeDocumentSchema>;
const path = z
  .string()
  .max(700)
  .regex(/^(?:\/[a-zA-Z0-9_-]+)+$/)
  .refine(
    (p) => p.split("/").every((segment) => !["constructor", "prototype", "__proto__"].includes(segment)),
    "Invalid field path",
  );
const neighbor = resumeIdSchema.nullable();
export const resumeOperationSchema = z.discriminatedUnion("op", [
  z.strictObject({ op: z.literal("set"), path, value: z.union([body, z.boolean(), z.null()]) }),
  z.strictObject({
    op: z.literal("insert"),
    path,
    value: z.union([resumeSectionSchema, resumeEntrySchema, resumeBulletSchema, resumeLinkSchema]),
    after: neighbor.optional(),
  }),
  z.strictObject({ op: z.literal("move"), path, after: neighbor }),
  ...(["remove", "reset", "keep", "discard"] as const).map((op) => z.strictObject({ op: z.literal(op), path })),
]);
export type ResumeOperation = z.infer<typeof resumeOperationSchema>;
export const resumeTargetSchema = z.strictObject({
  variantId: resumeIdSchema.nullish(),
  language: resumeLanguageSchema.optional(),
  revisionToken: z.string().max(1000).optional(),
});
const mutation = { expectedRevisionToken: z.string().min(1).max(1000), idempotencyKey: z.string().min(1).max(150) };
const scope = { variantId: resumeIdSchema.nullish(), language: resumeLanguageSchema.optional() };
export const createResumeSchema = z.strictObject({
  title: label.min(1),
  document: resumeDocumentSchema,
  language: resumeLanguageSchema,
  idempotencyKey: mutation.idempotencyKey,
});
export const editResumeSchema = z.strictObject({
  ...scope,
  ...mutation,
  operations: z.array(resumeOperationSchema).min(1).max(1500),
});
export const createResumeVariantSchema = z.strictObject({
  ...mutation,
  language: scope.language,
  company: label.min(1),
  targetRole: label.optional(),
  jobDescription: body.optional(),
  sourceRevisionToken: z.string().max(1000).optional(),
  acceptedPaths: z.array(path).max(1500).optional(),
});
export const previewResumeRestoreSchema = z.strictObject({ ...scope, revisionToken: z.string().min(1).max(1000) });
export const restoreResumeSchema = previewResumeRestoreSchema.extend(mutation);
const nullableText = body.nullable();
const baseline = z.strictObject({
  sourceRevisionToken: z.string().max(1000),
  sourceValue: nullableText,
  acceptedValue: nullableText,
});
export const commitResumeTranslationSchema = z.strictObject({
  ...scope,
  ...mutation,
  expectedRevisionToken: mutation.expectedRevisionToken.nullable(),
  sourceRevisionToken: mutation.expectedRevisionToken,
  sourceLanguage: resumeLanguageSchema,
  language: resumeLanguageSchema,
  operations: z.array(resumeOperationSchema).max(1500),
  baselines: z.record(path, baseline).optional(),
  baseOperations: z.array(resumeOperationSchema).max(1500).optional(),
  baseBaselines: z.record(path, baseline).optional(),
});
export type ResumeBaseline = z.infer<typeof baseline>;
