import { afterEach, describe, expect, it, vi } from "vitest";
import { openReferenceLink } from "@/lib/services/paper-references";

function firecrawlReply(metadata: Record<string, unknown>, markdown = "") {
  return vi.fn(async () => Response.json({ success: true, data: { markdown, metadata } }));
}

describe("openReferenceLink with Firecrawl", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.unstubAllEnvs();
  });

  it("opens the link through Firecrawl and keeps the page's status and title", async () => {
    vi.stubEnv("FIRECRAWL_API_KEY", "fc-test");
    const fetchMock = firecrawlReply({ statusCode: 200, title: "GitHub - sirily11/msbd5017-docs", url: "https://github.com/sirily11/msbd5017-docs" }, "# msbd5017-docs");
    vi.stubGlobal("fetch", fetchMock);

    const link = await openReferenceLink("https://github.com/sirily11/msbd5017-docs");

    expect(link).toMatchObject({ reachable: true, httpStatus: 200, title: "GitHub - sirily11/msbd5017-docs", text: "# msbd5017-docs", note: null });
    const [endpoint, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(endpoint).toBe("https://api.firecrawl.dev/v2/scrape");
    expect(new Headers(init.headers).get("authorization")).toBe("Bearer fc-test");
    expect(JSON.parse(String(init.body))).toMatchObject({ url: "https://github.com/sirily11/msbd5017-docs", formats: ["markdown"] });
  });

  it("reports a 404 page as unreachable even though it has content", async () => {
    vi.stubEnv("FIRECRAWL_API_KEY", "fc-test");
    vi.stubGlobal("fetch", firecrawlReply({ statusCode: 404, title: "Page not found · GitHub" }, "404 This is not the web page you are looking for"));

    const link = await openReferenceLink("https://github.com/sirily11/no-such-repo");

    expect(link).toMatchObject({ reachable: false, httpStatus: 404, note: "HTTP 404." });
  });

  it("treats a blocked page with content as loaded", async () => {
    vi.stubEnv("FIRECRAWL_API_KEY", "fc-test");
    vi.stubGlobal("fetch", firecrawlReply({ statusCode: 403, title: "Article" }, "Abstract …"));

    const link = await openReferenceLink("https://publisher.example.com/article");

    expect(link.reachable).toBe(true);
    expect(link.httpStatus).toBe(403);
  });

  it("never sends local or private addresses to Firecrawl", async () => {
    vi.stubEnv("FIRECRAWL_API_KEY", "fc-test");
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);

    for (const url of ["http://localhost:3000/", "http://10.0.0.5/", "http://db.internal/"]) {
      expect(await openReferenceLink(url)).toMatchObject({ reachable: false, note: "The link is not a public web address." });
    }
    expect(fetchMock).not.toHaveBeenCalled();
  });
});
