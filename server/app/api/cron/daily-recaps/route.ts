import { getDatabase } from "@/lib/db/client";
import { authorizeCronRequest } from "@/lib/http/cron-auth";
import { errorResponse, noStoreJson } from "@/lib/http/errors";
import { dispatchDailyRecaps } from "@/lib/services/daily-recap";

export const runtime = "nodejs";
export const maxDuration = 300;
export async function GET(request: Request) {
  const auth = authorizeCronRequest(request);
  if (!auth.ok) return auth.response;
  try { return noStoreJson({ ok: true, ...await dispatchDailyRecaps(getDatabase()) }); }
  catch (error) { return errorResponse(error); }
}
