import { sleep } from "workflow";
import { getDatabase } from "@/lib/db/client";
import { refreshTripReminders } from "@/lib/services/trip-reminders";

/** Sleep until the next itinerary reminder; edits fence this run and start a new schedule. */
export async function remindTrip(tripId: string, runnerId: string) {
  "use workflow";
  for (;;) {
    const plan = await sendReminders(tripId, runnerId);
    if (plan.done) return;
    await sleep(new Date(plan.nextAt));
  }
}

async function sendReminders(tripId: string, runnerId: string) {
  "use step";
  return refreshTripReminders(getDatabase(), tripId, runnerId);
}
