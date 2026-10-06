import { sleep } from "workflow";
import type { TripChangeInput } from "@/lib/ai/trip-change-agent";
import { getDatabase } from "@/lib/db/client";
import { deliverTripNotification, planTripNotification, publishTripNotification, writeTripChangeSummary } from "@/lib/services/trip-notifications";

/** Durable quiet-period debounce, one agent summary, then a grouped push to every recipient. */
export async function notifyTripChanges(batchId: string, runnerId: string) {
  "use workflow";
  for (;;) {
    const plan = await planBatch(batchId, runnerId);
    if (plan.status === "done") return;
    if (plan.status === "wait") {
      await sleep(new Date(plan.nextAt));
      continue;
    }
    if (plan.status === "summarize") {
      const body = await summarizeChanges(plan.input);
      if (!await publishBatch(batchId, runnerId, plan.revision, body)) continue;
    }
    if (await deliverBatch(batchId, runnerId)) return;
  }
}

async function planBatch(batchId: string, runnerId: string) {
  "use step";
  return planTripNotification(getDatabase(), batchId, runnerId);
}
async function summarizeChanges(input: TripChangeInput) {
  "use step";
  return writeTripChangeSummary(input);
}
async function publishBatch(batchId: string, runnerId: string, revision: number, body: string) {
  "use step";
  return publishTripNotification(getDatabase(), batchId, runnerId, revision, body);
}
async function deliverBatch(batchId: string, runnerId: string) {
  "use step";
  return deliverTripNotification(getDatabase(), batchId, runnerId);
}
