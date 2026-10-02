/** Environment-derived settings. Everything is read lazily so builds work without env vars. */

export const ALLOWED_TTL_DAYS = [1, 3, 7, 30, 90, 365] as const;
export type TtlDays = (typeof ALLOWED_TTL_DAYS)[number];

export function siteUrl(): string {
  return (process.env.NEXT_PUBLIC_SITE_URL || "https://summary.rxlab.app").replace(/\/+$/, "");
}

/**
 * Public base URL of the R2 bucket's custom domain (e.g. `https://cdn.summary.rxlab.app`), or null.
 * When set, OG images of public summaries are served straight from Cloudflare's CDN.
 */
export function r2PublicBaseUrl(): string | null {
  const raw = process.env.R2_PUBLIC_BASE_URL?.trim().replace(/\/+$/, "");
  return raw ? raw : null;
}

export function defaultTtlDays(): TtlDays | null {
  const raw = process.env.DEFAULT_TTL_DAYS?.trim();
  if (!raw) return 7;
  if (raw === "never" || raw === "null" || raw === "0") return null;
  const value = Number(raw);
  return (ALLOWED_TTL_DAYS as readonly number[]).includes(value) ? (value as TtlDays) : 7;
}

export function expiresAtFor(ttlDays: number | null, from = new Date()): Date | null {
  return ttlDays === null ? null : new Date(from.getTime() + ttlDays * 24 * 60 * 60 * 1000);
}

export const APPLE_TEAM_ID_DEFAULT = "P9KK452K8P";
export const APP_BUNDLE_ID = "com.rxlab.summary-chip";
export const APP_CLIP_BUNDLE_ID = "com.rxlab.summary-chip.Clip";

export function appleTeamId(): string {
  return process.env.APPLE_TEAM_ID || APPLE_TEAM_ID_DEFAULT;
}

/** Always resolves to the DMG attached to the newest published GitHub release. */
export const MAC_DOWNLOAD_URL = "https://github.com/rxtech-lab/summary-chip-ios/releases/latest/download/SummaryChip.dmg";

/** App Store listing for the iOS app, or null until `APP_STORE_ID` is configured. */
export function appStoreUrl(): string | null {
  const appId = process.env.APP_STORE_ID?.trim();
  return appId && /^\d+$/.test(appId) ? `https://apps.apple.com/app/id${appId}` : null;
}
