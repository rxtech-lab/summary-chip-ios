import { getDatabase } from "@/lib/db/client";
import { authorizeCronRequest } from "@/lib/http/cron-auth";
import { errorResponse } from "@/lib/http/errors";
import { sweepOverdueAccountDeletions } from "@/lib/services/account-deletion";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 300;

/** Hourly: finalizes every account deletion whose grace period has run out. */
export async function GET(request: Request) {
  const auth = authorizeCronRequest(request);
  if (!auth.ok) return auth.response;
  try {
    const report = await sweepOverdueAccountDeletions(getDatabase());
    console.log(`[cron] account-deletion ${JSON.stringify(report)}`);
    return Response.json({ ok: true, ...report }, { headers: { "cache-control": "no-store" } });
  } catch (error) {
    return errorResponse(error);
  }
}
