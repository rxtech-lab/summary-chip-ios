import { eq } from "drizzle-orm";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as summariesRoute from "@/app/api/v1/summaries/route";
import * as summaryRoute from "@/app/api/v1/summaries/[id]/route";
import * as linksRoute from "@/app/api/v1/summaries/[id]/links/route";
import * as linkRoute from "@/app/api/v1/summaries/[id]/links/[linkId]/route";
import * as viewsRoute from "@/app/api/v1/views/route";
import * as publicRoute from "@/app/api/public/summaries/[slug]/route";
import * as ogRoute from "@/app/s/[slug]/og.png/route";
import { shareLinks } from "@/lib/db/schema";
import { apiRequest, params, setupTestEnv, signToken, type TestEnv } from "../helpers/setup";

let env: TestEnv;

beforeEach(async () => {
  env = await setupTestEnv();
});

afterEach(() => {
  vi.unstubAllEnvs();
  env.teardown();
});

async function createText(text: string, title: string, extra: Record<string, unknown> = {}) {
  const response = await summariesRoute.POST(apiRequest("POST", "/api/v1/summaries", { token: env.tokens.alice, body: { source: { type: "text", text, title }, ...extra } }));
  expect(response.status).toBe(201);
  return response.json();
}

function createLink(id: string, body: Record<string, unknown>, token = env.tokens.alice) {
  return linksRoute.POST(apiRequest("POST", `/api/v1/summaries/${id}/links`, { token, body }), params({ id }));
}

function patchLink(id: string, linkId: string, body: Record<string, unknown>, token = env.tokens.alice) {
  return linkRoute.PATCH(apiRequest("PATCH", `/api/v1/summaries/${id}/links/${linkId}`, { token, body }), params({ id, linkId }));
}

function listLinks(id: string, token = env.tokens.alice) {
  return linksRoute.GET(apiRequest("GET", `/api/v1/summaries/${id}/links`, { token }), params({ id }));
}

const tokenOf = (url: string) => url.split("/s/")[1]!;
const view = (key: string, token: string) => viewsRoute.POST(apiRequest("POST", "/api/v1/views", { token, body: { slug: key } }));
const openPublic = (key: string) => publicRoute.GET(apiRequest("GET", `/api/public/summaries/${key}`), params({ slug: key }));
const getSummary = (id: string, token: string) => summaryRoute.GET(apiRequest("GET", `/api/v1/summaries/${id}`, { token }), params({ id }));
const viewedIds = async (token: string) => {
  const page = await (await summariesRoute.GET(apiRequest("GET", "/api/v1/summaries?scope=viewed", { token }))).json();
  return page.items.map((item: { id: string }) => item.id);
};

describe("share links", () => {
  it("creates several links with their own lifetimes, lists and deletes them one by one", async () => {
    const summary = await createText("Honeybees communicate the location of flowers through a waggle dance in the hive.", "Bee dance");
    const week = await createLink(summary.id, { label: "Team", ttlDays: 7 });
    expect(week.status).toBe(201);
    const weekLink = await week.json();
    expect(weekLink).toMatchObject({ label: "Team", access: "anyone", ttlDays: 7, isExpired: false, emails: [] });
    expect(new Date(weekLink.expiresAt).getTime()).toBeGreaterThan(Date.now() + 6 * 86_400_000);
    const forever = await (await createLink(summary.id, { ttlDays: null })).json();
    expect(forever).toMatchObject({ label: null, ttlDays: null, expiresAt: null });
    expect(tokenOf(forever.url)).not.toBe(tokenOf(weekLink.url));
    expect(tokenOf(forever.url)).not.toBe(summary.slug);

    const listed = await (await listLinks(summary.id)).json();
    expect(listed.items.map((link: { id: string }) => link.id)).toEqual([weekLink.id, forever.id]);

    // Only the owner manages links.
    expect((await listLinks(summary.id, env.tokens.bob)).status).toBe(403);
    expect((await createLink(summary.id, {}, env.tokens.bob)).status).toBe(403);

    const deleted = await linkRoute.DELETE(apiRequest("DELETE", `/api/v1/summaries/${summary.id}/links/${weekLink.id}`, { token: env.tokens.alice }), params({ id: summary.id, linkId: weekLink.id }));
    expect(deleted.status).toBe(204);
    expect((await openPublic(tokenOf(weekLink.url))).status).toBe(404);
    expect((await openPublic(tokenOf(forever.url))).status).toBe(200);
    const after = await (await listLinks(summary.id)).json();
    expect(after.items.map((link: { id: string }) => link.id)).toEqual([forever.id]);
  });

  it("opens a private summary through an open link, until the link expires", async () => {
    const summary = await createText("Tardigrades survive extreme cold, radiation and even the vacuum of space.", "Tardigrades", { visibility: "private" });
    const link = await (await createLink(summary.id, { ttlDays: 1 })).json();
    const key = tokenOf(link.url);

    expect((await openPublic(summary.slug)).status).toBe(404);
    const opened = await openPublic(key);
    expect(opened.status).toBe(200);
    const json = await opened.json();
    expect(json).toMatchObject({ id: summary.id, isExpired: false, shareUrl: link.url });
    expect(json.summary).not.toBe("");
    expect(json.ogImageUrl).toContain(`/s/${key}/og.png`);
    const image = await ogRoute.GET(apiRequest("GET", `/s/${key}/og.png`), params({ slug: key }));
    expect(image.status).toBe(200);
    expect(image.headers.get("cache-control")).toBe("private, no-store");

    // A signed-in viewer keeps it in their library through the link.
    expect((await view(key, env.tokens.bob)).status).toBe(200);
    expect(await viewedIds(env.tokens.bob)).toEqual([summary.id]);
    expect((await getSummary(summary.id, env.tokens.bob)).status).toBe(200);

    await env.handle.db.update(shareLinks).set({ expiresAt: new Date(Date.now() - 1000) }).where(eq(shareLinks.id, link.id));
    expect((await openPublic(key)).status).toBe(404);
    expect((await getSummary(summary.id, env.tokens.bob)).status).toBe(404);
    expect(await viewedIds(env.tokens.bob)).toEqual([]);
    const listed = await (await listLinks(summary.id)).json();
    expect(listed.items[0]).toMatchObject({ isExpired: true });

    // Extending the lifetime reopens it.
    const extended = await (await patchLink(summary.id, link.id, { ttlDays: 30 })).json();
    expect(extended).toMatchObject({ ttlDays: 30, isExpired: false });
    expect((await getSummary(summary.id, env.tokens.bob)).status).toBe(200);
  });

  it("lets only invited emails open an invited link, and revoking an address ends access", async () => {
    const summary = await createText("Octopuses have three hearts and blue blood that carries oxygen with copper.", "Octopus", { visibility: "private" });
    expect((await createLink(summary.id, { access: "invited" })).status).toBe(400);
    const link = await (await createLink(summary.id, { access: "invited", emails: ["Bob@Example.com", "carol@example.com", "bob@example.com"] })).json();
    expect(link.emails.map((entry: { email: string }) => entry.email)).toEqual(["bob@example.com", "carol@example.com"]);
    const key = tokenOf(link.url);

    // Signed out: has to sign in. Signed in with another email: not invited.
    const anonymous = await openPublic(key);
    expect(anonymous.status).toBe(403);
    expect((await anonymous.json()).error.code).toBe("SIGN_IN_REQUIRED");
    // Its cover still loads signed out, so link previews show the card.
    const cover = await ogRoute.GET(apiRequest("GET", `/s/${key}/og.png`), params({ slug: key }));
    expect(cover.status).toBe(200);
    expect(cover.headers.get("cache-control")).toBe("private, no-store");
    const dave = await signToken("user-dave", { email: "dave@example.com" });
    const notInvited = await view(key, dave);
    expect(notInvited.status).toBe(403);
    expect((await notInvited.json()).error.code).toBe("NOT_INVITED");
    // Bob's token has no email claim yet; his account's email is unknown.
    expect((await view(key, env.tokens.bob)).status).toBe(403);

    const bob = await signToken("user-bob", { email: "BOB@example.com" });
    const opened = await view(key, bob);
    expect(opened.status).toBe(200);
    expect(await opened.json()).toMatchObject({ id: summary.id, isExpired: false, shareUrl: link.url });
    expect((await getSummary(summary.id, bob)).status).toBe(200);
    expect(await viewedIds(bob)).toEqual([summary.id]);

    // The owner always opens their own link.
    expect((await view(key, env.tokens.alice)).status).toBe(200);

    // Removing the last address of an invited link is refused; revoking Bob's keeps Carol's.
    expect((await patchLink(summary.id, link.id, { emails: [] })).status).toBe(400);
    const revoked = await (await patchLink(summary.id, link.id, { emails: ["carol@example.com"] })).json();
    expect(revoked.emails.map((entry: { email: string }) => entry.email)).toEqual(["carol@example.com"]);
    expect((await getSummary(summary.id, bob)).status).toBe(404);
    expect(await viewedIds(bob)).toEqual([]);
    expect((await view(key, bob)).status).toBe(403);

    // Opening the link to anyone lets Bob back in; deleting it ends everyone's access.
    expect((await (await patchLink(summary.id, link.id, { access: "anyone" })).json()).access).toBe("anyone");
    expect((await view(key, bob)).status).toBe(200);
    await linkRoute.DELETE(apiRequest("DELETE", `/api/v1/summaries/${summary.id}/links/${link.id}`, { token: env.tokens.alice }), params({ id: summary.id, linkId: link.id }));
    expect((await getSummary(summary.id, bob)).status).toBe(404);
  });

  it("keeps the summary's own link and its share links independent", async () => {
    const summary = await createText("Mangrove forests protect coastlines from storms and store large amounts of carbon.", "Mangroves");
    const link = await (await createLink(summary.id, {})).json();
    // Going private closes the summary's own link, not the share link.
    await summaryRoute.PATCH(apiRequest("PATCH", `/api/v1/summaries/${summary.id}`, { token: env.tokens.alice, body: { visibility: "private" } }), params({ id: summary.id }));
    expect((await openPublic(summary.slug)).status).toBe(404);
    expect((await openPublic(tokenOf(link.url))).status).toBe(200);
  });
});
