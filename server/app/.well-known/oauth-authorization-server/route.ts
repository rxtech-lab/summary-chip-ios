import { authorizationMetadata } from "@/lib/mcp/oauth-config";
import { noStoreJson } from "@/lib/http/errors";

export const dynamic = "force-dynamic";
export async function GET() { return noStoreJson(authorizationMetadata(), { headers: { "access-control-allow-origin": "*" } }); }
