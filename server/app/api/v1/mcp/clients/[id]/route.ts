import { and, eq, isNull } from "drizzle-orm";
import { mcpOAuthGrants } from "@/lib/db/schema";
import { notFound } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";

export const runtime = "nodejs";

/** Revokes one account-owned authorization, including its access and refresh tokens. */
export async function DELETE(request: Request, { params }: { params: Promise<{ id: string }> }) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    const owned = and(eq(mcpOAuthGrants.id, id), eq(mcpOAuthGrants.ownerId, principal.sub));
    const [grant] = await db.select({ id: mcpOAuthGrants.id }).from(mcpOAuthGrants).where(owned).limit(1);
    if (!grant) throw notFound("The client authorization does not exist");
    await db.update(mcpOAuthGrants).set({ revokedAt: new Date() }).where(and(owned, isNull(mcpOAuthGrants.revokedAt)));
    return new Response(null, { status: 204, headers: { "cache-control": "private, no-store" } });
  });
}
