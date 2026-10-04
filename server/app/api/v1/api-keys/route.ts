import { apiKeyNameSchema } from "@/lib/contracts/api";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { createApiKey, listApiKeys } from "@/lib/services/api-keys";

export const runtime = "nodejs";

/** The caller's MCP API keys with their usage, newest first. OAuth bearer token required (keys can't list keys). */
export async function GET(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => noStoreJson({ items: await listApiKeys(db, principal.sub) }));
}

/** Creates a key; the response is the only time `key` is returned. */
export async function POST(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => {
    const input = await readJson(request, (body) => apiKeyNameSchema.parse(body));
    return noStoreJson(await createApiKey(db, principal.sub, input.name), { status: 201 });
  });
}
