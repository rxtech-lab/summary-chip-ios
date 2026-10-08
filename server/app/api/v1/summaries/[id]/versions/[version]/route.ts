import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson } from "@/lib/http/errors";
import { getVersion, parseVersionNumber } from "@/lib/services/versions";

export const runtime = "nodejs";

/** One version with its `content`: a summary's text (`title`, `summary`, `highlights`…) or a trip's `document`. */
export async function GET(request: Request, { params }: { params: Promise<{ id: string; version: string }> }) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id, version } = await params;
    return noStoreJson(await getVersion(db, principal.sub, id, parseVersionNumber(version)));
  });
}
