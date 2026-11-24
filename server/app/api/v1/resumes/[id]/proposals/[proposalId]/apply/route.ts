import { applyProposalSchema } from "@/lib/resume/proposal-contract";
import { applyResumeProposal } from "@/lib/resume/proposals";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";

export async function POST(request: Request, context: { params: Promise<{ id: string; proposalId: string }> }) {
  return withApiAuth(request, async ({ db, principal }) => {
    const { id, proposalId } = await context.params;
    const input = await readJson(request, (body) => applyProposalSchema.parse(body));
    const result = await applyResumeProposal(db, principal.sub, id, proposalId, input);
    return noStoreJson(result);
  });
}
