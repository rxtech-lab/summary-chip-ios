import { sleep } from "workflow";
import { getDatabase } from "@/lib/db/client";
import { refreshTrackedFlight } from "@/lib/services/flights";

/**
 * One durable run per tracked flight: refresh, sleep until the next check, repeat until the plane
 * has been down for 15 minutes (or is cancelled, or nobody follows it any more). Each refresh is a
 * step, so a crash resumes at the last check instead of starting over. Schedule: `docs/flights.md`.
 */
export async function trackFlight(flightId: string) {
  "use workflow";

  // Bounded so a scheduling bug can't loop forever (a year of daily checks plus the flight day).
  for (let check = 1; check <= 1000; check += 1) {
    const plan = await refreshFlight(flightId);
    if (plan.done) return { flightId, checks: check };
    await sleep(new Date(plan.nextAt));
  }
  return { flightId, checks: 1000 };
}

async function refreshFlight(flightId: string) {
  "use step";
  return refreshTrackedFlight(getDatabase(), flightId);
}
