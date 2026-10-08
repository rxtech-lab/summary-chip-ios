import { getDatabase } from "@/lib/db/client";
import { authorizeCronRequest } from "@/lib/http/cron-auth";
import { errorResponse } from "@/lib/http/errors";
import { resumeTripNotifications } from "@/lib/services/trip-notifications";
import { resumeTripReminders } from "@/lib/services/trip-reminders";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 300;

export async function GET(request: Request) {
  const auth = authorizeCronRequest(request);
  if (!auth.ok) return auth.response;
  try {
    const db = getDatabase();
    return Response.json({ ok: true, ...await resumeTripNotifications(db), ...await resumeTripReminders(db) }, { headers: { "cache-control": "no-store" } });
  } catch (error) { return errorResponse(error); }
}
