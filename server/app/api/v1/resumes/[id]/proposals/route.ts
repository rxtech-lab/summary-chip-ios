import { proposalSchema } from "@/lib/resume/proposal-contract";
import { createResumeProposal } from "@/lib/resume/proposals";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
export const maxDuration = 300;
export async function POST(request: Request, context: { params: Promise<{ id: string }> }) {
  return withApiAuth(request, async ({ db, principal }) => {
    const { id } = await context.params;
    const input = await readJson(request, (body) => proposalSchema.parse(body));
    const result = await createResumeProposal(
      db,
      principal.sub,
      id,
      input,

    );
    return noStoreJson(result);
  }, { requireSubscription: true });
}
