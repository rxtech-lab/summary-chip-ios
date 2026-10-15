import { withMiniAuth as withApiAuth } from "@/lib/mini-app/auth";
import { readMiniJson as readJson } from "@/lib/mini-app/auth";
import { noStoreJson } from "@/lib/http/errors";
import { miniEnabled } from "@/lib/mini-app/service";
export const runtime = "nodejs";
export const maxDuration = 60;
type Context = { params: Promise<{ id: string }> };
import { z } from "zod";
import { miniId, miniQuerySchema, jsonValue } from "@/lib/contracts/mini-app";
import { queryMiniRecords, mutateMiniRecordOnce } from "@/lib/mini-app/service";
const schema = z.object({ key: z.string().uuid(), table: miniId, operation: z.enum(["create", "update", "delete"]), id: z.string().uuid().optional(), revision: z.number().int().nonnegative().optional(), data: z.record(miniId, jsonValue).optional() }).strict();
export async function GET(request: Request, { params }: Context) { return withApiAuth(request, async ({ db, principal }) => { miniEnabled(); const p = new URL(request.url).searchParams; const query = miniQuerySchema.parse(p.has("query") ? JSON.parse(p.get("query")!) : { table: p.get("table") }); return noStoreJson(await queryMiniRecords(db, (await params).id, principal.sub, query, {}, p.get("cursor") ?? undefined)); }); }
export async function POST(request: Request, { params }: Context) { return withApiAuth(request, async ({ db, principal }) => { miniEnabled(); const input = await readJson(request, v => schema.parse(v)); return noStoreJson(await mutateMiniRecordOnce(db, (await params).id, principal.sub, input)); }); }
