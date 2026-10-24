import { and, desc, eq, gt, isNull } from "drizzle-orm";
import { mcpOAuthClients, mcpOAuthGrants } from "@/lib/db/schema";
import { noStoreJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";

export const runtime = "nodejs";

/** Active authorizations, not online sessions. Never exposes tokens or callback URLs. */
export async function GET(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => {
    const items = await db.select({
      id: mcpOAuthGrants.id,
      clientId: mcpOAuthClients.id,
      name: mcpOAuthClients.name,
      scope: mcpOAuthGrants.scope,
      expiresAt: mcpOAuthGrants.expiresAt,
    }).from(mcpOAuthGrants)
      .innerJoin(mcpOAuthClients, eq(mcpOAuthClients.id, mcpOAuthGrants.clientId))
      .where(and(eq(mcpOAuthGrants.ownerId, principal.sub), isNull(mcpOAuthGrants.revokedAt), gt(mcpOAuthGrants.expiresAt, new Date())))
      .orderBy(desc(mcpOAuthGrants.expiresAt), desc(mcpOAuthGrants.id));
    return noStoreJson({ items: items.map(item => ({ ...item, expiresAt: item.expiresAt.toISOString() })) });
  });
}
