import { requireApiPrincipal } from "@/lib/auth/bearer";
import { getDatabase } from "@/lib/db/client";
import { ApiError, errorResponse, noStoreJson, notFound } from "@/lib/http/errors";
import {
  resolveResumePublication,
  artifactBytes,
  avatarBytes,
  recipientDocument,
  rememberPublication,
} from "@/lib/services/resume-outputs";
import { shareViewerFor } from "@/lib/services/share-access";
import { ensureUser } from "@/lib/services/users";

export async function readPublishedResume(
  request: Request,
  slug: string,
  format: "pdf" | "html" | "json" | "avatar" | "page",
  assetId?: string,
) {
  try {
    const db = getDatabase();
    const principal = request.headers.has("authorization") ? await requireApiPrincipal(request) : null;
    const result = await resolveResumePublication(db, slug, shareViewerFor(principal, request));
    const headers = new Headers({
      "cache-control": "private, no-store",
      vary: "Authorization",
      "x-content-type-options": "nosniff",
      "referrer-policy": "no-referrer",
    });
    const base = "/s/" + encodeURIComponent(slug);
    if (format === "page" && result.status === "sign-in") {
      headers.set("content-type", "text/html; charset=utf-8");
      return new Response(
        `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex,nofollow"><title>Private résumé</title></head><body style="font:1rem/1.5 system-ui;max-width:35rem;margin:8vh auto;padding:1rem"><h1>Private résumé</h1><p>Open Chippy and sign in with the invited email address.</p><a href="summarychip://s/${encodeURIComponent(slug)}">Open in Chippy</a></body></html>`,
        { headers },
      );
    }
    if (result.status === "sign-in")
      throw new ApiError(403, "SIGN_IN_REQUIRED", "Open Chippy and sign in to view this résumé");
    if (result.status === "forbidden")
      throw new ApiError(403, "NOT_INVITED", "This link is only for the invited account");
    if (result.status !== "ok") throw notFound();
    const { preview, link } = result;
    if (format === "json") {
      if (principal) {
        await ensureUser(db, principal);
        await rememberPublication(db, principal.sub, link.id);
      }
      return noStoreJson(
        { ...recipientDocument(preview, slug), expiresAt: link.expiresAt?.toISOString() },
        { headers },
      );
    }
    if (format === "pdf") {
      headers.set("content-type", "application/pdf");
      headers.set("content-disposition", 'attachment; filename="resume.pdf"');
      return new Response(await artifactBytes(db, preview.id, "pdf"), { headers });
    }
    if (format === "avatar") {
      if (!preview.assetId || preview.assetId !== assetId) throw notFound();
      headers.set("content-type", "image/jpeg");
      return new Response(new Uint8Array(await avatarBytes(db, preview.familyId, preview.assetId)), { headers });
    }
    headers.set("content-type", "text/html; charset=utf-8");
    headers.set(
      "content-security-policy",
      "default-src 'none'; style-src 'unsafe-inline'; img-src 'self'; frame-ancestors 'self'; base-uri 'none'; form-action 'none'",
    );
    const html = preview.assetId
      ? preview.html.replace(
          'src="__resume_avatar__"',
          'src="/s/' + encodeURIComponent(slug) + "/avatar/" + encodeURIComponent(preview.assetId) + '"',
        )
      : preview.html;
    if (format === "page") {
      const nav = `<nav style="max-width:820px;margin:1rem auto;text-align:right;padding:0 1rem"><a href="${base}/resume.pdf" download>Download PDF</a></nav>`;
      return new Response(html.replace("<body>", "<body>" + nav), { headers });
    }
    return new Response(html, { headers });
  } catch (error) {
    const response = errorResponse(error);
    response.headers.set("cache-control", "private, no-store");
    return response;
  }
}
