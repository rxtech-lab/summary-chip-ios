import { putPaperSchema } from "@/lib/contracts/paper";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { autosavePaper, getOwnedPaper, getPaper } from "@/lib/services/papers";
import { deleteSummary } from "@/lib/services/summaries";
import { z } from "zod";
import { TRANSLATION_LANGUAGES } from "@/lib/contracts/api";

export const runtime = "nodejs";
/** An autosave checks the bibliography entries it changed after the response (see `paper-references.ts`). */
export const maxDuration = 300;

type Context = { params: Promise<{ id: string }> };

/** The paper's working copy (owner), or the paper read-only for anyone who may open it. */
export async function GET(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    const raw = new URL(request.url).searchParams.get("lang");
    const language = raw === null ? undefined : z.enum(["original", ...TRANSLATION_LANGUAGES]).parse(raw);
    return noStoreJson({ paper: await getPaper(db, id, principal.sub, { language }) });
  }, { feature: "papers" });
}

/**
 * The editor's autosave of the working copy edited at `revision`; `409 PAPER_REVISION_CONFLICT`
 * when it changed since (usually an agent edit). Not a version: see `POST …/versions`.
 */
export async function PUT(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    const input = await readJson(request, (body) => putPaperSchema.parse(body));
    return noStoreJson({ paper: await autosavePaper(db, principal.sub, id, input) });
  }, { feature: "papers" });
}

/** Same as deleting the summary: the paper, its versions and its PDF go with it. */
export async function DELETE(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    await getOwnedPaper(db, id, principal.sub);
    await deleteSummary(db, principal.sub, id);
    return new Response(null, { status: 204, headers: { "cache-control": "no-store" } });
  }, { feature: "papers" });
}
