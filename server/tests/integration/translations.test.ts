import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as summariesRoute from "@/app/api/v1/summaries/route";
import * as importRoute from "@/app/api/v1/summaries/import/route";
import * as summaryRoute from "@/app/api/v1/summaries/[id]/route";
import * as markdownRoute from "@/app/api/v1/summaries/[id]/markdown/route";
import * as translationsRoute from "@/app/api/v1/summaries/[id]/translations/route";
import * as viewsRoute from "@/app/api/v1/views/route";
import * as publicRoute from "@/app/api/public/summaries/[slug]/route";
import * as ogRoute from "@/app/s/[slug]/og.png/route";
import { summaryTranslations } from "@/lib/db/schema";
import { preferredLanguage, translationLanguageFor } from "@/lib/services/translations";
import { apiRequest, params, pngSize, setupTestEnv, type TestEnv } from "../helpers/setup";

const ARTICLE = "Quantum widgets are tiny devices that entangle gears across the lab. Researchers say they could transform manufacturing within a decade.";

let env: TestEnv;

beforeEach(async () => {
  env = await setupTestEnv();
});

afterEach(() => {
  env.teardown();
});

async function createAsAlice() {
  const response = await summariesRoute.POST(apiRequest("POST", "/api/v1/summaries", {
    token: env.tokens.alice,
    body: { source: { type: "text", text: ARTICLE, title: "Quantum widgets" } },
  }));
  expect(response.status).toBe(201);
  const summary = await response.json();
  // The source document is written after the response.
  await vi.waitFor(async () => {
    const fresh = await getSummary(summary.id, env.tokens.alice);
    expect(fresh.hasSourceMarkdown).toBe(true);
  });
  return summary;
}

async function getSummary(id: string, token: string, language?: string) {
  const headers: Record<string, string> = language ? { "accept-language": language } : {};
  const response = await summaryRoute.GET(apiRequest("GET", `/api/v1/summaries/${id}`, { token, headers }), params({ id }));
  expect(response.status).toBe(200);
  return response.json();
}

async function patch(id: string, body: unknown, token = env.tokens.alice) {
  return summaryRoute.PATCH(apiRequest("PATCH", `/api/v1/summaries/${id}`, { token, body }), params({ id }));
}

describe("Accept-Language", () => {
  it("picks the most preferred supported language", () => {
    expect(preferredLanguage("ja-JP,ja;q=0.9,en;q=0.8")).toBe("ja");
    expect(preferredLanguage("it-IT, fr;q=0.5, en;q=0.7")).toBe("en");
    expect(preferredLanguage("zh-TW,zh;q=0.9")).toBe("zh-Hant");
    expect(preferredLanguage("zh-Hant-HK")).toBe("zh-Hant");
    expect(preferredLanguage("zh-CN")).toBe("zh-Hans");
    expect(preferredLanguage("de;q=0, *")).toBeNull();
    expect(preferredLanguage(null)).toBeNull();
    expect(translationLanguageFor("en-GB")).toBe("en");
  });
});

describe("summary translations", () => {
  it("shows a shared summary in the reader's language, with its source document", async () => {
    const created = await createAsAlice();
    const summary = await getSummary(created.id, env.tokens.bob, "ja-JP,ja;q=0.9");
    expect(summary).toMatchObject({
      language: "ja",
      originalLanguage: "en",
      displayLanguage: null,
      translationPending: false,
      title: `[ja] ${created.title}`,
      summary: `[ja] ${created.summary}`,
      highlights: created.highlights.map((highlight: string) => `[ja] ${highlight}`),
    });
    // Tags and keywords stay as written; they are filters.
    expect(summary.tags).toEqual(created.tags);

    await vi.waitFor(async () => {
      const response = await markdownRoute.GET(
        apiRequest("GET", `/api/v1/summaries/${created.id}/markdown`, { token: env.tokens.bob, headers: { "accept-language": "ja" } }),
        params({ id: created.id }),
      );
      const body = await response.json();
      expect(body).toMatchObject({ language: "ja", translationPending: false });
      expect(body.markdown).toMatch(/^\[ja\] # Quantum widgets/);
    });
    // Translated once per language, then served from the saved translation.
    await getSummary(created.id, env.tokens.bob, "ja");
    expect(env.ai.calls.translateSummary).toHaveLength(1);
    expect(env.ai.calls.translateDocument).toHaveLength(1);
  });

  it("keeps the original when the reader already reads its language or none is supported", async () => {
    const created = await createAsAlice();
    expect(await getSummary(created.id, env.tokens.bob, "en-US,en;q=0.9")).toMatchObject({ language: "en", title: created.title });
    expect(await getSummary(created.id, env.tokens.bob, "it-IT")).toMatchObject({ language: "en", title: created.title });
    expect(env.ai.calls.translateSummary).toHaveLength(0);
  });

  it("shows the owner the language they chose, not their Accept-Language, and remembers it", async () => {
    const created = await createAsAlice();
    expect(await getSummary(created.id, env.tokens.alice, "fr")).toMatchObject({ language: "en", title: created.title });

    const response = await patch(created.id, { displayLanguage: "de" });
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ language: "de", displayLanguage: "de", title: `[de] ${created.title}` });
    expect(await getSummary(created.id, env.tokens.alice, "fr")).toMatchObject({ language: "de", displayLanguage: "de" });

    // A title edit while reading a translation edits that translation.
    const renamed = await (await patch(created.id, { title: "Quanten-Widgets" })).json();
    expect(renamed.title).toBe("Quanten-Widgets");
    expect((await patch(created.id, { displayLanguage: null }).then((r) => r.json()))).toMatchObject({ language: "en", displayLanguage: null, title: created.title });
  });

  it("stores reading in the original language as null", async () => {
    const created = await createAsAlice();
    const body = await (await patch(created.id, { displayLanguage: "en" })).json();
    expect(body).toMatchObject({ language: "en", displayLanguage: null });
  });

  it("refuses a language it could not translate into without storing it", async () => {
    const created = await createAsAlice();
    env.ai.translates = false;
    const response = await patch(created.id, { displayLanguage: "ko" });
    expect(response.status).toBe(502);
    expect((await response.json()).error.code).toBe("TRANSLATION_FAILED");
    expect(await getSummary(created.id, env.tokens.alice)).toMatchObject({ displayLanguage: null, language: "en" });
    // A reader still gets the original when translation fails.
    expect(await getSummary(created.id, env.tokens.bob, "ko")).toMatchObject({ language: "en", title: created.title });
  });

  it("lists translations already written and translates the rest after the response", async () => {
    const created = await createAsAlice();
    await viewsRoute.POST(apiRequest("POST", "/api/v1/views", { token: env.tokens.bob, body: { slug: created.slug } }));
    await env.handle.db.delete(summaryTranslations);
    const list = async () => {
      const response = await summariesRoute.GET(apiRequest("GET", "/api/v1/summaries", { token: env.tokens.bob, headers: { "accept-language": "es" } }));
      return (await response.json()).items[0];
    };
    expect(await list()).toMatchObject({ language: "en", translationPending: true, title: created.title });
    await vi.waitFor(async () => {
      expect(await list()).toMatchObject({ language: "es", translationPending: false, title: `[es] ${created.title}` });
    });
  });

  it("translates the public API (App Clip) by Accept-Language", async () => {
    const created = await createAsAlice();
    const response = await publicRoute.GET(
      apiRequest("GET", `/api/public/summaries/${created.slug}`, { headers: { "accept-language": "zh-TW" } }),
      params({ slug: created.slug }),
    );
    expect(response.headers.get("vary")).toBe("Accept-Language");
    expect(await response.json()).toMatchObject({ language: "zh-Hant", title: `[zh-Hant] ${created.title}`, displayLanguage: null });
  });
});

describe("summary language detection", () => {
  async function importChip(body: Record<string, unknown>) {
    const response = await importRoute.POST(apiRequest("POST", "/api/v1/summaries/import", {
      token: env.tokens.alice,
      body: { text: "Raw source text for the chip.", ...body },
    }));
    expect(response.status).toBe(201);
    return response.json();
  }

  it("stores the language the evaluation model reads an imported summary in", async () => {
    // Declared "en" (the default), but written in Japanese.
    const chip = await importChip({ title: "量子ウィジェットの解説", summary: "量子ウィジェットは研究室の歯車をつなぐ小さな装置です。" });
    expect(chip).toMatchObject({ language: "ja", originalLanguage: "ja" });
    expect(env.ai.calls.detectLanguage).toHaveLength(1);
    expect(env.ai.calls.designCover[0].language).toBe("ja");
    // Read in its own language, so a Japanese reader gets no translation.
    expect(await getSummary(chip.id, env.tokens.bob, "ja")).toMatchObject({ language: "ja", title: chip.title });
    expect(env.ai.calls.translateSummary).toHaveLength(0);
  });

  it("keeps the declared language when the model detects none of the supported ones", async () => {
    const chip = await importChip({ title: "Widget quantistici", summary: "Piccoli dispositivi da laboratorio.", language: "it" });
    expect(chip.language).toBe("it");
  });

  it("detects the language of a summary written in the source's language, but not of a requested one", async () => {
    await createAsAlice();
    expect(env.ai.calls.detectLanguage).toHaveLength(1);
    const response = await summariesRoute.POST(apiRequest("POST", "/api/v1/summaries", {
      token: env.tokens.alice,
      body: { source: { type: "text", text: ARTICLE }, language: "fr" },
    }));
    expect((await response.json()).language).toBe("fr");
    expect(env.ai.calls.detectLanguage).toHaveLength(1);
  });
});

describe("GET /api/v1/summaries/:id/translations", () => {
  async function translations(id: string, token = env.tokens.alice) {
    return translationsRoute.GET(apiRequest("GET", `/api/v1/summaries/${id}/translations`, { token }), params({ id }));
  }

  it("lists the languages a summary is already translated into, without translating anything", async () => {
    const created = await createAsAlice();
    expect(await (await translations(created.id)).json()).toEqual({ originalLanguage: "en", items: [] });

    expect((await patch(created.id, { displayLanguage: "ja" })).status).toBe(200);
    await getSummary(created.id, env.tokens.bob, "de");
    await vi.waitFor(async () => {
      const body = await (await translations(created.id)).json();
      expect(body.items).toEqual([
        { language: "ja", sourceTranslated: true, sourcePending: false },
        { language: "de", sourceTranslated: true, sourcePending: false },
      ]);
    });
    expect(env.ai.calls.translateSummary).toHaveLength(2);
  });

  it("is only for people who may open the summary", async () => {
    const created = await createAsAlice();
    await patch(created.id, { visibility: "private" });
    expect((await translations(created.id, env.tokens.bob)).status).toBe(404);
  });

  it("draws the cover with the translated headline, once, and retires it with the summary", async () => {
    const created = await createAsAlice();
    const original = [...env.store.objects.keys()].find((key) => key.startsWith("og/"))!;
    const translated = await (await patch(created.id, { displayLanguage: "ja" })).json();
    expect(env.ai.calls.translateSummary.at(-1)?.headline).toBeTruthy();
    const url = new URL(translated.ogImageUrl);
    expect(url.pathname).toBe(`/s/${created.slug}/og.png`);
    expect(url.searchParams.get("lang")).toBe("ja");

    const cover = () => ogRoute.GET(apiRequest("GET", `${url.pathname}${url.search}`, { token: env.tokens.alice }), params({ slug: created.slug }));
    const first = await cover();
    expect(first.status).toBe(200);
    expect(pngSize(new Uint8Array(await first.arrayBuffer()))).toEqual({ width: 1200, height: 630 });
    const [row] = await env.handle.db.select().from(summaryTranslations);
    expect(row.headline).toMatch(/^\[ja\] /);
    expect(row.ogImageKey).toMatch(new RegExp(`^og/${created.id}-ja-[0-9a-f]{24}\\.png$`));
    expect(env.store.objects.has(row.ogImageKey!)).toBe(true);
    expect(row.ogImageKey).not.toBe(original);

    // Drawn once: the second request serves the stored cover.
    const objects = env.store.objects.size;
    expect((await cover()).status).toBe(200);
    expect(env.store.objects.size).toBe(objects);

    // Without a translation in that language, the original cover.
    const french = await ogRoute.GET(apiRequest("GET", `/s/${created.slug}/og.png?lang=fr`, { token: env.tokens.alice }), params({ slug: created.slug }));
    expect(Buffer.from(await french.arrayBuffer()).equals(Buffer.from(env.store.objects.get(original)!.bytes))).toBe(true);

    await summaryRoute.DELETE(apiRequest("DELETE", `/api/v1/summaries/${created.id}`, { token: env.tokens.alice }), params({ id: created.id }));
    expect(env.store.objects.has(row.ogImageKey!)).toBe(false);
  });
});
