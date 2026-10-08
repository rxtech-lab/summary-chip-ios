import { facetQuerySchema, queryObject } from "@/lib/contracts/api";
import { withApiAuth } from "@/lib/http/handler";
import { noStoreJson } from "@/lib/http/errors";
import { getFacets, searchFacets } from "@/lib/services/facets";

export const runtime = "nodejs";

/** Without `kind`: every facet at once. With `kind=category|tag`: one list, filtered by `q`, paged. */
export async function GET(request: Request) {
  return withApiAuth(request, async ({ principal, db }) => {
    const query = facetQuerySchema.parse(queryObject(request));
    if (!query.kind) return noStoreJson(await getFacets(db, principal.sub));
    return noStoreJson(await searchFacets(db, principal.sub, query.kind, query));
  });
}
