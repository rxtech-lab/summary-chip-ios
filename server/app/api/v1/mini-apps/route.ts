import { withMiniAuth as withApiAuth } from "@/lib/mini-app/auth";
import { readMiniJson as readJson } from "@/lib/mini-app/auth";
import { noStoreJson } from "@/lib/http/errors";
import { miniEnabled } from "@/lib/mini-app/service";
export const runtime = "nodejs";
export const maxDuration = 60;
import { createMiniApp, listMiniApps } from "@/lib/mini-app/service";
export async function GET(request: Request) { return withApiAuth(request, async ({ db, principal }) => { miniEnabled(); return noStoreJson(await listMiniApps(db, principal.sub, new URL(request.url).searchParams.get("cursor") ?? undefined)); }); }
export async function POST(request: Request) { return withApiAuth(request, async ({ db, principal }) => { miniEnabled(); const input = await readJson(request, value => value); return noStoreJson({ app: await createMiniApp(db, principal.sub, input) }, { status: 201 }); }); }
