import { WebStandardStreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js";
import { withApiKeyAuth } from "@/lib/http/handler";
import { createMcpServer } from "@/lib/mcp/server";
import { acceptedLanguage } from "@/lib/services/translations";
import { billingEnvironment } from "@/lib/subscription/environment";

export const runtime = "nodejs";
/** `add_summary` checks for duplicates and designs the cover before answering (the import route allows 180 s). */
export const maxDuration = 300;

/**
 * The hosted MCP server (Streamable HTTP, stateless): agents add, search and list the key owner's
 * chips. Authenticated by a personal API key from Settings → MCP Server; see docs/mcp.md.
 */
export async function POST(request: Request) {
  return withApiKeyAuth(request, async ({ principal, db }) => {
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
      return await transport.handleRequest(request);
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
