import { noStoreJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { appleAccountToken } from "@/lib/subscription/flowcy";

export const runtime = "nodejs";

export async function POST(request: Request) {
  return withApiAuth(request, async ({ principal, storeEnvironment }) =>
    noStoreJson(await appleAccountToken(principal.sub, storeEnvironment)),
  );
}
