import { sleep } from "workflow";
import { getDatabase } from "@/lib/db/client";
import { deliverPaperNotification, planPaperNotification } from "@/lib/services/paper-notifications";

/** Durable quiet-period debounce, then one "paper added / updated" push to the owner. */
export async function notifyPaperChanges(paperId: string, runnerId: string) {
  "use workflow";
  for (;;) {
    const plan = await planBatch(paperId, runnerId);
    if (plan.status === "done") return;
    if (plan.status === "wait") {
      await sleep(new Date(plan.nextAt));
      continue;
    }
    if (await deliverBatch(paperId, runnerId, plan.revision)) return;
  }
}

async function planBatch(paperId: string, runnerId: string) {
  "use step";
  return planPaperNotification(getDatabase(), paperId, runnerId);
}
async function deliverBatch(paperId: string, runnerId: string, revision: number) {
  "use step";
  return deliverPaperNotification(getDatabase(), paperId, runnerId, revision);
}
