import { withMiniAuth as withApiAuth } from "@/lib/mini-app/auth";
import { readMiniJson as readJson } from "@/lib/mini-app/auth";
import { noStoreJson } from "@/lib/http/errors";
import { miniEnabled } from "@/lib/mini-app/service";
export const runtime = "nodejs";
export const maxDuration = 60;
type Context = { params: Promise<{ id: string }> };
import { z } from "zod";
import { attachMiniAppFile } from "@/lib/mini-app/files";
const schema = z.object({ uploadKey: z.string().trim().min(1).max(300), name: z.string().trim().min(1).max(200).optional() }).strict();
/** Stores a completed upload as a Clip file and returns its `{id, url, name, contentType, size}` reference. */
export async function POST(request: Request, { params }: Context) { return withApiAuth(request, async ({ db, principal }) => { miniEnabled(); const input = await readJson(request, v => schema.parse(v)); return noStoreJson({ file: await attachMiniAppFile(db, (await params).id, principal.sub, input) }, { status: 201 }); }); }
