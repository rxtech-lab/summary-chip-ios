import { getDatabase } from "@/lib/db/client";
import { runDailyRecap, type DailyRecapJob } from "@/lib/services/daily-recap";

export async function generateDailyRecap(job: DailyRecapJob) {
  "use workflow";
  await generate(job);
}
async function generate(job: DailyRecapJob) {
  "use step";
  await runDailyRecap(getDatabase(), job);
}
generate.maxRetries = 0;
