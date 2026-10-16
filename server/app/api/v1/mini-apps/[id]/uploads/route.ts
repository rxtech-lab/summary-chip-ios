import { withMiniAuth as withApiAuth } from "@/lib/mini-app/auth";
import { readMiniJson as readJson } from "@/lib/mini-app/auth";
import { noStoreJson } from "@/lib/http/errors";
import { miniEnabled } from "@/lib/mini-app/service";
export const runtime = "nodejs";
type Context = { params: Promise<{ id: string }> };
import { createFileUploadSchema } from "@/lib/contracts/api";
import { createMiniAppUpload } from "@/lib/mini-app/files";
/** A presigned PUT for a file picked in a Clip; attach it with POST /files once uploaded. */
export async function POST(request: Request, { params }: Context) { return withApiAuth(request, async ({ db, principal }) => { miniEnabled(); const input = await readJson(request, v => createFileUploadSchema.parse(v)); return noStoreJson(await createMiniAppUpload(db, (await params).id, principal.sub, input), { status: 201 }); }); }
