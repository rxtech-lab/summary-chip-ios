import { withMiniAuth as withApiAuth } from "@/lib/mini-app/auth";
import { readMiniJson as readJson } from "@/lib/mini-app/auth";
import { noStoreJson } from "@/lib/http/errors";
import { miniEnabled } from "@/lib/mini-app/service";
export const runtime = "nodejs";
export const maxDuration = 60;
type Context = { params: Promise<{ id: string }> };
import { connectMiniApp, listConnections } from "@/lib/mini-app/connections";
export async function GET(request: Request, { params }: Context) { return withApiAuth(request, async ({ db, principal }) => { miniEnabled(); return noStoreJson(await listConnections(db, (await params).id, principal.sub)); }); }
export async function POST(request: Request, { params }: Context) { return withApiAuth(request, async ({ db, principal }) => { miniEnabled(); return noStoreJson(await connectMiniApp(db, (await params).id, principal.sub, await readJson(request, v => v))); }); }
