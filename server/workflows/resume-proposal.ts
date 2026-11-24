import { getDatabase } from "@/lib/db/client";
import { notifyResumeProposal, runResumeProposal } from "@/lib/resume/proposals";
import type { BillingEnvironment } from "@/lib/subscription/config";

type Job = { id: string; familyId: string; ownerId: string; environment?: BillingEnvironment };
export async function resumeProposalWorkflow(job: Job) {
  "use workflow";
  try {
    await generateProposal(job);
  } finally {
    await notify(job);
  }
}
async function generateProposal(job: Job) {
  "use step";
  await runResumeProposal(getDatabase(), job.id, job.environment);
}
async function notify(job: Job) {
  "use step";
  await notifyResumeProposal(getDatabase(), job.ownerId, job.familyId, job.id);
}
