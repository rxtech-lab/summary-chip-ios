import { expect, test, type APIRequestContext } from "@playwright/test";
import { E2E_CLIENT_ID, ISSUER_URL } from "../../playwright.config";

async function accessToken(request: APIRequestContext, sub: string, clientId = E2E_CLIENT_ID): Promise<string> {
  const response = await request.post(`${ISSUER_URL}/token`, { data: { sub, clientId } });
  expect(response.ok()).toBe(true);
  return (await response.json()).access_token;
}

const auth = (token: string) => ({ authorization: `Bearer ${token}` });

/** Unique per test so parallel runs never share a user's library. */
const userId = (name: string) => `e2e-${name}-${crypto.randomUUID()}`;

const BODY = {
  title: "Monarch migration",
  summary: "Monarch butterflies fly thousands of kilometres south every autumn.",
  tags: ["Butterflies", "migration", "butterflies"],
  text: "Raw field notes: monarchs left the meadow on 2 October, heading south-west.",
};

test.describe("POST /api/v1/summaries/import", () => {
  test("requires an OAuth bearer token", async ({ request }) => {
    const response = await request.post("/api/v1/summaries/import", { data: BODY });
    expect(response.status()).toBe(401);
    expect((await response.json()).error.code).toBe("MISSING_ACCESS_TOKEN");
  });

  test("rejects tokens that fail verification", async ({ request }) => {
    const response = await request.post("/api/v1/summaries/import", { data: BODY, headers: auth("not.a.jwt") });
    expect(response.status()).toBe(401);
    expect((await response.json()).error.code).toBe("INVALID_ACCESS_TOKEN");
  });

  test("rejects tokens issued to an OAuth client that is not allowed", async ({ request }) => {
    const token = await accessToken(request, userId("stranger"), "some-other-client");
    const response = await request.post("/api/v1/summaries/import", { data: BODY, headers: auth(token) });
    expect(response.status()).toBe(403);
    expect((await response.json()).error.code).toBe("OAUTH_CLIENT_NOT_ALLOWED");
  });

  test("validates the body", async ({ request }) => {
    const token = await accessToken(request, userId("validator"));
    const missingText = await request.post("/api/v1/summaries/import", { data: { ...BODY, text: "  " }, headers: auth(token) });
    expect(missingText.status()).toBe(400);
    expect((await missingText.json()).error.code).toBe("VALIDATION_ERROR");
    const unknownField = await request.post("/api/v1/summaries/import", { data: { ...BODY, slug: "mine" }, headers: auth(token) });
    expect(unknownField.status()).toBe(400);
  });

  test("saves the summary, tags and raw text in one call", async ({ request }) => {
    const token = await accessToken(request, userId("alice"));
    const response = await request.post("/api/v1/summaries/import", {
      data: { ...BODY, highlights: ["They fly south"], category: "Science", sourceUrl: "https://github.com/rxtech-lab/chippy" },
      headers: auth(token),
    });
    expect(response.status()).toBe(201);
    const summary = await response.json();
    expect(summary).toMatchObject({
      title: BODY.title,
      summary: BODY.summary,
      highlights: ["They fly south"],
      category: "Science",
      tags: ["butterflies", "migration"],
      sourceType: "url",
      source: "github",
      sourceUrl: "https://github.com/rxtech-lab/chippy",
      visibility: "public",
      isOwner: true,
      hasSourceMarkdown: true,
      sourceMarkdownPending: false,
    });

    const fetched = await request.get(`/api/v1/summaries/${summary.id}`, { headers: auth(token) });
    expect(fetched.status()).toBe(200);
    expect((await fetched.json()).tags).toEqual(["butterflies", "migration"]);

    const markdown = await request.get(`/api/v1/summaries/${summary.id}/markdown`, { headers: auth(token) });
    expect(markdown.status()).toBe(200);
    expect((await markdown.json()).markdown).toBe(BODY.text);

    const byTag = await request.get("/api/v1/summaries?tag=butterflies", { headers: auth(token) });
    expect((await byTag.json()).items.map((item: { id: string }) => item.id)).toEqual([summary.id]);

    // The cover itself is checked in the integration tests: in mock mode each dev route bundle has
    // its own in-memory object store, so another route cannot serve it here.
    expect(summary.ogImageUrl).toMatch(new RegExp(`/s/${summary.slug}/og\\.png\\?v=\\d+$`));
  });

  test("keeps a private import from other users", async ({ request }) => {
    const owner = await accessToken(request, userId("owner"));
    const other = await accessToken(request, userId("other"));
    const summary = await (await request.post("/api/v1/summaries/import", {
      data: { ...BODY, visibility: "private" },
      headers: auth(owner),
    })).json();
    expect(summary.visibility).toBe("private");

    const asOther = await request.get(`/api/v1/summaries/${summary.id}`, { headers: auth(other) });
    expect(asOther.status()).toBe(404);
    const publicPage = await request.get(`/api/public/summaries/${summary.slug}`);
    expect(publicPage.status()).toBe(404);
  });
});
