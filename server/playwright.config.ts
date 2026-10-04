import { defineConfig } from "@playwright/test";

const APP_PORT = 3100;
const ISSUER_PORT = 3101;
export const E2E_CLIENT_ID = "e2e-client";
export const ISSUER_URL = `http://127.0.0.1:${ISSUER_PORT}`;

/**
 * End-to-end API tests against a real `next dev` server: mock AI + in-memory object store
 * (`SUMMARY_MOCK_SERVICES`), a fresh SQLite file database, and bearer tokens signed by a local mock
 * issuer. Values set here win over `.env`; every credential it may hold is blanked so no real
 * service (R2, AI Gateway, RxSubscription, Browser Rendering) is called.
 */
const serverEnv: Record<string, string> = {
  SUMMARY_MOCK_SERVICES: "true",
  SUMMARY_OG_REMOTE_ASSETS: "false",
  TURSO_DATABASE_URL: "file:.e2e/e2e.db",
  TURSO_AUTH_TOKEN: "",
  AUTH_ISSUER: ISSUER_URL,
  IOS_OAUTH_CLIENT_ID: E2E_CLIENT_ID,
  RXLAB_ALLOWED_CLIENT_IDS: "",
  NEXT_PUBLIC_SITE_URL: `http://127.0.0.1:${APP_PORT}`,
  DEFAULT_TTL_DAYS: "7",
  AI_GATEWAY_API_KEY: "",
  R2_ACCOUNT_ID: "",
  R2_ACCESS_KEY_ID: "",
  R2_SECRET_ACCESS_KEY: "",
  R2_PUBLIC_BASE_URL: "",
  CRON_SECRET: "",
  CLOUDFLARE_ACCOUNT_ID: "",
  CLOUDFLARE_API_TOKEN: "",
  RX_SUBSCRIPTION_URL: "",
  RX_SUBSCRIPTION_ENVIRONMENT: "",
  RX_SUBSCRIPTION_API_KEY: "",
  RX_SUBSCRIPTION_PUBLISHABLE_KEY: "",
  RX_SUBSCRIPTION_PRODUCTION_API_KEY: "",
  RX_SUBSCRIPTION_SANDBOX_API_KEY: "",
  RX_SUBSCRIPTION_XCODE_API_KEY: "",
  RX_SUBSCRIPTION_PRODUCTION_PUBLISHABLE_KEY: "",
  RX_SUBSCRIPTION_SANDBOX_PUBLISHABLE_KEY: "",
  RX_SUBSCRIPTION_XCODE_PUBLISHABLE_KEY: "",
};

export default defineConfig({
  testDir: "tests/e2e",
  testMatch: "**/*.spec.ts",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI ? [["github"], ["html", { open: "never" }]] : "list",
  // Dev mode compiles each route on first hit.
  timeout: 90_000,
  use: { baseURL: `http://127.0.0.1:${APP_PORT}` },
  webServer: [
    {
      command: "bun tests/e2e/mock-issuer.ts",
      url: `${ISSUER_URL}/.well-known/jwks.json`,
      env: { MOCK_ISSUER_PORT: String(ISSUER_PORT) },
      reuseExistingServer: false,
    },
    {
      command: `rm -rf .e2e && mkdir .e2e && bun scripts/migrate.ts && bunx next dev --port ${APP_PORT} --hostname 127.0.0.1`,
      // Any response means the server is up; the legal route needs no auth or database.
      url: `http://127.0.0.1:${APP_PORT}/api/v1/legal/terms`,
      env: serverEnv,
      timeout: 180_000,
      reuseExistingServer: false,
    },
  ],
});
