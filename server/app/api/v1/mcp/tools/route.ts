import { noStoreJson } from "@/lib/http/errors";
import { withApiAuth } from "@/lib/http/handler";
import { listMcpTools } from "@/lib/mcp/catalog";
import { acceptedLanguage } from "@/lib/services/translations";

export const runtime = "nodejs";

/** App-authenticated catalog for settings; derives its metadata from the hosted MCP server. */
export async function GET(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => noStoreJson({
    items: await listMcpTools({ db, principal, accepted: acceptedLanguage(request) }),
  }));
}
