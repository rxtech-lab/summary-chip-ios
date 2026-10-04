import { apiKeyNameSchema } from "@/lib/contracts/api";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson, readJson } from "@/lib/http/errors";
import { renameApiKey, revokeApiKey } from "@/lib/services/api-keys";

export const runtime = "nodejs";

type Context = { params: Promise<{ id: string }> };

export async function PATCH(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    const input = await readJson(request, (body) => apiKeyNameSchema.parse(body));
    return noStoreJson(await renameApiKey(db, principal.sub, id, input.name));
  });
}

export async function DELETE(request: Request, { params }: Context) {
  return withApiAuth(request, async ({ principal, db }) => {
    const { id } = await params;
    await revokeApiKey(db, principal.sub, id);
    return new Response(null, { status: 204 });
  });
}
