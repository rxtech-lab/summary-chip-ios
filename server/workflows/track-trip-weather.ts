import { sleep } from "workflow";
import { getDatabase } from "@/lib/db/client";
import { refreshTripWeather } from "@/lib/services/weather";

/**
 * One durable run per trip: refresh the forecast for the combined evening briefing, send
 * next-30-minutes alerts, then sleep until the next check. Each refresh is a step, so a
 * crash resumes at the last check. Schedule: `docs/weather.md`.
 */
export async function trackTripWeather(tripId: string) {
  "use workflow";

  // Bounded so a scheduling bug can't loop forever (a long trip checked every 15 minutes in the daytime).
  for (let check = 1; check <= 20_000; check += 1) {
    const plan = await refreshWeather(tripId);
    if (plan.done) return { tripId, checks: check };
    await sleep(new Date(plan.nextAt));
  }
  return { tripId, checks: 20_000 };
}

async function refreshWeather(tripId: string) {
  "use step";
  return refreshTripWeather(getDatabase(), tripId);
}
