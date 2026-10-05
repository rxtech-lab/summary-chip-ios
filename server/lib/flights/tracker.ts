/**
 * Starts and checks `trackFlight` workflow runs. Behind an interface so services (and tests) never
 * import the workflow runtime directly.
 */
export interface FlightTracker {
  /** Starts a run for the flight and returns its id. */
  start(flightId: string): Promise<string>;
  /** Whether the run is still pending or running. */
  isActive(runId: string): Promise<boolean>;
}

let override: FlightTracker | undefined;

export function setFlightTrackerForTests(tracker?: FlightTracker): void {
  override = tracker;
}

const workflowTracker: FlightTracker = {
  async start(flightId) {
    const [{ start }, { trackFlight }] = await Promise.all([import("workflow/api"), import("@/workflows/track-flight")]);
    const run = await start(trackFlight, [flightId]);
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

export function getFlightTracker(): FlightTracker {
  return override ?? workflowTracker;
}
