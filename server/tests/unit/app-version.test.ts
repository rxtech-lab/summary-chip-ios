import { afterEach, describe, expect, it, vi } from "vitest";
import { MAC_DOWNLOAD_URL } from "@/lib/config";
import { appClient, compareVersions, requireAppFeature, supportsAppFeature } from "@/lib/http/app-version";
import { ApiError } from "@/lib/http/errors";

function request(headers: Record<string, string> = {}): Request {
  return new Request("http://localhost/api/v1/trips", { headers });
}

afterEach(() => vi.unstubAllEnvs());

describe("app version", () => {
  it("compares dotted versions numerically", () => {
    expect(compareVersions("1.10.0", "1.9.0")).toBeGreaterThan(0);
    expect(compareVersions("1.9", "1.9.0")).toBe(0);
    expect(compareVersions("v2.0.0-beta", "2.0.0")).toBe(0);
    expect(compareVersions("1.8.9", "1.9.0")).toBeLessThan(0);
  });

  it("reads the app headers and ignores invalid versions", () => {
    expect(appClient(request({ "x-app-version": "1.9.1", "x-app-build": "42", "x-app-platform": "iOS" })))
      .toEqual({ version: "1.9.1", build: "42", platform: "ios" });
    expect(appClient(request({ "x-app-version": "latest" }))).toBeNull();
    expect(appClient(request())).toBeNull();
  });

  it("lets clients without a version header through", () => {
    expect(supportsAppFeature(request(), "trips")).toBe(true);
    expect(() => requireAppFeature(request(), "trips")).not.toThrow();
    expect(() => requireAppFeature(request({ "x-app-version": "1.9.0" }), "trips")).not.toThrow();
  });

  it("asks older apps to update to the feature's version", () => {
    vi.stubEnv("APP_STORE_ID", "123456789");
    const error = (() => {
      try { requireAppFeature(request({ "x-app-version": "1.8.0", "x-app-platform": "ios" }), "trips"); } catch (caught) { return caught; }
    })();
    expect(error).toBeInstanceOf(ApiError);
    expect(error).toMatchObject({
      status: 426,
      code: "APP_UPDATE_REQUIRED",
      details: { feature: "trips", requiredVersion: "1.9.0", currentVersion: "1.8.0", updateUrl: "https://apps.apple.com/app/id123456789" },
    });
  });

  it("links the Mac download for the macOS app", () => {
    expect(() => requireAppFeature(request({ "x-app-version": "1.0.0", "x-app-platform": "macos" }), "trips"))
      .toThrow(expect.objectContaining({ details: expect.objectContaining({ updateUrl: MAC_DOWNLOAD_URL }) }));
  });
});
