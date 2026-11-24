import { getResumeProposal } from "@/lib/resume/proposals";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson } from "@/lib/http/errors";

export async function GET(request: Request, context: { params: Promise<{ id: string; proposalId: string }> }) {
  return withApiAuth(request, async ({ db, principal }) => {
    const { id, proposalId } = await context.params;

    const result = await getResumeProposal(db, principal.sub, id, proposalId);
    return noStoreJson(result);
  });
}
