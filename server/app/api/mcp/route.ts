import { WebStandardStreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js";
import { withMcpAuth } from "@/lib/http/handler";
import { createMcpServer } from "@/lib/mcp/server";
import { securitySchemes } from "@/lib/mcp/oauth-config";
import { acceptedLanguage } from "@/lib/services/translations";
import { billingEnvironment } from "@/lib/subscription/environment";

export const runtime = "nodejs";
/** `add_summary` checks for duplicates and designs the cover before answering (the import route allows 180 s). */
export const maxDuration = 300;

/**
 * The hosted MCP server (Streamable HTTP, stateless): agents add, search and list the key owner's
 * chips. Authenticated through OAuth or a personal API key; see docs/mcp.md.
 */
export async function POST(request: Request) {
  return withMcpAuth(request, async ({ principal, db }) => {
    const server = createMcpServer({
      db,
      principal,
      billingEnvironment: await billingEnvironment(request, principal),
      accepted: acceptedLanguage(request),
    });
    // Stateless: no session ids, and each response is plain JSON instead of an SSE stream.
    const transport = new WebStandardStreamableHTTPServerTransport({ sessionIdGenerator: undefined, enableJsonResponse: true });
    await server.connect(transport);
    try {
      const response = await transport.handleRequest(request);
      // SDK 1.x serializes tool auth metadata only inside _meta. Also expose the standard
      // top-level declaration required by OpenAI hosts without changing other RPC results.
      if (response.headers.get("content-type")?.includes("application/json")) {
        const rpc = await response.clone().json();
        if (Array.isArray(rpc.result?.tools)) {
          for (const tool of rpc.result.tools) tool.securitySchemes = securitySchemes(tool.name);
          return Response.json(rpc, { status: response.status, headers: response.headers });
        }
      }
      return response;
    } finally {
      await server.close();
    }
  });
}

/** No server-initiated stream and no sessions to end: the spec's answer is 405. */
function methodNotAllowed() {
  return Response.json(
    { jsonrpc: "2.0", error: { code: -32000, message: "Method not allowed." }, id: null },
    { status: 405, headers: { allow: "POST" } },
  );
}

export const GET = methodNotAllowed;
export const DELETE = methodNotAllowed;
