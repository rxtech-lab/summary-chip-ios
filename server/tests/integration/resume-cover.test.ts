import { expect, it } from "vitest";
import { GET as resumeCover } from "@/app/api/v1/resumes/[id]/cover.png/route";
import { POST as createResume } from "@/app/api/v1/resumes/route";
import { GET as listSummaries } from "@/app/api/v1/summaries/route";
import { GET as shareCover } from "@/app/s/[slug]/og.png/route";
import { apiRequest, params, pngSize, setupTestEnv } from "../helpers/setup";

it("generates a private cover for a résumé listed in its owner's library", async () => {
  const env = await setupTestEnv();
  try {
    const created = await createResume(apiRequest("POST", "/api/v1/resumes", {
      token: env.tokens.alice,
      body: {
        title: "Design résumé",
        language: "en",
        idempotencyKey: "cover-test",
        document: { version: 1, candidateName: "Alice Example", links: [], sections: [] },
      },
    }));
    expect(created.status).toBe(201);
    const { familyId } = await created.json();

    const list = await listSummaries(apiRequest("GET", "/api/v1/summaries?scope=mine&kind=resume", {
      token: env.tokens.alice,
    }));
    expect(list.status).toBe(200);
    const { items } = await list.json();
    expect(items).toHaveLength(1);
    const [item] = items;
    expect(item).toMatchObject({ id: familyId, kind: "resume", visibility: "private" });
    const url = new URL(item.artImageUrl);
    expect(url.pathname).toBe(`/api/v1/resumes/${familyId}/cover.png`);
    expect(item.ogImageUrl).toBe(url.href);

    const path = url.pathname + url.search;
    const context = params({ id: familyId });
    const cover = await resumeCover(apiRequest("GET", path, { token: env.tokens.alice }), context);
    expect(cover.status).toBe(200);
    expect(cover.headers.get("content-type")).toBe("image/png");
    expect(cover.headers.get("cache-control")).toBe("private, no-store");
    expect(cover.headers.get("vary")).toBe("Authorization");
    expect(pngSize(new Uint8Array(await cover.arrayBuffer()))).toEqual({ width: 1200, height: 630 });

    expect((await resumeCover(apiRequest("GET", path), context)).status).toBe(401);
    expect((await resumeCover(apiRequest("GET", path, { token: env.tokens.bob }), context)).status).toBe(404);
    expect((await shareCover(apiRequest("GET", `/s/${item.slug}/og.png`), params({ slug: item.slug }))).status).toBe(404);
  } finally {
    env.teardown();
  }
});
