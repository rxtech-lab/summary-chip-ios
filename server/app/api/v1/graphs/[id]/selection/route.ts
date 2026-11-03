import { putGraphSelectionSchema } from "@/lib/contracts/graph";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { setGraphSelection } from "@/lib/services/graphs";

export const runtime = "nodejs";

type Context = { params: Promise<{ id: string }> };

/** Keeps or clears what the view picks out, so it survives a reload. Adds no version. */
export async function PUT(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    const { selection } = await readJson(request, (body) => putGraphSelectionSchema.parse(body));
    return noStoreJson({ selection: await setGraphSelection(db, principal.sub, id, selection) });
  });
}
