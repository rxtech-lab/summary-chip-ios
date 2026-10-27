import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { dailyRecapSettings, dailyRecapSettingsSchema, saveDailyRecapSettings } from "@/lib/services/daily-recap";
import { billingEnvironment } from "@/lib/subscription/environment";

export const runtime = "nodejs";
export async function GET(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => noStoreJson(await dailyRecapSettings(db, principal.sub)));
}
export async function PUT(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => {
    const input = await readJson(request, body => dailyRecapSettingsSchema.parse(body));
    return noStoreJson(await saveDailyRecapSettings(db, principal.sub, input, await billingEnvironment(request, principal)));
  });
}
