import { appStoreUrl, MAC_DOWNLOAD_URL } from "@/lib/config";
import { ApiError } from "@/lib/http/errors";

/** Headers every request from the Chippy apps carries (`SummaryKit/Networking/AppVersionHeaders.swift`). */
export const APP_VERSION_HEADER = "x-app-version";
export const APP_BUILD_HEADER = "x-app-build";
export const APP_PLATFORM_HEADER = "x-app-platform";

/**
 * The oldest app version that can use each feature whose API an older app can't handle.
 * Add an entry when a change isn't compatible with apps already released, and gate its routes
 * with `withApiAuth(request, action, { feature })` or `requireAppFeature` (see README → App versions).
 */
export const FEATURE_MIN_APP_VERSIONS = {
  /** Trip diaries (`/api/v1/trips/*`, chat about a trip). */
  trips: "1.9.0",
  /** LaTeX papers (`/api/v1/papers/*`). */
  papers: "1.13.0",
} as const satisfies Record<string, string>;

export type AppFeature = keyof typeof FEATURE_MIN_APP_VERSIONS;

export type AppPlatform = "ios" | "macos" | "visionos";

export interface AppClient {
  /** `CFBundleShortVersionString`, e.g. `1.9.0`. */
  version: string;
  build?: string;
  platform?: AppPlatform;
}

const PLATFORMS: readonly AppPlatform[] = ["ios", "macos", "visionos"];

/** Parses `1.9`, `1.9.0` or `v1.9.0-beta` into numeric parts; null when it isn't a version. */
export function parseVersion(value: string): number[] | null {
  const match = /^v?(\d+(?:\.\d+){0,3})(?:[-+].*)?$/.exec(value.trim());
  return match ? match[1].split(".").map(Number) : null;
}

/** Negative when `a` is older than `b`, 0 when equal, positive when newer (missing parts count as 0). */
export function compareVersions(a: string, b: string): number {
  const left = parseVersion(a) ?? [0];
  const right = parseVersion(b) ?? [0];
  for (let index = 0; index < Math.max(left.length, right.length); index++) {
    const difference = (left[index] ?? 0) - (right[index] ?? 0);
    if (difference !== 0) return difference;
  }
  return 0;
}

/**
 * The app that sent the request, or null when it carries no valid `X-App-Version`: tests, scripts,
 * and app builds released before the header was added (up to 1.9.x), which are let through.
 */
export function appClient(request: Request): AppClient | null {
  const version = request.headers.get(APP_VERSION_HEADER)?.trim().slice(0, 32);
  if (!version || !parseVersion(version)) return null;
  const build = request.headers.get(APP_BUILD_HEADER)?.trim().slice(0, 32) || undefined;
  const platform = request.headers.get(APP_PLATFORM_HEADER)?.trim().toLowerCase();
  return { version, build, platform: PLATFORMS.find((value) => value === platform) };
}

/** Whether the requesting app can use `feature`; clients without a version header always can. */
export function supportsAppFeature(request: Request, feature: AppFeature): boolean {
  const client = appClient(request);
  return !client || compareVersions(client.version, FEATURE_MIN_APP_VERSIONS[feature]) >= 0;
}

/**
 * Throws `426 APP_UPDATE_REQUIRED` when the app is older than `feature` needs. The app shows an alert
 * asking the user to update to `details.requiredVersion`, linking `details.updateUrl` when known.
 */
export function requireAppFeature(request: Request, feature: AppFeature): void {
  if (supportsAppFeature(request, feature)) return;
  const client = appClient(request)!;
  const requiredVersion = FEATURE_MIN_APP_VERSIONS[feature];
  const updateUrl = client.platform === "macos" ? MAC_DOWNLOAD_URL : appStoreUrl();
  throw new ApiError(
    426,
    "APP_UPDATE_REQUIRED",
    `This feature needs Chippy ${requiredVersion} or later. Update the app to keep using it.`,
    { feature, requiredVersion, currentVersion: client.version, ...(updateUrl ? { updateUrl } : {}) },
  );
}
