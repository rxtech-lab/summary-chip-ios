import { withMiniAuth as withApiAuth } from "@/lib/mini-app/auth";
import { readMiniJson as readJson } from "@/lib/mini-app/auth";
import { noStoreJson } from "@/lib/http/errors";
import { miniEnabled } from "@/lib/mini-app/service";
export const runtime = "nodejs";
export const maxDuration = 60;
type Context = { params: Promise<{ id: string }> };
import { miniRunSchema } from "@/lib/contracts/mini-app";
import { runMiniAction } from "@/lib/mini-app/runtime";
export async function POST(request: Request, { params }: Context) { return withApiAuth(request, async ({ db, principal }) => { miniEnabled(); const input = await readJson(request, v => miniRunSchema.parse(v)); return noStoreJson(await runMiniAction(db, (await params).id, principal.sub, input)); }); }
