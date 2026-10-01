import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson } from "@/lib/http/errors";
import { storefrontConfig } from "@/lib/subscription/config";
import { billingEnvironment } from "@/lib/subscription/environment";
import { SUMMARY_USAGE_ITEM } from "@/lib/subscription/usage";

export const runtime = "nodejs";

/** Return only the matching publishable key; secret keys never leave the server. */
export async function GET(request: Request) {
  return withApiAuth(request, async ({ principal }) => noStoreJson({
    ...storefrontConfig(await billingEnvironment(request, principal)),
    usageItem: SUMMARY_USAGE_ITEM,
    balanceUnit: "points",
  }));
}
