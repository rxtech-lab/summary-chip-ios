import { z } from "zod";

/**
 * The signed-in user's email and display name, from the identity provider's userinfo endpoint.
 *
 * rxlab-auth never puts `email` or `name` in access tokens (only in ID tokens), so the server has
 * neither for a user until it asks. Userinfo answers with the caller's own bearer token. It always
 * includes the name, and only includes the email when the token was granted the `email`
 * (`read:email`) scope.
 */

const UserInfoSchema = z.object({
  email: z.string().nullable().optional(),
  email_verified: z.boolean().nullable().optional(),
  name: z.string().nullable().optional(),
  preferred_username: z.string().nullable().optional(),
});

export type UserInfoEmailFetcher = (authorization: string) => Promise<string | null>;
export type UserInfoNameFetcher = (authorization: string) => Promise<string | null>;

let testFetcher: UserInfoEmailFetcher | undefined;
let testNameFetcher: UserInfoNameFetcher | undefined;

/** Lets tests answer userinfo without a network call. */
export function setUserInfoFetcherForTests(fetcher?: UserInfoEmailFetcher): void {
  testFetcher = fetcher;
}

/** Lets tests answer userinfo's name without a network call. */
export function setUserInfoNameFetcherForTests(fetcher?: UserInfoNameFetcher): void {
  testNameFetcher = fetcher;
}

function userInfoEndpoint(): string {
  const issuer = process.env.AUTH_ISSUER || "https://auth.rxlab.app";
  return `${issuer.replace(/\/$/, "")}/api/oauth/userinfo`;
}

async function fetchUserInfo(authorization: string): Promise<z.infer<typeof UserInfoSchema> | null> {
  try {
    const response = await fetch(userInfoEndpoint(), {
      headers: { authorization, accept: "application/json" },
      cache: "no-store",
      signal: AbortSignal.timeout(5_000),
    });
    if (!response.ok) {
      console.error(`Identity provider userinfo returned ${response.status}`);
      return null;
    }
    const parsed = UserInfoSchema.safeParse(await response.json().catch(() => null));
    return parsed.success ? parsed.data : null;
  } catch (error) {
    console.error("Identity provider userinfo request failed:", error);
    return null;
  }
}

/**
 * The verified, lowercased email of whoever holds `authorization` (an `Authorization: Bearer …`
 * header), or null when the token has no email scope, the address is unverified, or the IdP fails.
 */
export async function fetchUserInfoEmail(authorization: string): Promise<string | null> {
  if (testFetcher) return testFetcher(authorization);
  const info = await fetchUserInfo(authorization);
  if (!info?.email || info.email_verified === false) return null;
  return info.email.trim().toLowerCase() || null;
}

/** The display name of whoever holds `authorization`, or their username when they haven't set one. */
export async function fetchUserInfoName(authorization: string): Promise<string | null> {
  if (testNameFetcher) return testNameFetcher(authorization);
  const info = await fetchUserInfo(authorization);
  return info?.name?.trim() || info?.preferred_username?.trim() || null;
}
