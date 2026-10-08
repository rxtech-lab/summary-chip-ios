import { z } from "zod";
import { TRANSLATION_LANGUAGES } from "@/lib/contracts/api";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { listPaperTranslations, translatePaper } from "@/lib/services/paper-translations";
import { findPaperForViewer, getPaper } from "@/lib/services/papers";
import { ApiError } from "@/lib/http/errors";
import { translationPayer } from "@/lib/services/translations";
import { billingEnvironment } from "@/lib/subscription/environment";

export const runtime = "nodejs";
export const maxDuration = 300;
type Context = { params: Promise<{ id: string }> };

export async function GET(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    const found = await findPaperForViewer(db, id, principal.sub);
    if (!found) throw new ApiError(404, "NOT_FOUND", "The paper does not exist");
    return noStoreJson(await listPaperTranslations(db, found.summary, found.paper));
  }, { feature: "papers" });
}

export async function POST(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    const input = await readJson(request, (body) => z.object({ language: z.enum(TRANSLATION_LANGUAGES).nullable().default(null) }).parse(body));
    const payer = translationPayer({ ownerId: principal.sub }, principal.sub, () => billingEnvironment(request, principal));
    await translatePaper(db, id, principal.sub, input.language, payer);
    return noStoreJson({ paper: await getPaper(db, id, principal.sub, {}) });
  }, { feature: "papers" });
}
