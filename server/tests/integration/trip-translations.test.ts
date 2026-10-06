import { eq } from "drizzle-orm";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as summaryRoute from "@/app/api/v1/summaries/[id]/route";
import * as tripsRoute from "@/app/api/v1/trips/route";
import * as tripRoute from "@/app/api/v1/trips/[id]/route";
import * as operationsRoute from "@/app/api/v1/trips/[id]/operations/route";
import * as pdfRoute from "@/app/api/v1/trips/[id]/pdf/route";
import * as translationsRoute from "@/app/api/v1/trips/[id]/translations/route";
import type { TripDocument } from "@/lib/contracts/trip";
import { summaries, tripTranslations } from "@/lib/db/schema";
import { mapTripTexts, tripTexts } from "@/lib/services/trip-translations";
import type { TripJson } from "@/lib/services/trips";
import { apiRequest, params, setupTestEnv, type TestEnv } from "../helpers/setup";

let env: TestEnv;

beforeEach(async () => {
  env = await setupTestEnv();
  vi.stubEnv("SUMMARY_OG_REMOTE_ASSETS", "false");
});

afterEach(() => {
  env.teardown();
  vi.unstubAllEnvs();
});

const document: Partial<TripDocument> = {
  title: "Lisbon long weekend",
  startDate: "2026-11-06",
  endDate: "2026-11-09",
  timeZone: "Europe/Lisbon",
  currency: "EUR",
  places: [{ id: "lisbon", name: "Lisbon", kind: "city", coordinate: { lat: 38.7223, lng: -9.1393 }, major: true, address: "Praça do Comércio", note: null, photos: [], pricing: [] }],
  days: [{
    id: "day-1",
    date: "2026-11-06",
    title: "Alfama at dusk",
    highlight: false,
    moments: [{ slot: "evening", time: "19:30", text: "Fado in a tiny tavern", placeId: "lisbon" }],
    transportIds: [],
    route: null,
    stayId: null,
  }],
  expenses: [{ id: "fado", category: "activity", title: "Fado dinner", amount: { amount: 45, currency: "EUR" }, paid: false }],
};

async function create(visibility: "public" | "private" = "private"): Promise<TripJson> {
  const response = await tripsRoute.POST(apiRequest("POST", "/api/v1/trips", { token: env.tokens.alice, body: { document, visibility } }));
  expect(response.status).toBe(201);
  return (await response.json()).trip;
}

async function get(id: string, token = env.tokens.alice, language?: string): Promise<TripJson> {
  const headers: Record<string, string> = language ? { "accept-language": language } : {};
  const response = await tripRoute.GET(apiRequest("GET", `/api/v1/trips/${id}`, { token, headers }), params({ id }));
  expect(response.status).toBe(200);
  return (await response.json()).trip;
}

function setLanguage(id: string, displayLanguage: string | null) {
  return summaryRoute.PATCH(apiRequest("PATCH", `/api/v1/summaries/${id}`, { token: env.tokens.alice, body: { displayLanguage } }), params({ id }));
}

describe("trip texts", () => {
  it("translates what readers read and leaves ids, codes and addresses alone", () => {
    const full = { ...document, transports: [], hotels: [], notes: [], sources: [], views: [] } as unknown as TripDocument;
    expect(tripTexts(full)).toEqual(["Lisbon long weekend", "Lisbon", "Alfama at dusk", "Fado in a tiny tavern", "Fado dinner"]);
    const translated = mapTripTexts(full, (text) => text.toUpperCase());
    expect(translated.places[0]).toMatchObject({ id: "lisbon", name: "LISBON", address: "Praça do Comércio" });
    expect(translated.days[0].moments[0]).toMatchObject({ time: "19:30", text: "FADO IN A TINY TAVERN", placeId: "lisbon" });
    expect(translated.expenses[0].amount).toEqual({ amount: 45, currency: "EUR" });
  });
});

describe("trip translations", () => {
  it("opens the owner's trip in the language they chose, and only translates edits after that", async () => {
    const trip = await create();
    expect(trip).toMatchObject({ language: "en", originalLanguage: "en", displayLanguage: null });

    const response = await setLanguage(trip.id, "ja");
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({ language: "ja", displayLanguage: "ja", title: "[ja] Lisbon long weekend" });

    const translated = await get(trip.id);
    expect(translated).toMatchObject({ language: "ja", originalLanguage: "en", displayLanguage: "ja", revision: 0 });
    expect(translated.document).toMatchObject({
      title: "[ja] Lisbon long weekend",
      currency: "EUR",
      places: [{ id: "lisbon", name: "[ja] Lisbon", address: "Praça do Comércio" }],
      days: [{ id: "day-1", title: "[ja] Alfama at dusk", moments: [{ text: "[ja] Fado in a tiny tavern" }] }],
    });
    // Translated once when the language was chosen; reading it again is free.
    expect(env.ai.calls.translateStrings).toHaveLength(1);

    // Editing the original: only the new text is translated on the next read.
    const edited = await operationsRoute.POST(apiRequest("POST", `/api/v1/trips/${trip.id}/operations`, {
      token: env.tokens.alice,
      body: { operations: [{ op: "upsert_note", note: { id: "tip", title: "Trams", text: "Ride the 28 early" } }] },
    }), params({ id: trip.id }));
    expect(edited.status).toBe(200);
    // Saves answer with the document as written: the app edits the original.
    expect((await edited.json()).trip).toMatchObject({ language: "en", document: { title: "Lisbon long weekend" } });

    const again = await get(trip.id);
    expect(again.document.notes).toEqual([{ id: "tip", title: "[ja] Trams", text: "[ja] Ride the 28 early" }]);
    expect(env.ai.calls.translateStrings.at(-1)?.texts).toEqual(["Trams", "Ride the 28 early"]);

    const listed = await (await translationsRoute.GET(apiRequest("GET", `/api/v1/trips/${trip.id}/translations`, { token: env.tokens.alice }), params({ id: trip.id }))).json();
    expect(listed).toEqual({ originalLanguage: "en", items: [{ language: "ja", upToDate: true, translating: false }] });

    // Back to the original.
    expect((await setLanguage(trip.id, null)).status).toBe(200);
    expect(await get(trip.id)).toMatchObject({ language: "en", displayLanguage: null, document: { title: "Lisbon long weekend" } });
  });

  it("shows a shared trip in the reader's language; the owner reads it as written", async () => {
    const trip = await create("public");
    const shared = await get(trip.id, env.tokens.bob, "fr-FR,fr;q=0.9");
    expect(shared).toMatchObject({ language: "fr", originalLanguage: "en", displayLanguage: null, isOwner: false, document: { title: "[fr] Lisbon long weekend" } });
    expect(await get(trip.id, env.tokens.alice, "fr-FR")).toMatchObject({ language: "en", document: { title: "Lisbon long weekend" } });
  });

  it("translates a large trip in the background and shows it as written until then", async () => {
    const trip = await create();
    const notes = Array.from({ length: 80 }, (_, index) => ({ id: `note-${index}`, title: `Tip ${index}`, text: `Walk to viewpoint ${index}` }));
    const added = await operationsRoute.POST(apiRequest("POST", `/api/v1/trips/${trip.id}/operations`, {
      token: env.tokens.alice,
      body: { operations: notes.map((note) => ({ op: "upsert_note", note })) },
    }), params({ id: trip.id }));
    expect(added.status).toBe(200);

    expect((await setLanguage(trip.id, "ja")).status).toBe(200);
    expect(env.tripTranslations).toEqual([{ summaryId: trip.id, language: "ja", userId: "user-alice" }]);
    expect(env.ai.calls.translateStrings).toHaveLength(0);

    // While it runs, the trip reads as written, without translating inline or starting another run.
    expect(await get(trip.id)).toMatchObject({ language: "en", displayLanguage: "ja", translating: true, document: { title: "Lisbon long weekend" } });
    expect(env.tripTranslations).toHaveLength(1);
    const listing = async () => (await (await translationsRoute.GET(apiRequest("GET", `/api/v1/trips/${trip.id}/translations`, { token: env.tokens.alice }), params({ id: trip.id }))).json()).items;
    expect(await listing()).toEqual([{ language: "ja", upToDate: false, translating: true }]);

    await env.runTripTranslations();
    const translated = await get(trip.id);
    expect(translated).toMatchObject({ language: "ja", translating: false, document: { title: "[ja] Lisbon long weekend" } });
    expect(translated.document.notes[79]).toMatchObject({ title: "[ja] Tip 79", text: "[ja] Walk to viewpoint 79" });
    expect(await listing()).toEqual([{ language: "ja", upToDate: true, translating: false }]);
  });

  it("unmarks a background translation that failed, so the next read can start another", async () => {
    const trip = await create();
    const notes = Array.from({ length: 80 }, (_, index) => ({ id: `note-${index}`, title: `Tip ${index}`, text: `Ferry ${index}` }));
    await operationsRoute.POST(apiRequest("POST", `/api/v1/trips/${trip.id}/operations`, {
      token: env.tokens.alice,
      body: { operations: notes.map((note) => ({ op: "upsert_note", note })) },
    }), params({ id: trip.id }));
    expect((await setLanguage(trip.id, "de")).status).toBe(200);
    env.ai.translates = false;
    await env.runTripTranslations();
    // Nothing was translated: it isn't listed as a translation.
    const listed = await (await translationsRoute.GET(apiRequest("GET", `/api/v1/trips/${trip.id}/translations`, { token: env.tokens.alice }), params({ id: trip.id }))).json();
    expect(listed.items).toEqual([]);
    // The trip reads as written, and opening it starts another run.
    expect(await get(trip.id)).toMatchObject({ language: "en", translating: true });
    expect(env.tripTranslations).toHaveLength(1);
  });

  it("lists a translation as outdated after the trip changed, and updates only what changed when chosen again", async () => {
    const trip = await create();
    expect((await setLanguage(trip.id, "ja")).status).toBe(200);
    expect((await setLanguage(trip.id, null)).status).toBe(200);
    await operationsRoute.POST(apiRequest("POST", `/api/v1/trips/${trip.id}/operations`, {
      token: env.tokens.alice,
      body: { operations: [{ op: "upsert_note", note: { id: "tip", title: "Trams", text: "Ride the 28 early" } }] },
    }), params({ id: trip.id }));
    const listing = async () => (await (await translationsRoute.GET(apiRequest("GET", `/api/v1/trips/${trip.id}/translations`, { token: env.tokens.alice }), params({ id: trip.id }))).json()).items;
    expect(await listing()).toEqual([{ language: "ja", upToDate: false, translating: false }]);

    expect((await setLanguage(trip.id, "ja")).status).toBe(200);
    expect(env.ai.calls.translateStrings.at(-1)?.texts).toEqual(["Trams", "Ride the 28 early"]);
    expect(await listing()).toEqual([{ language: "ja", upToDate: true, translating: false }]);
  });

  it("exports the PDF in the language the trip is read in, from the saved translation", async () => {
    vi.stubEnv("CLOUDFLARE_ACCOUNT_ID", "acct-123");
    vi.stubEnv("CLOUDFLARE_API_TOKEN", "cf-token");
    const fetchMock = vi.fn(async () => new Response(new TextEncoder().encode("%PDF-1.7 fake"), { headers: { "content-type": "application/pdf" } }));
    vi.stubGlobal("fetch", fetchMock);
    const printed = async (id: string, token: string, lang: string) => {
      const response = await pdfRoute.GET(apiRequest("GET", `/api/v1/trips/${id}/pdf?lang=${lang}`, { token }), params({ id }));
      expect(response.status).toBe(200);
      return JSON.parse(String((fetchMock.mock.calls.at(-1) as unknown as [string, RequestInit])[1].body)).html as string;
    };
    const trip = await create("public");

    // Translated content; labels in the app's language when the report has none in Japanese.
    expect((await setLanguage(trip.id, "ja")).status).toBe(200);
    const japanese = await printed(trip.id, env.tokens.alice, "zh-Hant");
    expect(japanese).toContain("[ja] Alfama at dusk");
    expect(japanese).toContain("第 1 天");
    // Labels follow the translation when the report speaks it.
    expect((await setLanguage(trip.id, "zh-Hans")).status).toBe(200);
    const chinese = await printed(trip.id, env.tokens.alice, "en");
    expect(chinese).toContain("[zh-Hans] Alfama at dusk");
    expect(chinese).toContain("第 1 天");
    // Someone else reads it in their language only once it's translated: the export translates nothing.
    const callsBefore = env.ai.calls.translateStrings.length;
    expect(await printed(trip.id, env.tokens.bob, "fr")).toContain(">Alfama at dusk");
    expect(env.ai.calls.translateStrings.length).toBe(callsBefore);
    vi.unstubAllGlobals();
  });

  it("refuses a language the trip could not be translated into, without storing it", async () => {
    const trip = await create();
    env.ai.translates = false;
    const response = await setLanguage(trip.id, "de");
    expect(response.status).toBe(502);
    const [row] = await env.handle.db.select().from(summaries).where(eq(summaries.id, trip.id));
    expect(row.displayLanguage).toBeNull();
    expect(await env.handle.db.select().from(tripTranslations)).toEqual([]);
  });
});
