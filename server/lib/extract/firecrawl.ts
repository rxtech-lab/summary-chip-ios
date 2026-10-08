/**
 * Firecrawl's /v2/scrape endpoint: it opens the URL from Firecrawl's network (in a browser when the
 * page needs one, PDFs included) and returns the page as markdown with the target's HTTP status.
 */
const SCRAPE_ENDPOINT = "https://api.firecrawl.dev/v2/scrape";

const SCRAPE_TIMEOUT_MS = 60_000;

/** Null unless FIRECRAWL_API_KEY is set. */
export function firecrawlApiKey(): string | null {
  return process.env.FIRECRAWL_API_KEY?.trim() || null;
}

export interface FirecrawlPage {
  /** The target's HTTP status, or null when Firecrawl didn't report one. */
  statusCode: number | null;
  /** Where the page ended up after redirects. */
  finalUrl: string | null;
  title: string | null;
  markdown: string;
}

interface ScrapeResponse {
  success?: boolean;
  error?: string;
  data?: {
    markdown?: string;
    metadata?: { title?: string | string[]; statusCode?: number; url?: string; sourceURL?: string; error?: string | null };
  };
}

/**
 * Scrapes a URL with Firecrawl. Returns null when Firecrawl isn't configured or the call fails
 * (callers fall back to their own fetch). Firecrawl runs off our network, but callers must still
 * pass a URL that is public by its text (`assertPublicUrlSyntax`).
 */
export async function scrapeWithFirecrawl(url: string): Promise<FirecrawlPage | null> {
  const apiKey = firecrawlApiKey();
  if (!apiKey) return null;
  try {
    const response = await fetch(SCRAPE_ENDPOINT, {
      method: "POST",
      signal: AbortSignal.timeout(SCRAPE_TIMEOUT_MS),
      headers: { authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
      body: JSON.stringify({ url, formats: ["markdown"], onlyMainContent: true, timeout: SCRAPE_TIMEOUT_MS - 10_000 }),
    });
    const parsed = (await response.json().catch(() => null)) as ScrapeResponse | null;
    if (!response.ok || !parsed?.success || !parsed.data) {
      console.warn(`[extract] firecrawl failed for ${url}: HTTP ${response.status}${parsed?.error ? ` ${parsed.error}` : ""}`);
      return null;
    }
    const metadata = parsed.data.metadata ?? {};
    const title = Array.isArray(metadata.title) ? metadata.title[0] : metadata.title;
    return {
      statusCode: typeof metadata.statusCode === "number" ? metadata.statusCode : null,
      finalUrl: metadata.url ?? metadata.sourceURL ?? null,
      title: title?.trim() || null,
      markdown: parsed.data.markdown ?? "",
    };
  } catch (error) {
    console.warn(`[extract] firecrawl failed for ${url}:`, (error as Error).message);
    return null;
  }
}
