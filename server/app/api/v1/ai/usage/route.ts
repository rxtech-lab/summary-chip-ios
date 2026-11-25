import { flowcyModelUsage } from "@/lib/ai/flowcy";
import { noStoreJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";

export async function GET(request: Request) {
  return withApiAuth(request, async () => {
    const usage = await flowcyModelUsage(request.headers.get("authorization")!, request.signal);
    return noStoreJson(usage);
  }, { requireSubscription: true });
}
