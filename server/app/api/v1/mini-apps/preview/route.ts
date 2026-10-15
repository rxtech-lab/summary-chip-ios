import { withMiniAuth as withApiAuth } from "@/lib/mini-app/auth";
import { readMiniJson as readJson } from "@/lib/mini-app/auth";
import { noStoreJson } from "@/lib/http/errors";
import { miniEnabled } from "@/lib/mini-app/service";
export const runtime = "nodejs";
export const maxDuration = 60;
import { z } from "zod";
import { miniAppDocumentSchema, miniRunSchema, jsonValue, miniId } from "@/lib/contracts/mini-app";
import { previewMiniAction } from "@/lib/mini-app/runtime";
const schema = z.object({ document: miniAppDocumentSchema, action: miniRunSchema.omit({ key: true, revision: true }), records: z.record(miniId, z.array(jsonValue).max(100)).optional() });
export async function POST(request: Request) { return withApiAuth(request, async () => { miniEnabled(); const input = await readJson(request, v => schema.parse(v)); return noStoreJson(await previewMiniAction(input.document, input.action, input.records)); }); }
