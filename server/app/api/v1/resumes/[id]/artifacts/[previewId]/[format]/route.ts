import { withApiAuth, withMcpAuth } from "@/lib/http/handler";
import { ApiError, notFound } from "@/lib/http/errors";
import { ACCESS_TOKEN_PREFIX } from "@/lib/mcp/oauth-config";
import { API_KEY_PREFIX } from "@/lib/services/api-keys";
import { ownerArtifact, artifactMime } from "@/lib/services/resume-outputs";

export async function GET(
  request: Request,
  { params }: { params: Promise<{ id: string; previewId: string; format: string }> },
) {
  const auth = request.headers.get("authorization");
  const authenticated =
    auth?.startsWith("Bearer " + ACCESS_TOKEN_PREFIX) || auth?.startsWith("Bearer " + API_KEY_PREFIX)
      ? withMcpAuth
      : withApiAuth;
  return authenticated(request, async ({ db, principal }) => {
    if (
      auth?.startsWith("Bearer " + ACCESS_TOKEN_PREFIX) &&
      !principal.scopes.includes("chippy:read") &&
      !principal.scopes.includes("chippy:write")
    ) {
      throw new ApiError(403, "INSUFFICIENT_SCOPE", "This credential cannot read résumé artifacts");
    }
    const { id, previewId, format } = await params;
    if (format !== "pdf" && format !== "docx") throw notFound();
    return new Response(new Uint8Array(await ownerArtifact(db, principal.sub, id, previewId, format)), {
      headers: {
        "content-type": artifactMime[format],
        "cache-control": "private, no-store",
        "content-disposition": (format === "pdf" ? "inline" : "attachment") + '; filename="resume.' + format + '"',
      },
    });
  });
}
