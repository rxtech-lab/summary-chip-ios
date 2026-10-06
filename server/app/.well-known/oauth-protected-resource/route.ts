import { resourceMetadata } from "@/lib/mcp/oauth-config";
import { noStoreJson } from "@/lib/http/errors";

export const dynamic = "force-dynamic";
export async function GET() { return noStoreJson(resourceMetadata(), { headers: { "access-control-allow-origin": "*" } }); }
