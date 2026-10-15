import { withMiniAuth as withApiAuth } from "@/lib/mini-app/auth";
import { readMiniJson as readJson } from "@/lib/mini-app/auth";
import { noStoreJson } from "@/lib/http/errors";
import { miniEnabled } from "@/lib/mini-app/service";
export const runtime = "nodejs";
export const maxDuration = 60;
type Context = { params: Promise<{ id: string; connection: string }> };
import { z } from "zod";
import { disconnectMini, grantMiniConnection } from "@/lib/mini-app/connections";
const grant = z.object({ email: z.string().email().transform(v => v.toLowerCase()), operations: z.array(z.string()).max(50) }).strict();
export async function DELETE(request: Request, { params }: Context) { return withApiAuth(request, async ({ db, principal }) => { miniEnabled(); const { id, connection } = await params; await disconnectMini(db, id, principal.sub, connection); return noStoreJson({ ok: true }); }); }
export async function PUT(request: Request, { params }: Context) { return withApiAuth(request, async ({ db, principal }) => { miniEnabled(); const { id, connection } = await params; const input = await readJson(request, v => grant.parse(v)); await grantMiniConnection(db, id, principal.sub, connection, input.email, input.operations); return noStoreJson({ ok: true }); }); }
