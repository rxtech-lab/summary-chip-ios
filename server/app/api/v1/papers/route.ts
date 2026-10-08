import { createPaperSchema } from "@/lib/contracts/paper";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { createPaper, listPapers } from "@/lib/services/papers";

export const runtime = "nodejs";
/** Creating a paper designs and renders its cover. */
/** Designing the cover, then checking the template's references after the response. */
export const maxDuration = 300;

/** The caller's papers, most recently edited first. */
export async function GET(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => noStoreJson(await listPapers(db, principal.sub)), { feature: "papers" });
}

/** A new paper from `files` (+ `mainFile`), or from a `template`; it is version 1. */
export async function POST(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => {
    const input = await readJson(request, (body) => createPaperSchema.parse(body));
    return noStoreJson({ paper: await createPaper(db, principal, input) }, { status: 201 });
  }, { feature: "papers" });
}
