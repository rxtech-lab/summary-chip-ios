import { timingSafeEqual } from "node:crypto";

/**
 * Bearer-secret authentication for Vercel Cron routes. Vercel sends
 * `Authorization: Bearer ${CRON_SECRET}`; an unset secret refuses every request.
 */
export type CronAuthResult = { ok: true } | { ok: false; response: Response };

function secretMatches(provided: string, expected: string): boolean {
  const a = Buffer.from(provided, "utf8");
  const b = Buffer.from(expected, "utf8");
  if (a.length !== b.length) return false;
  return timingSafeEqual(a, b);
}

export function authorizeCronRequest(request: Request): CronAuthResult {
  const requestId = crypto.randomUUID();
  const expected = process.env.CRON_SECRET;
  if (!expected) {
    console.error("CRON_SECRET is not configured; refusing to run the scheduled job");
    return {
      ok: false,
      response: Response.json(
        { error: { code: "CRON_NOT_CONFIGURED", message: "Scheduled jobs are not configured", requestId } },
        { status: 503, headers: { "cache-control": "no-store" } },
      ),
    };
  }
  const header = request.headers.get("authorization");
  const provided = header?.startsWith("Bearer ") ? header.slice("Bearer ".length) : "";
  if (!secretMatches(provided, expected)) {
    return {
      ok: false,
      response: Response.json(
        { error: { code: "UNAUTHORIZED", message: "Invalid cron credentials", requestId } },
        { status: 401, headers: { "cache-control": "no-store" } },
      ),
    };
  }
  return { ok: true };
}
