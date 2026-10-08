import { getDatabase } from "@/lib/db/client";
import { authorizeCronRequest } from "@/lib/http/cron-auth";
import { errorResponse } from "@/lib/http/errors";
import { getAiProvider } from "@/lib/ai/provider";
import { runCleanup } from "@/lib/services/cleanup";
import { backfillEmbeddings } from "@/lib/services/embeddings";
import { deleteStaleFlights, resumeFlightTracking } from "@/lib/services/flights";
import { resumeWeatherTracking } from "@/lib/services/weather";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 300;

export async function GET(request: Request) {
  const auth = authorizeCronRequest(request);
  if (!auth.ok) return auth.response;
  try {
    const db = getDatabase();
    const report = {
      ...await runCleanup(db),
      embeddings: await backfillEmbeddings(db, await getAiProvider()),
      // Safety net for flight tracker runs that died; and lookups nobody tracks, long past.
      flightTracking: await resumeFlightTracking(db),
      staleFlights: await deleteStaleFlights(db),
      // And for trip weather runs that died.
      weatherTracking: await resumeWeatherTracking(db),
    };
    console.log(`[cron] cleanup ${JSON.stringify(report)}`);
    return Response.json({ ok: true, ...report }, { headers: { "cache-control": "no-store" } });
  } catch (error) {
    return errorResponse(error);
  }
}
