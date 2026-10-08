/**
 * Starts and checks `trackTripWeather` workflow runs. Behind an interface so services (and tests)
 * never import the workflow runtime directly.
 */
export interface WeatherTracker {
  /** Starts a run for the trip and returns its id. */
  start(tripId: string): Promise<string>;
  /** Whether the run is still pending or running. */
  isActive(runId: string): Promise<boolean>;
}

let override: WeatherTracker | undefined;

export function setWeatherTrackerForTests(tracker?: WeatherTracker): void {
  override = tracker;
}

const workflowTracker: WeatherTracker = {
  async start(tripId) {
    const [{ start }, { trackTripWeather }] = await Promise.all([import("workflow/api"), import("@/workflows/track-trip-weather")]);
    const run = await start(trackTripWeather, [tripId]);
    return run.runId;
  },
  async isActive(runId) {
    const { getRun } = await import("workflow/api");
    const run = getRun(runId);
    if (!await run.exists) return false;
    const status = await run.status;
    return status === "pending" || status === "running";
  },
};

export function getWeatherTracker(): WeatherTracker {
  return override ?? workflowTracker;
}
