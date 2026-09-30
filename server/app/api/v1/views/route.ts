import { recordViewSchema } from "@/lib/contracts/api";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { recordView } from "@/lib/services/views";

export const runtime = "nodejs";

export async function POST(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { slug } = await readJson(request, (body) => recordViewSchema.parse(body));
    return noStoreJson(await recordView(db, principal.sub, slug));
  });
}
