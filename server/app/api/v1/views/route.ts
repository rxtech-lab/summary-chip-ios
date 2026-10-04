import { recordViewSchema } from "@/lib/contracts/api";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { acceptedLanguage } from "@/lib/services/translations";
import { recordView } from "@/lib/services/views";
import { billingEnvironment } from "@/lib/subscription/environment";

export const runtime = "nodejs";
/** Translating the source document continues after the response (`after`). */
export const maxDuration = 300;

export async function POST(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { slug } = await readJson(request, (body) => recordViewSchema.parse(body));
    return noStoreJson(await recordView(db, principal.sub, slug, {
      accepted: acceptedLanguage(request),
      billingEnvironment: () => billingEnvironment(request, principal),
    }));
  });
}
