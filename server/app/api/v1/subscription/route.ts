import { appClient } from "@/lib/http/app-version";
import { noStoreJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { appleProductId, flowcyAccess } from "@/lib/subscription/flowcy";

export const runtime = "nodejs";

export async function GET(request: Request) {
  return withApiAuth(request, async ({ principal, storeEnvironment }) => {
    const access = await flowcyAccess(principal.sub, storeEnvironment);
    const productId = !access.active && appClient(request)?.platform === "ios"
      ? await appleProductId(principal.sub, storeEnvironment)
      : null;
    return noStoreJson({ ...access, productId });
  });
}
