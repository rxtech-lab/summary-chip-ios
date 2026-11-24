import type { z } from "zod";
import { resumeLanguageSchema, resumeTargetSchema } from "@/lib/contracts/resume";
import type { Database } from "@/lib/db/client";
import { ApiError } from "@/lib/http/errors";
import { getResume, resumeTranslationFields } from "@/lib/services/resumes";

export const translationLanguage = resumeLanguageSchema.optional().describe(
  "Target language for a direct translation. Returns the source text for each writable path and the tokens needed to save it.",
);

export async function readResumeForAgent(
  db: Database,
  owner: string,
  familyId: string,
  scope: z.infer<typeof resumeTargetSchema>,
  language?: z.infer<typeof resumeLanguageSchema>,
) {
  const source = await getResume(db, owner, familyId, scope);
  if (!language) return source;
  if (language === source.language) throw new ApiError(422, "RESUME_INVALID", "Choose a different target language.");

  // A captured source revision may predate the creation of an existing target edition.
  const target = await getResume(db, owner, familyId, { variantId: source.variantId, language }).catch((error) => {
    if (error instanceof ApiError && error.code === "RESUME_EDITION_NOT_FOUND") return undefined;
    throw error;
  });
  const base = source.variantId && !target
    ? await getResume(db, owner, familyId, { variantId: null, language: source.language, revisionToken: source.baseRevisionToken })
    : undefined;
  return {
    familyId,
    variantId: source.variantId,
    sourceLanguage: source.language,
    language,
    sourceRevisionToken: source.revisionToken,
    expectedRevisionToken: target?.revisionToken ?? null,
    translationFields: resumeTranslationFields(source, base),
    ...(target && { currentTranslations: target.localizedWording }),
  };
}
