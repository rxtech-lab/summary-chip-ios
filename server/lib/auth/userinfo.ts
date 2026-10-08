import { z } from "zod";

/**
 * The signed-in user's email, from the identity provider's userinfo endpoint.
 *
 * rxlab-auth never puts `email` in access tokens (only in ID tokens), so the server has no email
 * for a user until it asks. Userinfo answers with the caller's own bearer token, and only includes
 * the email when the token was granted the `email` (`read:email`) scope.
 */

const UserInfoSchema = z.object({
  email: z.string().nullable().optional(),
  email_verified: z.boolean().nullable().optional(),
});

export type UserInfoEmailFetcher = (authorization: string) => Promise<string | null>;

let testFetcher: UserInfoEmailFetcher | undefined;

/** Lets tests answer userinfo without a network call. */
export function setUserInfoFetcherForTests(fetcher?: UserInfoEmailFetcher): void {
  testFetcher = fetcher;
}

function userInfoEndpoint(): string {
  const issuer = process.env.AUTH_ISSUER || "https://auth.rxlab.app";
  return `${issuer.replace(/\/$/, "")}/api/oauth/userinfo`;
}

/**
 * The verified, lowercased email of whoever holds `authorization` (an `Authorization: Bearer …`
 * header), or null when the token has no email scope, the address is unverified, or the IdP fails.
 */
export async function fetchUserInfoEmail(authorization: string): Promise<string | null> {
  if (testFetcher) return testFetcher(authorization);
  try {
    const response = await fetch(userInfoEndpoint(), {
      headers: { authorization, accept: "application/json" },
      cache: "no-store",
    });
    if (!response.ok) {
      console.error(`Identity provider userinfo returned ${response.status}`);
      return null;
    }
    const parsed = UserInfoSchema.safeParse(await response.json().catch(() => null));
    if (!parsed.success || !parsed.data.email || parsed.data.email_verified === false) return null;
    return parsed.data.email.trim().toLowerCase() || null;
  } catch (error) {
    console.error("Identity provider userinfo request failed:", error);
    return null;
  }
}
