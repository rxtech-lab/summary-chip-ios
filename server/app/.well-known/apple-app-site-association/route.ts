import { appSiteAssociation } from "@/lib/aasa";

export const dynamic = "force-dynamic";

/** Served as JSON without an extension, as Apple requires. */
export async function GET() {
  return Response.json(appSiteAssociation(), {
    headers: { "content-type": "application/json", "cache-control": "public, max-age=3600" },
  });
}
