import { withMiniAuth as withApiAuth } from "@/lib/mini-app/auth";
import { readMiniJson as readJson } from "@/lib/mini-app/auth";
import { noStoreJson } from "@/lib/http/errors";
import { miniEnabled } from "@/lib/mini-app/service";
export const runtime = "nodejs";
export const maxDuration = 30;
type Context = { params: Promise<{ id: string }> };
import { z } from "zod";
import { jsonValue, miniId } from "@/lib/contracts/mini-app";
import { runMiniScriptStep } from "@/lib/mini-app/runtime";
const schema = z.object({ revision: z.number().int().nonnegative(), script: miniId, input: jsonValue.default(null) }).strict();
export async function POST(request: Request, { params }: Context) { return withApiAuth(request, async ({ db, principal }) => { miniEnabled(); const input = await readJson(request, v => schema.parse(v)); return noStoreJson(await runMiniScriptStep(db, (await params).id, principal.sub, input)); }); }
