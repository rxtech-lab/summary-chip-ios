import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson } from "@/lib/http/errors";
import { parseVersionNumber, restoreVersion } from "@/lib/services/versions";
import { billingEnvironment } from "@/lib/subscription/environment";

export const runtime = "nodejs";

/**
 * Saves the version's content as the newest version: `{ version, summary, trip }` with the item as
 * restored under its kind's key (the other is null), and `version` null when nothing changed.
 */
export async function POST(request: Request, { params }: { params: Promise<{ id: string; version: string }> }) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id, version } = await params;
    return noStoreJson(await restoreVersion(db, principal.sub, id, parseVersionNumber(version), {
      billingEnvironment: () => billingEnvironment(request, principal),
    }));
  });
}
