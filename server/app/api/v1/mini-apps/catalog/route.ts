import { withMiniAuth as withApiAuth } from "@/lib/mini-app/auth";
import { noStoreJson } from "@/lib/http/errors";
import { miniEnabled } from "@/lib/mini-app/service";
export const runtime = "nodejs";
export const maxDuration = 60;
import { miniAppCatalog } from "@/lib/contracts/mini-app";
export async function GET(request: Request) { return withApiAuth(request, async () => { miniEnabled(); return noStoreJson(miniAppCatalog()); }); }
