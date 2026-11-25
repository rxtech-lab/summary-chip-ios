import type { z } from "zod";
import type { commitResumeTranslationSchema, saveResumeTranslationSchema, ResumeOperation } from "@/lib/contracts/resume";
import type { ResolvedResume } from "@/lib/services/resumes";
import { invalid, splitWording, valueAt, type Edition, type Words } from "./editing";

export type DirectTranslation = z.infer<typeof saveResumeTranslationSchema>;
export type ProposalTranslation = z.infer<typeof commitResumeTranslationSchema>;

function editionFields(source: ResolvedResume): Words {
  const visible = splitWording(source.document).words;
  if (!source.variantId) return { ...source.localizedWording, ...visible };
  const inherited = new Set(source.inheritedPaths);
  const fields: Words = {};
  for (const path of Object.keys(source.overrideSources)) {
    if (inherited.has(path)) continue;
    // An absent optional field is a company override only when its parent is still on the résumé.
    const parent = path.slice(0, path.lastIndexOf("/"));
    if (valueAt(source.document, parent) !== undefined || path === "/contact/location") {
      fields[path] = visible[path] ?? null;
    }
  }
  return fields;
}

function translationSources(source: ResolvedResume, baseSource?: ResolvedResume) {
  const words = editionFields(source);
  if (baseSource) {
    for (const [path, value] of Object.entries(editionFields(baseSource))) words["/base" + path] = value;
  }
  return words;
}

/** A new company translation also supplies the wording inherited from the new base edition. */
export function resumeTranslationFields(source: ResolvedResume, baseSource?: ResolvedResume): Record<string, string> {
  return Object.fromEntries(
    Object.entries(translationSources(source, baseSource)).filter(
      (field): field is [string, string] => !!field[1]?.trim(),
    ),
  );
}

export function directTranslationEdits(
  input: DirectTranslation,
  source: ResolvedResume,
  canonicalWords: Words,
  baseSource?: ResolvedResume,
): ProposalTranslation {
  const originals = translationSources(source, baseSource);
  const supplied = new Map<string, string>();
  for (const { path, value } of input.translations) {
    if (!originals[path]?.trim()) invalid("Unknown translation field " + path);
    if (supplied.has(path)) invalid("Duplicate translation field " + path);
    supplied.set(path, value);
  }
  const creating = input.expectedRevisionToken === null;
  if (!creating && !supplied.size) invalid("Supply at least one field to update the translation");
  const operations: ResumeOperation[] = [];
  const baseOperations: ResumeOperation[] = [];
  const baselines: Edition["baselines"] = {};
  const baseBaselines: Edition["baselines"] = {};
  for (const [field, original] of Object.entries(originals)) {
    if (!supplied.has(field)) {
      if (!creating) continue;
      if (original?.trim()) invalid("A new language edition requires a translation for " + field);
    }
    const value = supplied.get(field) ?? original;
    const inBase = field.startsWith("/base/");
    const path = inBase ? field.slice(5) : field;
    const scope = inBase ? baseSource! : source;
    (inBase ? baseOperations : operations).push({ op: "set", path, value });
    (inBase ? baseBaselines : baselines)[path] = {
      sourceValue: original,
      acceptedValue: value,
      sourceRevisionToken: scope.revisionToken,
      ...(scope.variantId && { sourceLanguage: scope.language }),
      ...(!scope.variantId && scope.language !== scope.sourceLanguage && {
        canonicalSourceValue: canonicalWords[path] ?? null,
      }),
    };
  }
  return { ...input, operations, baselines, baseOperations, baseBaselines };
}
