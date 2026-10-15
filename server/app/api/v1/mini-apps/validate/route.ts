import { withMiniAuth as withApiAuth } from "@/lib/mini-app/auth";
import { readMiniJson as readJson } from "@/lib/mini-app/auth";
import { noStoreJson } from "@/lib/http/errors";
import { miniEnabled } from "@/lib/mini-app/service";
export const runtime = "nodejs";
export const maxDuration = 60;
import { validateMiniApp } from "@/lib/mini-app/validation";
export async function POST(request: Request) { return withApiAuth(request, async () => { miniEnabled(); return noStoreJson(await validateMiniApp(await readJson(request, v => v))); }); }
