import { withMiniAuth as withApiAuth } from "@/lib/mini-app/auth";
import { readMiniJson as readJson } from "@/lib/mini-app/auth";
import { ApiError, noStoreJson } from "@/lib/http/errors";
import { miniEnabled } from "@/lib/mini-app/service";
export const runtime = "nodejs";
export const maxDuration = 60;
type Context = { params: Promise<{ id: string }> };
import { z } from "zod";
import { and, eq } from "drizzle-orm";
import { miniAppMembers, miniAppConnectionGrants, miniAppConnections } from "@/lib/db/schema";
import { miniAccess } from "@/lib/mini-app/service";
import { miniId } from "@/lib/contracts/mini-app";
const schema = z.object({ email: z.string().email().transform(v => v.toLowerCase()), permissions: z.record(miniId, z.enum(["read", "write"])).default({}), remove: z.boolean().default(false) }).strict();
export async function GET(request: Request, { params }: Context) { return withApiAuth(request, async ({ db, principal }) => { miniEnabled(); const { id } = await params; await miniAccess(db, id, principal.sub, true); return noStoreJson({ items: await db.select().from(miniAppMembers).where(eq(miniAppMembers.appId, id)) }); }); }
export async function PUT(request: Request, { params }: Context) { return withApiAuth(request, async ({ db, principal }) => { miniEnabled(); const { id } = await params; const access = await miniAccess(db, id, principal.sub, true); const input = await readJson(request, v => schema.parse(v)); if (!input.remove && Object.keys(input.permissions).some(table => access.app.document.tables[table]?.scope !== "shared")) throw new ApiError(422, "MINI_PERMISSION_INVALID", "Permissions must name existing shared tables"); if (input.remove) { await db.delete(miniAppMembers).where(and(eq(miniAppMembers.appId, id), eq(miniAppMembers.email, input.email))); const cs = await db.select().from(miniAppConnections).where(eq(miniAppConnections.appId, id)); for (const c of cs) await db.delete(miniAppConnectionGrants).where(and(eq(miniAppConnectionGrants.connectionId, c.id), eq(miniAppConnectionGrants.email, input.email))); } else await db.insert(miniAppMembers).values({ appId: id, email: input.email, permissions: input.permissions }).onConflictDoUpdate({ target: [miniAppMembers.appId, miniAppMembers.email], set: { permissions: input.permissions } }); return noStoreJson({ ok: true }); }); }
