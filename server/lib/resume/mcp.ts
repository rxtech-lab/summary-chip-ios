import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";
import {
  createResumeSchema,
  createResumeVariantSchema,
  editResumeSchema,
  resumeIdSchema,
  resumeTargetSchema,
  restoreResumeSchema,
  previewResumeRestoreSchema,
} from "@/lib/contracts/resume";
import {
  previewResumeVariant,
  createResume,
  listResumes,
  getResume,
  editResume,
  createResumeVariant,
  listResumeHistory,
  previewResumeRestore,
  restoreResume,
} from "@/lib/services/resumes";
import {
  avatarUploadSchema,
  stageResumeAvatar,
  importResumeAvatar,
  listResumePublications,
  prepareResumePreview,
  publishResumePreview,
  resumePreviewSchema,
  resumePublicationSchema,
} from "@/lib/services/resume-outputs";
import { RESUME_TEMPLATES } from "@/lib/resume/render";
import { deleteShareLink } from "@/lib/services/share-links";
import { getResumeProposal, createResumeProposal, applyResumeProposal } from "./proposals";
import { proposalSchema, applyProposalSchema } from "./proposal-contract";
import type { McpContext } from "@/lib/mcp/server";
import { securitySchemes } from "@/lib/mcp/oauth-config";

type Run = (name: string, action: () => Promise<{ result: CallToolResult }>) => Promise<CallToolResult>;
export function registerResumeTools(server: McpServer, context: McpContext, run: Run) {
  const { db, principal, billingEnvironment } = context,
    owner = principal.sub;
  const target = { familyId: resumeIdSchema };
  function register<S extends z.ZodRawShape>(
    name: string,
    description: string,
    schema: z.ZodObject<S>,
    read: boolean,
    action: (input: z.output<z.ZodObject<S>>) => Promise<unknown>,
  ) {
    const wireShape: z.ZodRawShape = schema.shape;
    server.registerTool(
      name,
      {
        description,
        inputSchema: wireShape,
        _meta: { securitySchemes: securitySchemes(name) },
        annotations: { readOnlyHint: read, destructiveHint: name === "revoke_resume_link", openWorldHint: false },
      },
      async (raw) =>
        run(name, async () => {
          const data = await action(schema.parse(raw));
          return {
            result: {
              content: [{ type: "text", text: JSON.stringify(data) }],
              structuredContent: data as Record<string, unknown>,
            },
          };
        }),
    );
  }
  register(
    "create_resume",
    "Create one private résumé family and its source edition.",
    createResumeSchema,
    false,
    (input) => createResume(db, owner, input),
  );
  register("list_resumes", "List private résumé families.", z.object({}), true, async () => ({
    resumes: await listResumes(db, owner),
  }));
  register(
    "get_resume",
    "Resolve the base or a company résumé, optionally at a historical token.",
    resumeTargetSchema.extend(target),
    true,
    ({ familyId, ...input }) => getResume(db, owner, familyId, input),
  );
  register(
    "edit_resume",
    "Apply one revision of stable-ID edits. Use reset to inherit the base value. Set paths use /sections/ID/entries/ID/bullets/ID/text.",
    editResumeSchema.extend(target),
    false,
    ({ familyId, ...input }) => editResume(db, owner, familyId, input),
  );
  register(
    "preview_resume_company",
    "Compare a selected historical or company revision with the current base before copying accepted paths.",
    z.object({ ...target, sourceRevisionToken: z.string(), language: resumeTargetSchema.shape.language }),
    true,
    ({ familyId, ...input }) => previewResumeVariant(db, owner, familyId, input),
  );
  register(
    "create_resume_company",
    "Create a company variant with empty overrides or accepted historical differences.",
    createResumeVariantSchema.extend(target),
    false,
    ({ familyId, ...input }) => createResumeVariant(db, owner, familyId, input),
  );
  register(
    "list_resume_revisions",
    "List base and company revisions for the selected edition.",
    resumeTargetSchema.extend(target),
    true,
    async ({ familyId, ...input }) => ({
      familyId,
      ...input,
      history: await listResumeHistory(db, owner, familyId, input),
    }),
  );
  register(
    "compare_resume_revision",
    "Preview a historical revision against the current edition before restoring.",
    previewResumeRestoreSchema.extend(target),
    true,
    ({ familyId, ...input }) => previewResumeRestore(db, owner, familyId, input),
  );
  register(
    "restore_resume_revision",
    "Append a scoped restoration of the previewed historical revision.",
    restoreResumeSchema.extend(target),
    false,
    ({ familyId, ...input }) => restoreResume(db, owner, familyId, input),
  );
  for (const kind of ["review", "tailor", "translate"] as const) {
    register(
      kind + "_resume",
      "Generate a points-billed " + kind + " proposal. Translation refresh reuses unchanged wording.",
      z.object({ ...proposalSchema.shape, ...target }).omit({ kind: true }),
      false,
      ({ familyId, ...input }) => createResumeProposal(db, owner, familyId, { ...input, kind }, billingEnvironment),
    );
  }
  register(
    "get_resume_job",
    "Get proposal status, field-specific findings and conflicts.",
    z.object({ ...target, proposalId: z.string() }),
    true,
    ({ familyId, proposalId }) => getResumeProposal(db, owner, familyId, proposalId),
  );
  register(
    "apply_resume_proposal",
    "Commit only accepted proposal paths in one revision.",
    applyProposalSchema.extend({ ...target, proposalId: z.string() }),
    false,
    ({ familyId, proposalId, ...input }) => applyResumeProposal(db, owner, familyId, proposalId, input),
  );
  register(
    "start_resume_avatar_upload",
    "Stage a private PNG or JPEG upload. PUT the bytes to the returned presigned URL with the required headers.",
    avatarUploadSchema.extend(target),
    false,
    ({ familyId, ...input }) => stageResumeAvatar(db, owner, familyId, input),
  );
  register(
    "finish_resume_avatar_upload",
    "Validate uploaded image bytes and return an opaque asset ID. Set /avatarAssetId with edit_resume to save it.",
    z.object({ ...target, uploadId: z.string() }),
    false,
    ({ familyId, uploadId }) => importResumeAvatar(db, owner, familyId, uploadId),
  );
  register("list_resume_templates", "List immutable résumé template versions.", z.object({}), true, async () => ({
    templates: RESUME_TEMPLATES,
  }));
  register(
    "preview_resume",
    "Prepare one immutable preview and return authenticated PDF and editable DOCX handles.",
    z.object({ ...resumePreviewSchema.shape, ...target }),
    false,
    ({ familyId, ...input }) => prepareResumePreview(db, owner, familyId, resumePreviewSchema.parse(input)),
  );
  register(
    "export_resume",
    "Retrieve an authenticated PDF or editable DOCX handle for one template and exact revision.",
    z.object({ ...resumePreviewSchema.shape, ...target, format: z.enum(["pdf", "docx"]) }),
    false,
    async ({ familyId, format, ...input }) => {
      const preview = await prepareResumePreview(db, owner, familyId, resumePreviewSchema.parse(input));
      return { ...preview, format, artifactUrl: format === "pdf" ? preview.pdfUrl : preview.docxUrl };
    },
  );
  register(
    "publish_resume",
    "Create a publication link or republish a preview to an existing link.",
    z.object({ ...resumePublicationSchema.shape, ...target }),
    false,
    ({ familyId, ...input }) => publishResumePreview(db, owner, familyId, resumePublicationSchema.parse(input)),
  );
  register(
    "list_resume_links",
    "Inspect access, invites and expiry for this résumé's links.",
    z.object(target),
    true,
    async ({ familyId }) => {
      return listResumePublications(db, owner, familyId);
    },
  );
  register(
    "revoke_resume_link",
    "Revoke one published résumé link immediately.",
    z.object({ ...target, linkId: resumeIdSchema }),
    false,
    async ({ familyId, linkId }) => {
      await getResume(db, owner, familyId);
      await deleteShareLink(db, owner, familyId, linkId);
      return { familyId, linkId, revoked: true };
    },
  );
}
