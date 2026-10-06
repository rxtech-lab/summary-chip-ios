import type { TripTranslationJob } from "@/lib/services/trip-translations";

/**
 * Starts `translateTrip` workflow runs. Behind an interface so services (and tests) never import
 * the workflow runtime directly.
 */
export interface TripTranslator {
  /** Starts a background run that translates the trip and notifies its owner. */
  start(job: TripTranslationJob): Promise<void>;
}

let override: TripTranslator | undefined;

export function setTripTranslatorForTests(translator?: TripTranslator): void {
  override = translator;
}

const workflowTranslator: TripTranslator = {
  async start(job) {
    const [{ start }, { translateTrip }] = await Promise.all([import("workflow/api"), import("@/workflows/translate-trip")]);
    await start(translateTrip, [job]);
  },
};

export function getTripTranslator(): TripTranslator {
  return override ?? workflowTranslator;
}
