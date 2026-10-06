import { getDatabase } from "@/lib/db/client";
import { finishTripTranslation, runTripTranslationPass, type TripTranslationJob, type TripTranslationOutcome } from "@/lib/services/trip-translations";

/** Passes before giving up on parts the model keeps failing; each pass only translates what is still missing. */
const MAX_PASSES = 3;

/**
 * Translates a trip too large to translate while its owner waits, then notifies them. Each pass is
 * a step and saves what it translated, so a crash or timeout resumes with the texts still missing.
 */
export async function translateTrip(job: TripTranslationJob) {
  "use workflow";

  let outcome = await translatePass(job);
  for (let pass = 2; pass <= MAX_PASSES && outcome.status === "partial"; pass += 1) {
    outcome = await translatePass(job);
  }
  await finish(job, outcome);
  return outcome;
}

async function translatePass(job: TripTranslationJob) {
  "use step";
  return runTripTranslationPass(getDatabase(), job);
}

async function finish(job: TripTranslationJob, outcome: TripTranslationOutcome) {
  "use step";
  await finishTripTranslation(getDatabase(), job, outcome);
}
