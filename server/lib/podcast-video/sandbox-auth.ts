/** Vercel deployment OIDC is the default; explicit credentials support local operator setup. */
export function sandboxCredentials() {
  if (!process.env.VERCEL_TOKEN) return {};
  if (!process.env.VERCEL_TEAM_ID || !process.env.VERCEL_PROJECT_ID) throw new Error("Vercel team and project are required with VERCEL_TOKEN");
  return { token: process.env.VERCEL_TOKEN, teamId: process.env.VERCEL_TEAM_ID, projectId: process.env.VERCEL_PROJECT_ID };
}
