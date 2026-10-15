import { withPublicApi } from "@/lib/http/handler";
import { finishMiniOAuth } from "@/lib/mini-app/connections";
import { miniEnabled } from "@/lib/mini-app/service";
export const runtime = "nodejs";
export async function GET(request: Request, { params }: { params: Promise<{ id: string; connection: string }> }) {
 return withPublicApi(request, async ({ db }) => { miniEnabled(); const { id, connection } = await params; const callback = new URL(request.url); const result = await finishMiniOAuth(db, id, connection, callback.searchParams, callback.origin + callback.pathname); return new Response(null, { status: 302, headers: { location: `summarychip://mini-app/oauth-complete?status=${result.status}`, "cache-control": "no-store", "referrer-policy": "no-referrer" } }); });
}
