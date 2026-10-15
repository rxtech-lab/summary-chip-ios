import { withApiAuth } from "@/lib/http/handler";
import { fetchUserInfoEmail } from "@/lib/auth/userinfo";
import { ensureUser, getUser } from "@/lib/services/users";

/** RxAuth may omit email from access tokens. Resolve it only from the authenticated issuer. */
export const withMiniAuth: typeof withApiAuth = (request, handler) => withApiAuth(request, async context => {
  const user = await getUser(context.db, context.principal.sub);
  if (!user?.email) {
    const email = await fetchUserInfoEmail(request.headers.get("authorization") ?? "");
    if (email) await ensureUser(context.db, { ...context.principal, email });
  }
  return handler(context);
});

import { readJson, ApiError } from "@/lib/http/errors";
import { boundedMiniJson } from "./bounds";
export const readMiniJson: typeof readJson = (request, parse) => readJson(request, value => {
  if (!boundedMiniJson(value)) throw new ApiError(422, "MINI_JSON_LIMIT", "JSON is too large or deeply nested");
  return parse(value);
});
