import { z } from "zod";
import { TRANSLATION_LANGUAGES } from "@/lib/contracts/api";
import type { ResumeOperation } from "@/lib/contracts/resume";

export const proposalSchema = z
  .object({
    kind: z.enum(["review", "tailor", "translate"]),
    variantId: z.string().min(1).max(120).nullish(),
    language: z.enum(TRANSLATION_LANGUAGES),
    targetLanguage: z.enum(TRANSLATION_LANGUAGES).optional(),
    expectedRevisionToken: z.string().min(1).max(1000),
    idempotencyKey: z.string().min(1).max(150),
  })
  .strict()
  .refine(
    (x) => x.kind !== "translate" || (x.targetLanguage && x.targetLanguage !== x.language),
    "Choose a different target language.",
  )
  .refine((x) => x.kind !== "tailor" || x.variantId, "Select a company to tailor.");
export type ProposalInput = z.infer<typeof proposalSchema>;
export const applyProposalSchema = z
  .object({
    keepPaths: z.array(z.string().min(1).max(1000)).max(6000).optional(),
    acceptedPaths: z.array(z.string().min(1).max(1000)).max(6000),
    expectedRevisionToken: z.string().min(1).max(1000),
    idempotencyKey: z.string().min(1).max(150),
  })
  .strict();

export interface Finding {
  path: string;
  rationale: string;
  source?: string | null;
  current?: string | null;
  proposed?: string | null;
  conflict: boolean;
  operation?: ResumeOperation;
  scope?: "base" | "company";
}
