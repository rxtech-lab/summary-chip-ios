import { withMiniAuth as withApiAuth } from "@/lib/mini-app/auth";
import { readMiniJson as readJson } from "@/lib/mini-app/auth";
import { noStoreJson } from "@/lib/http/errors";
import { miniEnabled } from "@/lib/mini-app/service";
export const runtime = "nodejs";
export const maxDuration = 60;
type Context = { params: Promise<{ id: string }> };
import { getMiniApp, miniAccess, updateMiniApp } from "@/lib/mini-app/service";
import { saveMiniAppSchema } from "@/lib/contracts/mini-app";
import { deleteSummary } from "@/lib/services/summaries";
export async function GET(request: Request, { params }: Context) { return withApiAuth(request, async ({ db, principal }) => { miniEnabled(); return noStoreJson({ app: await getMiniApp(db, (await params).id, principal.sub) }); }); }
export async function PUT(request: Request, { params }: Context) { return withApiAuth(request, async ({ db, principal }) => { miniEnabled(); const input = await readJson(request, v => saveMiniAppSchema.parse(v)); return noStoreJson({ app: await updateMiniApp(db, (await params).id, principal.sub, input.document, input.revision) }); }); }
export async function DELETE(request: Request, { params }: Context) { return withApiAuth(request, async ({ db, principal }) => { miniEnabled(); const { id } = await params; await miniAccess(db, id, principal.sub, true); await deleteSummary(db, principal.sub, id); return new Response(null, { status: 204 }); }); }
