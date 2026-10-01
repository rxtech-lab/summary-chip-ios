import { getDatabase } from "@/lib/db/client";
import { authorizeCronRequest } from "@/lib/http/cron-auth";
import { errorResponse } from "@/lib/http/errors";
import { getAiProvider } from "@/lib/ai/provider";
import { runCleanup } from "@/lib/services/cleanup";
import { backfillEmbeddings } from "@/lib/services/embeddings";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 300;

export async function GET(request: Request) {
  const auth = authorizeCronRequest(request);
  if (!auth.ok) return auth.response;
  try {
    const db = getDatabase();
    const report = { ...await runCleanup(db), embeddings: await backfillEmbeddings(db, await getAiProvider()) };
    console.log(`[cron] cleanup ${JSON.stringify(report)}`);
    return Response.json({ ok: true, ...report }, { headers: { "cache-control": "no-store" } });
  } catch (error) {
    return errorResponse(error);
  }
}
