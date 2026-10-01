import sharp from "sharp";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as summariesRoute from "@/app/api/v1/summaries/route";
import * as summaryRoute from "@/app/api/v1/summaries/[id]/route";
import * as imageRoute from "@/app/api/v1/summaries/[id]/image/route";
import * as uploadsRoute from "@/app/api/v1/uploads/route";
import * as facetsRoute from "@/app/api/v1/facets/route";
import * as publicRoute from "@/app/api/public/summaries/[slug]/route";
import * as artRoute from "@/app/s/[slug]/art.png/route";
import * as ogRoute from "@/app/s/[slug]/og.png/route";
import * as sourceRoute from "@/app/s/[slug]/source/route";
import { ownerKeyPrefix } from "@/lib/storage/r2";
import { apiRequest, buildPdf, params, pngSize, setupTestEnv, type TestEnv } from "../helpers/setup";

const ARTICLE_HTML = `<!doctype html><html lang="en"><head>
<title>Quantum widgets explained</title>
<meta property="og:site_name" content="Widget Weekly">
<meta property="og:image" content="/cover.png">
</head><body><nav>Home About</nav><article><h1>Quantum widgets explained</h1>
${Array.from({ length: 8 }, (_, index) => `<p>Paragraph ${index}: quantum widgets are tiny devices that entangle gears across the lab, and researchers say they could transform manufacturing within a decade.</p>`).join("")}
</article><footer>Copyright</footer></body></html>`;

let env: TestEnv;

beforeEach(async () => {
  env = await setupTestEnv();
});

afterEach(() => {
  vi.unstubAllGlobals();
  env.teardown();
});

async function create(body: unknown, token = env.tokens.alice) {
  return summariesRoute.POST(apiRequest("POST", "/api/v1/summaries", { token, body }));
}

async function createText(text: string, extra: Record<string, unknown> = {}, token = env.tokens.alice) {
  const response = await create({ source: { type: "text", text, title: extra.title ?? null }, ...extra }, token);
  expect(response.status).toBe(201);
  return response.json();
}

describe("POST /api/v1/summaries", () => {
  it("requires a bearer token and returns the error envelope", async () => {
    const response = await summariesRoute.POST(apiRequest("POST", "/api/v1/summaries", { body: {} }));
    expect(response.status).toBe(401);
    const body = await response.json();
    expect(body.error).toMatchObject({ code: "MISSING_ACCESS_TOKEN", message: expect.any(String), requestId: expect.any(String) });
  });

  it("validates the body with zod", async () => {
    const response = await create({ source: { type: "text", text: "hi" }, ttlDays: 5 });
    expect(response.status).toBe(400);
    expect((await response.json()).error.code).toBe("VALIDATION_ERROR");
  });

  it("summarises a url source fetched with a browser UA and renders the OG image", async () => {
    const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      expect(String(input)).toBe("https://news.example.com/widgets");
      expect(new Headers(init?.headers).get("user-agent")).toMatch(/Mozilla\/5\.0/);
      return new Response(ARTICLE_HTML, { headers: { "content-type": "text/html; charset=utf-8" } });
    });
    vi.stubGlobal("fetch", fetchMock);
    const response = await create({ source: { type: "url", url: "https://news.example.com/widgets" }, language: "auto" });
    expect(response.status).toBe(201);
    const summary = await response.json();
    expect(summary).toMatchObject({
      sourceType: "url",
      source: "web",
      sourceUrl: "https://news.example.com/widgets",
      sourceTitle: "Quantum widgets explained",
      siteName: "Widget Weekly",
      sourceFileUrl: null,
      category: "Technology",
      imageStyle: "graphic",
      visibility: "public",
      ttlDays: 7,
      viewCount: 0,
      isOwner: true,
      language: "en",
    });
    expect(summary.slug).toMatch(/^[A-Za-z0-9]{10}$/);
    expect(summary.shareUrl).toBe(`https://summary.rxlab.app/s/${summary.slug}`);
    expect(summary.ogImageUrl).toBe(`${summary.shareUrl}/og.png?v=${new Date(summary.updatedAt).getTime()}`);
    expect(new Date(summary.expiresAt).getTime() - new Date(summary.createdAt).getTime()).toBe(7 * 86_400_000);
    expect(summary.theme).toEqual({ colors: expect.any(Array), mode: "dark", emoji: "🧪", accent: "#f59e0b" });
    expect(Object.keys(summary)).toEqual([
      "id", "slug", "shareUrl", "ogImageUrl", "artImageUrl", "sourceType", "source", "sourceUrl", "sourceTitle", "siteName", "sourceFileUrl",
      "title", "summary", "highlights", "category", "tags", "keywords", "language", "theme", "imageStyle", "visibility",
      "ttlDays", "expiresAt", "viewCount", "isOwner", "viewedAt", "createdAt", "updatedAt",
    ]);
    // Readability extracted the article, not the nav/footer chrome.
    const sent = env.ai.calls.summarize[0];
    expect(sent.text).toContain("quantum widgets are tiny devices");
    expect(sent.text).not.toContain("Copyright");
    // OG image and its text-free art stored as real 1200x630 PNGs under og/ and art/.
    expect(summary.artImageUrl).toBe(`${summary.shareUrl}/art.png?v=${new Date(summary.updatedAt).getTime()}`);
    const keys = [...env.store.objects.keys()].sort();
    expect(keys).toHaveLength(2);
    expect(keys[0]).toMatch(new RegExp(`^art/${summary.id}-\\d+-[0-9a-f]{12}\\.png$`));
    expect(keys[1]).toMatch(new RegExp(`^og/${summary.id}-\\d+-[0-9a-f]{12}\\.png$`));
    for (const key of keys) expect(pngSize(env.store.objects.get(key)!.bytes)).toEqual({ width: 1200, height: 630 });
  });

  it("records a url that serves a PDF as a pdf source", async () => {
    const bytes = buildPdf("Quarterly outlook: shipping volumes recovered as port congestion eased across Asia and Europe.");
    vi.stubGlobal("fetch", vi.fn(async () => new Response(bytes as BodyInit, { headers: { "content-type": "application/pdf" } })));
    const response = await create({ source: { type: "url", url: "https://corp.example.com/outlook.pdf" } });
    expect(response.status).toBe(201);
    expect(await response.json()).toMatchObject({ sourceType: "url", source: "pdf", sourceUrl: "https://corp.example.com/outlook.pdf", sourceFileUrl: null });
  });

  describe("with Cloudflare Browser Rendering configured", () => {
    const BROWSER_ENDPOINT = "https://api.cloudflare.com/client/v4/accounts/acct-123/browser-rendering/content";
    const RENDERED_HTML = ARTICLE_HTML.replace(/quantum widgets are tiny devices/g, "rendered widgets are tiny devices");

    beforeEach(() => {
      vi.stubEnv("CLOUDFLARE_ACCOUNT_ID", "acct-123");
      vi.stubEnv("CLOUDFLARE_API_TOKEN", "cf-token");
    });

    afterEach(() => {
      vi.unstubAllEnvs();
    });

    it("summarises the browser-rendered page and keeps static metadata as a fallback", async () => {
      const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
        if (String(input) === BROWSER_ENDPOINT) {
          expect(new Headers(init?.headers).get("authorization")).toBe("Bearer cf-token");
          expect(JSON.parse(String(init?.body))).toMatchObject({ url: "https://news.example.com/widgets" });
          return Response.json({ success: true, result: RENDERED_HTML.replace(/<meta property="og:site_name"[^>]*>/, "") });
        }
        return new Response(ARTICLE_HTML, { headers: { "content-type": "text/html" } });
      });
      vi.stubGlobal("fetch", fetchMock);
      const response = await create({ source: { type: "url", url: "https://news.example.com/widgets" } });
      expect(response.status).toBe(201);
      expect(await response.json()).toMatchObject({ source: "web", siteName: "Widget Weekly", sourceTitle: "Quantum widgets explained" });
      expect(env.ai.calls.summarize[0].text).toContain("rendered widgets are tiny devices");
      expect(fetchMock).toHaveBeenCalledTimes(2);
    });

    it("retries pages that block plain fetches in the browser", async () => {
      vi.stubGlobal("fetch", vi.fn(async (input: RequestInfo | URL) =>
        String(input) === BROWSER_ENDPOINT ? Response.json({ success: true, result: RENDERED_HTML }) : new Response("Forbidden", { status: 403 })));
      const response = await create({ source: { type: "url", url: "https://news.example.com/widgets" } });
      expect(response.status).toBe(201);
      expect(env.ai.calls.summarize[0].text).toContain("rendered widgets are tiny devices");
    });

    it("falls back to the static page when rendering fails", async () => {
      vi.stubGlobal("fetch", vi.fn(async (input: RequestInfo | URL) =>
        String(input) === BROWSER_ENDPOINT ? new Response("nope", { status: 500 }) : new Response(ARTICLE_HTML, { headers: { "content-type": "text/html" } })));
      const response = await create({ source: { type: "url", url: "https://news.example.com/widgets" } });
      expect(response.status).toBe(201);
      expect(env.ai.calls.summarize[0].text).toContain("quantum widgets are tiny devices");
    });
  });

  it("refuses private network URLs (SSRF)", async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
    for (const url of ["http://127.0.0.1/admin", "http://169.254.169.254/latest/meta-data", "http://intranet.internal-test/", "file:///etc/passwd"]) {
      const response = await create({ source: { type: "url", url } });
      expect([400, 422]).toContain(response.status);
    }
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("re-validates redirects against private addresses", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response(null, { status: 302, headers: { location: "http://10.0.0.1/secret" } })));
    const response = await create({ source: { type: "url", url: "https://news.example.com/redirect" } });
    expect(response.status).toBe(422);
    expect((await response.json()).error.code).toBe("URL_NOT_ALLOWED");
  });

  it("stores the illustration as the text-free art and lays the headline over it for the card", async () => {
    const drawn = new Uint8Array(await sharp({ create: { width: 1200, height: 630, channels: 3, background: "#336699" } }).png().toBuffer());
    const illustrate = vi.spyOn(env.ai, "illustrate").mockResolvedValue(drawn);
    const summary = await createText("Cats' eyes inspire new camera sensors for robots and drones.", { imageStyle: "illustration" });
    expect(illustrate).toHaveBeenCalledTimes(1);
    expect(env.ai.calls.designSvg).toHaveLength(0);
    const objects = [...env.store.objects.entries()];
    const art = objects.find(([key]) => key.startsWith("art/"))![1].bytes;
    const card = objects.find(([key]) => key.startsWith("og/"))![1].bytes;
    expect(Buffer.from(art).equals(Buffer.from(drawn))).toBe(true);
    expect(pngSize(card)).toEqual({ width: 1200, height: 630 });
    expect(Buffer.from(card).equals(Buffer.from(drawn))).toBe(false);
    expect(summary.artImageUrl).toContain("/art.png");
  });

  describe("platform sources", () => {
    it("reads X posts through oEmbed and labels them x", async () => {
      const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
        const url = new URL(String(input));
        expect(url.origin + url.pathname).toBe("https://publish.twitter.com/oembed");
        expect(url.searchParams.get("url")).toBe("https://x.com/widgets/status/12345");
        return Response.json({
          author_name: "Widget Weekly",
          html: "<blockquote class=\"twitter-tweet\"><p lang=\"en\">Quantum widgets entangle gears across the lab.<br>They could transform manufacturing.</p>&mdash; Widget Weekly</blockquote>",
        });
      });
      vi.stubGlobal("fetch", fetchMock);
      const response = await create({ source: { type: "url", url: "https://x.com/widgets/status/12345" } });
      expect(response.status).toBe(201);
      expect(await response.json()).toMatchObject({ source: "x", siteName: "X", sourceTitle: "Widget Weekly on X" });
      expect(env.ai.calls.summarize[0].text).toBe("Post by Widget Weekly:\n\nQuantum widgets entangle gears across the lab.\nThey could transform manufacturing.");
    });

    it("reads a YouTube video's details from the watch page and labels it youtube", async () => {
      const player = {
        videoDetails: { title: "Quantum widgets explained", author: "Widget Weekly", shortDescription: "How quantum widgets entangle gears across the lab.", thumbnail: { thumbnails: [{ url: "https://i.ytimg.com/vi/abcdefghijk/hq.jpg" }] } },
        captions: { playerCaptionsTracklistRenderer: { captionTracks: [{ baseUrl: "https://www.youtube.com/api/timedtext?v=abcdefghijk", kind: "asr" }] } },
      };
      const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
        const url = String(input);
        if (url.startsWith("https://www.youtube.com/api/timedtext")) {
          return Response.json({ events: [{ segs: [{ utf8: "Today we look at " }, { utf8: "widgets {and} gears." }] }] });
        }
        expect(url).toBe("https://www.youtube.com/watch?v=abcdefghijk&hl=en");
        return new Response(`<html><script>var ytInitialPlayerResponse = ${JSON.stringify(player)};var meta = {};</script></html>`, { headers: { "content-type": "text/html" } });
      });
      vi.stubGlobal("fetch", fetchMock);
      const response = await create({ source: { type: "url", url: "https://youtu.be/abcdefghijk?si=share" } });
      expect(response.status).toBe(201);
      expect(await response.json()).toMatchObject({ source: "youtube", siteName: "YouTube", sourceTitle: "Quantum widgets explained" });
      const sent = env.ai.calls.summarize[0].text;
      expect(sent).toContain("Channel: Widget Weekly");
      expect(sent).toContain("How quantum widgets entangle gears");
      expect(sent).toContain("Transcript:\nToday we look at widgets {and} gears.");
    });

    it("falls back to the page when a platform extractor fails, keeping the platform label", async () => {
      vi.stubGlobal("fetch", vi.fn(async () => new Response(ARTICLE_HTML, { headers: { "content-type": "text/html" } })));
      const video = await create({ source: { type: "url", url: "https://www.youtube.com/watch?v=abcdefghijk" } });
      expect(video.status).toBe(201);
      expect(await video.json()).toMatchObject({ source: "youtube", sourceTitle: "Quantum widgets explained" });
    });

    it("labels GitHub and Facebook pages by their URL", async () => {
      vi.stubGlobal("fetch", vi.fn(async () => new Response(ARTICLE_HTML, { headers: { "content-type": "text/html" } })));
      const repo = await create({ source: { type: "url", url: "https://github.com/widgets/quantum" } });
      expect(await repo.json()).toMatchObject({ source: "github" });
      const post = await create({ source: { type: "webpage", url: "https://m.facebook.com/widgets/posts/1", content: "Provided main text about quantum widgets. ".repeat(5) } });
      expect(await post.json()).toMatchObject({ sourceType: "webpage", source: "facebook" });
    });

    it("filters the library by source", async () => {
      vi.stubGlobal("fetch", vi.fn(async () => new Response(ARTICLE_HTML, { headers: { "content-type": "text/html" } })));
      const repo = await (await create({ source: { type: "url", url: "https://github.com/widgets/quantum" } })).json();
      await create({ source: { type: "url", url: "https://news.example.com/widgets" } });
      await createText("A plain text note about baking sourdough bread at home.");
      const list = async (query: string) => (await summariesRoute.GET(apiRequest("GET", `/api/v1/summaries?${query}`, { token: env.tokens.alice }))).json();
      expect((await list("source=github")).items.map((item: { id: string }) => item.id)).toEqual([repo.id]);
      expect((await list("source=web")).items).toHaveLength(1);
      expect((await list("source=text")).items).toHaveLength(1);
      expect((await list("source=youtube")).items).toHaveLength(0);
      expect((await summariesRoute.GET(apiRequest("GET", "/api/v1/summaries?source=tiktok", { token: env.tokens.alice }))).status).toBe(400);
    });
  });

  it("uses provided webpage content, falling back to fetching when it is empty", async () => {
    const fetchMock = vi.fn(async () => new Response(ARTICLE_HTML, { headers: { "content-type": "text/html" } }));
    vi.stubGlobal("fetch", fetchMock);
    const provided = await create({
      source: { type: "webpage", url: "https://blog.example.com/post", title: "My post", content: "Provided main text about sourdough baking. ".repeat(10), siteName: "Blog", lang: "en" },
      language: "fr",
      imageStyle: "illustration",
      ttlDays: null,
      visibility: "private",
    });
    expect(provided.status).toBe(201);
    expect(await provided.json()).toMatchObject({ sourceType: "webpage", source: "web", sourceTitle: "My post", siteName: "Blog", language: "fr", ttlDays: null, expiresAt: null, visibility: "private", imageStyle: "illustration" });
    expect(fetchMock).not.toHaveBeenCalled();
    // illustration requested but no image model → graphic fallback via SVG design
    expect(env.ai.calls.illustrate).toHaveLength(1);
    expect(env.ai.calls.designSvg).toHaveLength(1);

    const empty = await create({ source: { type: "webpage", url: "https://blog.example.com/other", title: "Other", content: "   " } });
    expect(empty.status).toBe(201);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect((await empty.json()).sourceTitle).toBe("Other");
  });

  it("summarises text sources", async () => {
    const summary = await createText("Plain notes about the migration of monarch butterflies across North America every autumn.", { title: "Notes" });
    expect(summary).toMatchObject({ sourceType: "text", source: "text", sourceUrl: null, siteName: null, sourceTitle: "Notes" });
  });

  it("creates pdf summaries from an owned upload and rejects foreign or scanned uploads", async () => {
    const uploadResponse = await uploadsRoute.POST(apiRequest("POST", "/api/v1/uploads", {
      token: env.tokens.alice,
      body: { filename: "report.pdf", mimeType: "application/pdf", byteSize: 2048 },
    }));
    expect(uploadResponse.status).toBe(201);
    const upload = await uploadResponse.json();
    expect(upload).toMatchObject({ method: "PUT", headers: { "content-type": "application/pdf" }, uploadUrl: expect.any(String), expiresAt: expect.any(String) });
    expect(upload.key).toMatch(new RegExp(`^uploads/${ownerKeyPrefix("user-alice")}/[0-9a-f-]{36}\\.pdf$`));

    const tooBig = await uploadsRoute.POST(apiRequest("POST", "/api/v1/uploads", {
      token: env.tokens.alice, body: { filename: "big.pdf", mimeType: "application/pdf", byteSize: 26 * 1024 * 1024 },
    }));
    expect(tooBig.status).toBe(400);

    // Not uploaded yet.
    const early = await create({ source: { type: "pdf", uploadKey: upload.key, filename: "report.pdf", sourceUrl: null } });
    expect(early.status).toBe(409);

    await env.store.put(upload.key, { bytes: buildPdf("Annual report: revenue grew twelve percent while costs fell, driven by strong demand for widgets in Europe."), contentType: "application/pdf" });

    const foreign = await create({ source: { type: "pdf", uploadKey: upload.key, filename: "report.pdf" } }, env.tokens.bob);
    expect(foreign.status).toBe(403);
    expect((await foreign.json()).error.code).toBe("UPLOAD_FORBIDDEN");

    const response = await create({ source: { type: "pdf", uploadKey: upload.key, filename: "report.pdf", sourceUrl: "https://corp.example.com/report.pdf" } });
    expect(response.status).toBe(201);
    const summary = await response.json();
    expect(summary).toMatchObject({ sourceType: "pdf", source: "pdf", sourceTitle: "report", siteName: "corp.example.com", sourceFileUrl: `${summary.shareUrl}/source` });
    expect(env.ai.calls.summarize.at(-1)!.text).toContain("revenue grew twelve percent");

    const reused = await create({ source: { type: "pdf", uploadKey: upload.key } });
    expect(reused.status).toBe(409);

    const source = await sourceRoute.GET(apiRequest("GET", `/s/${summary.slug}/source`), params({ slug: summary.slug }));
    expect(source.status).toBe(302);
    expect(source.headers.get("location")).toContain(encodeURIComponent(upload.key));

    // A scanned (text-less) PDF is a clear 422.
    const scanned = await (await uploadsRoute.POST(apiRequest("POST", "/api/v1/uploads", {
      token: env.tokens.alice, body: { filename: "scan.pdf", mimeType: "application/pdf", byteSize: 1000 },
    }))).json();
    await env.store.put(scanned.key, { bytes: buildPdf(), contentType: "application/pdf" });
    const scannedResponse = await create({ source: { type: "pdf", uploadKey: scanned.key } });
    expect(scannedResponse.status).toBe(422);
    const error = (await scannedResponse.json()).error;
    expect(error.code).toBe("PDF_NO_TEXT");
    expect(error.message).toMatch(/scanned PDF/);
  });
});

describe("list, search, facets", () => {
  it("lists owned summaries newest first with cursor pagination, FTS search and filters", async () => {
    const first = await createText("Solar panels and renewable energy storage are getting cheaper every single year.", { title: "Solar power" });
    const second = await createText("Deep learning accelerators from several chip makers compete on inference efficiency.", { title: "AI chips" });
    const third = await createText("Sourdough bread needs a lively starter, patience and a very hot oven to rise well.", { title: "Baking bread" });
    await createText("Bob's own notes about solar eclipses and astronomy clubs meeting in the park.", { title: "Bob solar" }, env.tokens.bob);

    const page1 = await (await summariesRoute.GET(apiRequest("GET", "/api/v1/summaries?limit=2", { token: env.tokens.alice }))).json();
    expect(page1.items.map((item: { id: string }) => item.id)).toEqual([third.id, second.id]);
    expect(page1.nextCursor).toEqual(expect.any(String));
    const page2 = await (await summariesRoute.GET(apiRequest("GET", `/api/v1/summaries?limit=2&cursor=${page1.nextCursor}`, { token: env.tokens.alice }))).json();
    expect(page2.items.map((item: { id: string }) => item.id)).toEqual([first.id]);
    expect(page2.nextCursor).toBeNull();

    const search = await (await summariesRoute.GET(apiRequest("GET", "/api/v1/summaries?q=sola", { token: env.tokens.alice }))).json();
    expect(search.items.map((item: { title: string }) => item.title)).toEqual(["Solar power"]);
    const tricky = await summariesRoute.GET(apiRequest("GET", `/api/v1/summaries?q=${encodeURIComponent('"bread" OR title:*')}`, { token: env.tokens.alice }));
    expect(tricky.status).toBe(200);
    expect((await tricky.json()).items.map((item: { title: string }) => item.title)).toEqual([]);
    const punctuation = await (await summariesRoute.GET(apiRequest("GET", `/api/v1/summaries?q=${encodeURIComponent("%%")}`, { token: env.tokens.alice }))).json();
    expect(punctuation.items).toEqual([]);

    const tag = second.tags[0];
    const byTag = await (await summariesRoute.GET(apiRequest("GET", `/api/v1/summaries?tag=${tag}`, { token: env.tokens.alice }))).json();
    expect(byTag.items.map((item: { id: string }) => item.id)).toContain(second.id);
    const byCategory = await (await summariesRoute.GET(apiRequest("GET", "/api/v1/summaries?category=Technology", { token: env.tokens.alice }))).json();
    expect(byCategory.items).toHaveLength(3);
    const badCursor = await summariesRoute.GET(apiRequest("GET", "/api/v1/summaries?cursor=nope", { token: env.tokens.alice }));
    expect(badCursor.status).toBe(400);

    const facets = await (await facetsRoute.GET(apiRequest("GET", "/api/v1/facets", { token: env.tokens.alice }))).json();
    expect(facets.categories).toEqual([{ name: "Technology", count: 3 }]);
    expect(facets.tags.length).toBeGreaterThan(0);
    expect(facets.tags[0]).toEqual({ name: expect.any(String), count: expect.any(Number) });

    const categoryPage = await (await facetsRoute.GET(apiRequest("GET", "/api/v1/facets?kind=category&limit=10", { token: env.tokens.alice }))).json();
    expect(categoryPage.items).toHaveLength(10);
    expect(categoryPage.items[0]).toEqual({ name: "Technology", count: 3 });
    expect(categoryPage.nextCursor).toEqual(expect.any(String));
    const categoryRest = await (await facetsRoute.GET(apiRequest("GET", `/api/v1/facets?kind=category&limit=10&cursor=${categoryPage.nextCursor}`, { token: env.tokens.alice }))).json();
    expect(categoryRest.items.length + 10).toBe(17);
    expect(categoryRest.nextCursor).toBeNull();
    const categorySearch = await (await facetsRoute.GET(apiRequest("GET", "/api/v1/facets?kind=category&q=sci", { token: env.tokens.alice }))).json();
    expect(categorySearch.items).toEqual([{ name: "Science", count: 0 }]);
    const tagSearch = await (await facetsRoute.GET(apiRequest("GET", `/api/v1/facets?kind=tag&q=${encodeURIComponent(tag.slice(0, 3))}`, { token: env.tokens.alice }))).json();
    expect(tagSearch.items.map((item: { name: string }) => item.name)).toContain(tag);
    const noTags = await (await facetsRoute.GET(apiRequest("GET", "/api/v1/facets?kind=tag&q=%25%25", { token: env.tokens.alice }))).json();
    expect(noTags).toEqual({ items: [], nextCursor: null });
  });

  it("searches CJK text with the LIKE fallback", async () => {
    await createText("人工智能正在改变世界的每一个角落，从医疗到教育再到交通运输，影响深远而广泛。", { title: "人工智能的未来" });
    const result = await (await summariesRoute.GET(apiRequest("GET", `/api/v1/summaries?q=${encodeURIComponent("智能")}`, { token: env.tokens.alice }))).json();
    expect(result.items).toHaveLength(1);
  });
});

describe("R2 custom domain (R2_PUBLIC_BASE_URL)", () => {
  beforeEach(() => vi.stubEnv("R2_PUBLIC_BASE_URL", "https://cdn.summary.test/"));
  afterEach(() => vi.unstubAllEnvs());

  it("redirects public OG images to the CDN and rotates the key when made private", async () => {
    const created = await createText("Solar panels on balconies are becoming popular across Germany.", { title: "Balcony solar" });
    const firstKey = [...env.store.objects.keys()].find((key) => key.startsWith("og/"))!;
    const firstArtKey = [...env.store.objects.keys()].find((key) => key.startsWith("art/"))!;
    expect(firstKey).toMatch(/^og\/[0-9a-f-]{36}-\d+-[0-9a-f]{12}\.png$/);
    expect(env.store.objects.get(firstKey)?.cacheControl).toBe("public, max-age=300");

    const og = await ogRoute.GET(apiRequest("GET", `/s/${created.slug}/og.png`), params({ slug: created.slug }));
    expect(og.status).toBe(302);
    expect(og.headers.get("location")).toBe(`https://cdn.summary.test/${firstKey}`);

    // Private: the object moves to a fresh key (old CDN URL dies), owner still gets it streamed.
    const context = params({ id: created.id });
    await summaryRoute.PATCH(apiRequest("PATCH", `/api/v1/summaries/${created.id}`, { token: env.tokens.alice, body: { visibility: "private" } }), context);
    const keys = [...env.store.objects.keys()].sort();
    expect(keys).toHaveLength(2);
    expect(keys).not.toContain(firstKey);
    expect(keys).not.toContain(firstArtKey);
    expect(keys[0]).toMatch(/^art\//);
    expect((await artRoute.GET(apiRequest("GET", `/s/${created.slug}/art.png`), params({ slug: created.slug }))).status).toBe(404);
    expect((await artRoute.GET(apiRequest("GET", `/s/${created.slug}/art.png`, { token: env.tokens.alice }), params({ slug: created.slug }))).status).toBe(200);
    expect((await ogRoute.GET(apiRequest("GET", `/s/${created.slug}/og.png`), params({ slug: created.slug }))).status).toBe(404);
    const ownerOg = await ogRoute.GET(apiRequest("GET", `/s/${created.slug}/og.png`, { token: env.tokens.alice }), params({ slug: created.slug }));
    expect(ownerOg.status).toBe(200);
    expect(ownerOg.headers.get("cache-control")).toBe("private, no-store");

    // Public again: redirects to the new key.
    await summaryRoute.PATCH(apiRequest("PATCH", `/api/v1/summaries/${created.id}`, { token: env.tokens.alice, body: { visibility: "public" } }), context);
    const again = await ogRoute.GET(apiRequest("GET", `/s/${created.slug}/og.png`), params({ slug: created.slug }));
    expect(again.headers.get("location")).toBe(`https://cdn.summary.test/${keys[1]}`);
  });
});

describe("get, patch, visibility, delete", () => {
  it("patches ttl/visibility/title/tags, hides private summaries publicly, and deletes", async () => {
    const created = await createText("Electric bicycles are replacing car trips in many dense European cities.", { title: "E-bikes" });
    const context = params({ id: created.id });

    const asBob = await summaryRoute.GET(apiRequest("GET", `/api/v1/summaries/${created.id}`, { token: env.tokens.bob }), context);
    expect(asBob.status).toBe(200);
    expect((await asBob.json()).isOwner).toBe(false);

    const bobPatch = await summaryRoute.PATCH(apiRequest("PATCH", `/api/v1/summaries/${created.id}`, { token: env.tokens.bob, body: { title: "hacked" } }), context);
    expect(bobPatch.status).toBe(403);

    const invalidTtl = await summaryRoute.PATCH(apiRequest("PATCH", `/api/v1/summaries/${created.id}`, { token: env.tokens.alice, body: { ttlDays: 2 } }), context);
    expect(invalidTtl.status).toBe(400);

    const patched = await (await summaryRoute.PATCH(apiRequest("PATCH", `/api/v1/summaries/${created.id}`, {
      token: env.tokens.alice,
      body: { ttlDays: 30, title: "Electric bikes", tags: ["Cycling", "cities"], visibility: "private" },
    }), context)).json();
    expect(patched).toMatchObject({ ttlDays: 30, title: "Electric bikes", tags: ["cycling", "cities"], visibility: "private" });
    expect(new Date(patched.expiresAt).getTime() - Date.now()).toBeGreaterThan(29 * 86_400_000);

    const never = await (await summaryRoute.PATCH(apiRequest("PATCH", `/api/v1/summaries/${created.id}`, { token: env.tokens.alice, body: { ttlDays: null } }), context)).json();
    expect(never).toMatchObject({ ttlDays: null, expiresAt: null });

    const tagged = await (await summariesRoute.GET(apiRequest("GET", "/api/v1/summaries?tag=cycling", { token: env.tokens.alice }))).json();
    expect(tagged.items).toHaveLength(1);
    const renamed = await (await summariesRoute.GET(apiRequest("GET", "/api/v1/summaries?q=electric%20bikes", { token: env.tokens.alice }))).json();
    expect(renamed.items).toHaveLength(1);

    // Private: public API, OG image and other users see 404; owner still sees it.
    expect((await publicRoute.GET(apiRequest("GET", `/api/public/summaries/${created.slug}`), params({ slug: created.slug }))).status).toBe(404);
    expect((await ogRoute.GET(apiRequest("GET", `/s/${created.slug}/og.png`), params({ slug: created.slug }))).status).toBe(404);
    expect((await summaryRoute.GET(apiRequest("GET", `/api/v1/summaries/${created.id}`, { token: env.tokens.bob }), context)).status).toBe(404);
    expect((await summaryRoute.GET(apiRequest("GET", `/api/v1/summaries/${created.id}`, { token: env.tokens.alice }), context)).status).toBe(200);
    const ownerOg = await ogRoute.GET(apiRequest("GET", `/s/${created.slug}/og.png`, { token: env.tokens.alice }), params({ slug: created.slug }));
    expect(ownerOg.status).toBe(200);
    expect(ownerOg.headers.get("cache-control")).toBe("private, no-store");
    const bobOg = await ogRoute.GET(apiRequest("GET", `/s/${created.slug}/og.png`, { token: env.tokens.bob }), params({ slug: created.slug }));
    expect(bobOg.status).toBe(404);

    // Back to public.
    await summaryRoute.PATCH(apiRequest("PATCH", `/api/v1/summaries/${created.id}`, { token: env.tokens.alice, body: { visibility: "public" } }), context);
    const publicResponse = await publicRoute.GET(apiRequest("GET", `/api/public/summaries/${created.slug}`, { headers: { "user-agent": "facebookexternalhit/1.1" } }), params({ slug: created.slug }));
    expect(publicResponse.status).toBe(200);
    expect(await publicResponse.json()).toMatchObject({ id: created.id, isOwner: false, visibility: "public" });
    const og = await ogRoute.GET(apiRequest("GET", `/s/${created.slug}/og.png`), params({ slug: created.slug }));
    expect(og.status).toBe(200);
    expect(og.headers.get("content-type")).toBe("image/png");
    expect(og.headers.get("cache-control")).toBe("public, max-age=300, s-maxage=300");

    // Regenerate the image: new keys, old keys deleted. (No image model, so the graphic fallback.)
    const beforeKeys = [...env.store.objects.keys()];
    const regenerated = await (await imageRoute.POST(apiRequest("POST", `/api/v1/summaries/${created.id}/image`, { token: env.tokens.alice, body: { imageStyle: "illustration" } }), context)).json();
    expect(regenerated.imageStyle).toBe("illustration");
    expect(regenerated.ogImageUrl).not.toBe(never.ogImageUrl);
    const afterKeys = [...env.store.objects.keys()];
    expect(afterKeys).toHaveLength(2);
    expect(afterKeys.filter((key) => beforeKeys.includes(key))).toEqual([]);

    const bobDelete = await summaryRoute.DELETE(apiRequest("DELETE", `/api/v1/summaries/${created.id}`, { token: env.tokens.bob }), context);
    expect(bobDelete.status).toBe(403);
    const deleted = await summaryRoute.DELETE(apiRequest("DELETE", `/api/v1/summaries/${created.id}`, { token: env.tokens.alice }), context);
    expect(deleted.status).toBe(204);
    expect(env.store.objects.size).toBe(0);
    expect((await summaryRoute.GET(apiRequest("GET", `/api/v1/summaries/${created.id}`, { token: env.tokens.alice }), context)).status).toBe(404);
    const search = await (await summariesRoute.GET(apiRequest("GET", "/api/v1/summaries?q=electric", { token: env.tokens.alice }))).json();
    expect(search.items).toEqual([]);
  });

  it("counts public API views from people but not from link-preview bots", async () => {
    const created = await createText("Tide pools host starfish, anemones and hermit crabs along rocky coastlines.", { title: "Tide pools" });
    await publicRoute.GET(apiRequest("GET", `/api/public/summaries/${created.slug}`, { headers: { "user-agent": "Slackbot-LinkExpanding 1.0" } }), params({ slug: created.slug }));
    await publicRoute.GET(apiRequest("GET", `/api/public/summaries/${created.slug}`, { headers: { "user-agent": "Mozilla/5.0 (iPhone) AppleWebKit Safari" } }), params({ slug: created.slug }));
    await new Promise((resolve) => setTimeout(resolve, 20));
    const fetched = await (await summaryRoute.GET(apiRequest("GET", `/api/v1/summaries/${created.id}`, { token: env.tokens.alice }), params({ id: created.id }))).json();
    expect(fetched.viewCount).toBe(1);
  });
});
