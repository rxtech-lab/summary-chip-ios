import { BROWSER_USER_AGENT } from "./fetch";

/**
 * Cloudflare Browser Rendering's /content endpoint (account id is the path segment). It loads the
 * URL in headless Chromium and returns the rendered HTML in one synchronous call, so pages that
 * build their content with JavaScript (or block plain fetches) still yield readable text.
 */
const CONTENT_ENDPOINT = "https://api.cloudflare.com/client/v4/accounts/%s/browser-rendering/content";

const RENDER_TIMEOUT_MS = 45_000;

function log(message: string): void {
  if (process.env.NODE_ENV !== "test") console.info(`[extract] ${message}`);
}

interface BrowserRenderingConfig {
  accountId: string;
  apiToken: string;
}

/** Null unless CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_API_TOKEN (Browser Rendering - Edit) are set. */
export function browserRenderingConfig(): BrowserRenderingConfig | null {
  const accountId = process.env.CLOUDFLARE_ACCOUNT_ID?.trim();
  const apiToken = process.env.CLOUDFLARE_API_TOKEN?.trim();
  return accountId && apiToken ? { accountId, apiToken } : null;
}

/**
 * Renders a public URL in Cloudflare's headless browser and returns the page HTML, or null when
 * the service is not configured or the render fails — callers fall back to the static fetch.
 * The browser runs on Cloudflare's network, but callers must still pass a URL that is public by its
 * text (`assertPublicUrlSyntax`) or an SSRF-checked one.
 */
export async function renderWithBrowser(url: string, options: { maxChars?: number } = {}): Promise<string | null> {
  const config = browserRenderingConfig();
  if (!config) return null;
  const startedAt = Date.now();
  log(`browser run: rendering ${url}`);
  try {
    const response = await fetch(CONTENT_ENDPOINT.replace("%s", encodeURIComponent(config.accountId)), {
      method: "POST",
      signal: AbortSignal.timeout(RENDER_TIMEOUT_MS),
      headers: { authorization: `Bearer ${config.apiToken}`, "content-type": "application/json" },
      body: JSON.stringify({
        url,
        userAgent: BROWSER_USER_AGENT,
        gotoOptions: { waitUntil: "networkidle2", timeout: 30_000 },
        rejectResourceTypes: ["image", "media", "font", "stylesheet"],
      }),
    });
    if (!response.ok) {
      console.warn(`[extract] browser rendering failed for ${url}: HTTP ${response.status}`);
      return null;
    }
    const parsed = (await response.json()) as { success?: boolean; result?: unknown };
    if (!parsed.success || typeof parsed.result !== "string" || !parsed.result.trim()) {
      console.warn(`[extract] browser rendering returned no content for ${url}`);
      return null;
    }
    log(`browser run: rendered ${url} (${parsed.result.length} chars in ${Date.now() - startedAt}ms)`);
    const maxChars = options.maxChars ?? 10 * 1024 * 1024;
    return parsed.result.length > maxChars ? parsed.result.slice(0, maxChars) : parsed.result;
  } catch (error) {
    console.warn(`[extract] browser rendering failed for ${url}:`, (error as Error).message);
    return null;
  }
}
