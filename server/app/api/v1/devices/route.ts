import { and, eq, ne } from "drizzle-orm";
import { z } from "zod";
import { pushDevices } from "@/lib/db/schema";
import { readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";

export const runtime = "nodejs";
const installation = z.object({ installationId: z.uuid() }).strict();
const registration = installation.extend({
  // APNs tokens are opaque and variable in length; sent as hexadecimal by the app.
  token: z.string().regex(/^(?:[a-fA-F0-9]{2}){16,256}$/).transform((value) => value.toLowerCase()),
  environment: z.enum(["sandbox", "production"]),
  platform: z.enum(["ios", "macos"]),
}).strict();

export async function POST(request: Request) {
  return withApiAuth(request, async ({ db, principal }) => {
    const input = await readJson(request, (body) => registration.parse(body));
    const row = { ...input, ownerId: principal.sub, updatedAt: new Date() };
    await db.batch([
      db.delete(pushDevices).where(and(eq(pushDevices.token, input.token), eq(pushDevices.environment, input.environment), ne(pushDevices.installationId, input.installationId))),
      db.insert(pushDevices).values(row).onConflictDoUpdate({ target: pushDevices.installationId, set: row }),
    ]);
    return new Response(null, { status: 204 });
  });
}

export async function DELETE(request: Request) {
  return withApiAuth(request, async ({ db, principal }) => {
    const input = await readJson(request, (body) => installation.parse(body));
    await db.delete(pushDevices).where(and(eq(pushDevices.installationId, input.installationId), eq(pushDevices.ownerId, principal.sub)));
    return new Response(null, { status: 204 });
  });
}
