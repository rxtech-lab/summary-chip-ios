import { createHash } from "node:crypto";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { tourVoice } from "@/lib/ai/models";
import * as tripsRoute from "@/app/api/v1/trips/route";
import * as tourRoute from "@/app/api/v1/trips/[id]/tour/route";
import * as audioRoute from "@/app/api/v1/trips/[id]/tour/[key]/scenes/[index]/audio/route";
import type { TripTour } from "@/lib/contracts/tour";
import { tripDocumentSchema } from "@/lib/contracts/trip";
import { tourSkeleton } from "@/lib/services/trip-tour";
import type { TripJson } from "@/lib/services/trips";
import { apiRequest, params, setupTestEnv, type TestEnv } from "../helpers/setup";

let env: TestEnv;

beforeEach(async () => {
  env = await setupTestEnv();
});
afterEach(() => { env.teardown(); vi.restoreAllMocks(); });

const tripDocument = {
  title: "Kansai", startDate: "2030-04-01", endDate: "2030-04-03", timeZone: "Asia/Tokyo", currency: "JPY",
  places: [
    { id: "kix", name: "Kansai Airport", kind: "airport", coordinate: { lat: 34.4347, lng: 135.244 } },
    { id: "kyoto", name: "Kyoto", kind: "city", major: true, coordinate: { lat: 35.0116, lng: 135.7681 }, description: "An old imperial capital with craft traditions and seasonal Kyoto cooking." },
    { id: "fushimi", name: "Fushimi Inari", kind: "poi", coordinate: { lat: 34.9671, lng: 135.7727 }, description: "A shrine to Inari with paths of vermilion torii and fox guardians.", note: "Look for the fox statues; try inari sushi nearby.", hours: "Always open", pricing: [{ label: "Entry" }] },
    { id: "nara", name: "Nara", kind: "city", coordinate: { lat: 34.6851, lng: 135.8048 } },
    { id: "ryokan-place", name: "Gion", kind: "hotel", coordinate: { lat: 35.0037, lng: 135.7788 } },
  ],
  days: [
    { id: "d1", date: "2030-04-01", title: "Arrive", route: { kind: "airport", placeIds: ["kix", "kyoto"] }, transportIds: ["haruka"], stayId: "ryokan" },
    { id: "d2", date: "2030-04-02", title: "Shrines", blurb: "Follow the connection between rice, prosperity and Inari worship.", route: { kind: "side", placeIds: ["kyoto", "fushimi", "kyoto"] }, moments: [{ slot: "morning", time: "09:30", text: "Explore the torii paths and taste inari sushi", placeId: "fushimi" }], stayId: "ryokan" },
    { id: "d3", date: "2030-04-03", title: "Nara", moments: [{ slot: "morning", text: "Deer park", placeId: "nara" }] },
  ],
  transports: [{
    id: "haruka", date: "2030-04-01", label: "KIX → Kyoto", status: "booked",
    options: [{ id: "h36", label: "Haruka 36", departure: "2030-04-01T09:00", arrival: "2030-04-01T10:20", duration: "80 minutes", fare: { amount: 3640, currency: "JPY" }, segments: [{
      mode: "train", fromPlaceId: "kix", toPlaceId: "kyoto", fromName: "Kansai Airport", toName: "Kyoto",
      train: { name: "Haruka", number: "36", category: "limited_express", seat: "7A" },
    }] }],
  }],
  hotels: [{ id: "ryokan", name: "Ryokan Yachiyo", placeId: "ryokan-place", checkIn: "2030-04-01", checkOut: "2030-04-03", checkInTime: "15:00", confirmation: "ABC123", status: "booked", price: { amount: 60000, currency: "JPY" } }],
  expenses: [{ id: "fare", category: "transport", title: "Haruka", amount: { amount: 3640, currency: "JPY" }, linkedId: "haruka", dayId: "d1" }],
};

async function createTrip(document: unknown = tripDocument): Promise<TripJson> {
  const response = await tripsRoute.POST(apiRequest("POST", "/api/v1/trips", { token: env.tokens.alice, body: { document } }));
  expect(response.status).toBe(201);
  return (await response.json()).trip;
}

const postTour = (tripId: string, token = env.tokens.alice, body: unknown = {}) =>
  tourRoute.POST(apiRequest("POST", `/api/v1/trips/${tripId}/tour`, { token, body }), params({ id: tripId }));
const getAudio = (tripId: string, key: string, index: string, token = env.tokens.alice) =>
  audioRoute.GET(apiRequest("GET", `/api/v1/trips/${tripId}/tour/${key}/scenes/${index}/audio`, { token }), params({ id: tripId, key, index }));

describe("trip tours", () => {
  it("passes rendered gallery captions to the narrator and stores the actual images in their guided chapter", async () => {
    const images = [{ url: "https://example.com/garden.jpg", caption: "The mossy shrine garden", credit: "Photographer" }];
    const trip = await createTrip({ ...tripDocument, views: [{ id: "garden-notes", title: "Garden", dayId: "d2", spec: {
      root: "gallery", elements: { gallery: { type: "Gallery", props: { images } } },
    } }] });
    vi.spyOn(env.ai, "narrateTour").mockImplementationOnce(async (input) => {
      env.ai.calls.narrateTour.push(input);
      return input.scenes.map((scene) => ({ title: "Explore", narration: "Let's explore the garden.", visuals:
        (scene.imageGroupIds ?? []).map((imageGroupId) => ({ textOffset: 0, imageGroupId, photoIndex: 0 })),
      }));
    });
    const response = await postTour(trip.id);
    expect(response.status).toBe(200);
    const { tour } = await response.json() as { tour: TripTour };
    expect(env.ai.calls.narrateTour[0].imageGroups).toEqual([{ id: "garden-notes:gallery", title: "Garden", photos: [{ index: 0, caption: "The mossy shrine garden" }] }]);
    expect(JSON.stringify(env.ai.calls.narrateTour[0])).not.toContain("https://example.com/garden.jpg");
    const garden = tour.scenes.find((scene) => scene.kind === "day" && scene.dayId === "d2")!;
    expect(garden.imageGroups).toEqual([{ id: "garden-notes:gallery", title: "Garden", dayId: "d2", photos: images }]);
    expect(garden.visuals).toEqual([{ textOffset: 0, imageGroupId: "garden-notes:gallery", photoIndex: 0 }]);
    expect(tour.scenes.filter((scene) => scene.dayId !== "d2").every((scene) => !scene.imageGroups?.length)).toBe(true);
    const stored = JSON.parse(new TextDecoder().decode(env.store.objects.get(`tours/${trip.id}/${tour.key}.json`)!.bytes)) as TripTour;
    expect(stored.scenes.find((scene) => scene.kind === "day" && scene.dayId === "d2")?.imageGroups).toEqual(garden.imageGroups);
  });

  it("introduces a day's journey once instead of replaying it as a getting-there chapter", () => {
    const document = tripDocumentSchema.parse({
      title: "Tokyo from Chiba", startDate: "2026-10-11", endDate: "2026-10-11",
      places: [
        { id: "chiba", name: "Chiba", kind: "hotel", coordinate: { lat: 35.6074, lng: 140.1065 } },
        { id: "tokyo", name: "Tokyo Station", kind: "station", coordinate: { lat: 35.6812, lng: 139.7671 } },
      ],
      days: [{
        id: "d2", date: "2026-10-11", title: "Nezu Museum and Aoyama", route: { kind: "side", placeIds: ["chiba", "tokyo", "chiba"] },
        moments: [{ slot: "morning", text: "Explore Nezu Museum and its garden, then walk through Aoyama and Omotesando." }],
        transportIds: ["to-tokyo"],
      }],
      transports: [{ id: "to-tokyo", date: "2026-10-11", label: "Chiba to Tokyo", options: [{ id: "rail", label: "Train", segments: [{ mode: "train", fromName: "Chiba", toName: "Tokyo" }] }] }],
    });
    const chapter = tourSkeleton(document).filter((scene) => scene.dayId === "d2");
    expect(chapter.map((scene) => scene.kind)).toEqual(["day"]);
    expect(chapter[0].facts.journeys).toEqual([{ segments: [{ mode: "train", from: "Chiba", to: "Tokyo" }] }]);
    expect(chapter[0].facts.experiences).toEqual([{ slot: "morning", text: "Explore Nezu Museum and its garden, then walk through Aoyama and Omotesando." }]);
  });

  it("plays each day's journey once, followed by distinct sights and neighborhoods", () => {
    const document = tripDocumentSchema.parse(tripDocument);
    const scenes = tourSkeleton(document);
    expect(scenes.map((scene) => [scene.kind, scene.dayId, scene.placeId ?? scene.transportId ?? scene.hotelId])).toEqual([
      ["intro", null, null],
      ["day", "d1", null],
      // The airport has nothing to say about it; Kyoto is toured once.
      ["place", "d1", "kyoto"],
      ["stay", "d1", "ryokan-place"],
      ["day", "d2", null],
      ["place", "d2", "fushimi"],
      ["day", "d3", null],
      ["place", "d3", "nara"],
      ["outro", null, null],
    ]);
    // Keep the map's rides and stays, but give the guide stories rather than logistics.
    const facts = JSON.stringify(scenes.map((scene) => scene.facts));
    expect(facts).not.toMatch(/7A|ABC123|Haruka 36|booked|09:00|10:20|09:30|15:00|3640|60000|80 minutes|Always open/);
    expect(facts).not.toMatch(/"(?:budget|costs|fare|price|pricing|departure|arrival|duration|time|hours|checkIn|checkOut|checkInTime|nights|status|weather)":/);
    const shrineDay = scenes.find((scene) => scene.kind === "day" && scene.dayId === "d2");
    expect(shrineDay?.facts).toMatchObject({
      blurb: "Follow the connection between rice, prosperity and Inari worship.",
      places: expect.arrayContaining([expect.objectContaining({ name: "Fushimi Inari", description: "A shrine to Inari with paths of vermilion torii and fox guardians.", note: "Look for the fox statues; try inari sushi nearby." })]),
      experiences: [{ slot: "morning", text: "Explore the torii paths and taste inari sushi", place: "Fushimi Inari" }],
    });
    expect(scenes.find((scene) => scene.kind === "day" && scene.dayId === "d1")?.facts.journeys).toEqual([
      { segments: [{ mode: "train", from: "Kansai Airport", to: "Kyoto", toDescription: "An old imperial capital with craft traditions and seasonal Kyoto cooking." }] },
    ]);
  });

  it("writes a tour once, stores it and its narration, and serves both again for free", async () => {
    const trip = await createTrip();
    const first = await postTour(trip.id);
    expect(first.status).toBe(200);
    const { tour } = await first.json() as { tour: TripTour };
    expect(tour.scenes).toHaveLength(9);
    expect(tour.scenes[0]).toMatchObject({ kind: "intro", audioPath: `/api/v1/trips/${trip.id}/tour/${tour.key}/scenes/0/audio` });
    expect(env.ai.calls.narrateTour).toHaveLength(1);
    expect(env.ai.calls.narrateTour[0].trip.mainPlaces).toEqual([
      expect.objectContaining({ name: "Kyoto", description: "An old imperial capital with craft traditions and seasonal Kyoto cooking." }),
    ]);
    expect(JSON.stringify(env.ai.calls.narrateTour[0])).not.toMatch(/ABC123|7A|booked|3640|60000|09:00|09:30|15:00/);
    expect(env.store.objects.has(`tours/${trip.id}/${tour.key}.json`)).toBe(true);
    // The first scenes are voiced right away.
    await vi.waitFor(() => expect(env.ai.calls.speak).toHaveLength(3));

    const again = await (await postTour(trip.id)).json() as { tour: TripTour };
    expect(again.tour.key).toBe(tour.key);
    expect(env.ai.calls.narrateTour).toHaveLength(1);

    const audio = await getAudio(trip.id, tour.key, "5");
    expect(audio.status).toBe(200);
    expect(audio.headers.get("content-type")).toBe("audio/mpeg");
    expect(await audio.text()).toContain(tour.scenes[5].narration);
    expect((await getAudio(trip.id, tour.key, "5")).status).toBe(200);
    expect((await getAudio(trip.id, tour.key, "0")).status).toBe(200);
    expect(env.ai.calls.speak).toHaveLength(4);

    // `regenerate` writes it again; unchanged narration keeps its audio.
    await postTour(trip.id, env.tokens.alice, { regenerate: true });
    expect(env.ai.calls.narrateTour).toHaveLength(2);
  });

  it("gives every day scene its own tour date so the guide can speak about that day's journey", () => {
    const document = tripDocumentSchema.parse(tripDocument);
    const scenes = tourSkeleton(document);
    for (const day of document.days) {
      const chapter = scenes.filter((scene) => scene.dayId === day.id);
      expect(chapter.length).toBeGreaterThan(0);
      for (const scene of chapter) expect(scene.facts.date).toBe(day.date);
    }
    expect(scenes.find((scene) => scene.kind === "day" && scene.dayId === "d1")?.facts.route).toMatchObject({
      stops: ["Kansai Airport", "Kyoto"],
    });
  });

  it("replaces a cached tour with duplicated day and getting-there chapters on the next play", async () => {
    const trip = await createTrip();
    const oldKey = createHash("sha256").update(JSON.stringify({
      version: 7, language: trip.language, model: env.ai.tourModelId(),
      speechModel: env.ai.speechModelId(), voice: tourVoice(), document: trip.document,
    })).digest("hex").slice(0, 32);
    await env.store.put(`tours/${trip.id}/${oldKey}.json`, {
      bytes: new TextEncoder().encode(JSON.stringify({ key: oldKey, scenes: [
        { kind: "day", dayId: "d1", narration: "Today we travel from Kansai Airport to Kyoto." },
        { kind: "travel", dayId: "d1", narration: "We are traveling from Kansai Airport to Kyoto." },
      ] })),
      contentType: "application/json",
    });

    const response = await postTour(trip.id);
    expect(response.status).toBe(200);
    const { tour } = await response.json() as { tour: TripTour };
    expect(tour.key).not.toBe(oldKey);
    expect(env.ai.calls.narrateTour).toHaveLength(1);
    expect(tour.scenes).toHaveLength(9);
    expect(tour.scenes.some((scene) => scene.kind === "travel")).toBe(false);
  });

  it("only plays tours of trips the caller can read", async () => {
    const trip = await createTrip();
    const { tour } = await (await postTour(trip.id)).json() as { tour: TripTour };
    expect((await postTour(trip.id, env.tokens.bob)).status).toBe(404);
    expect((await getAudio(trip.id, tour.key, "0", env.tokens.bob)).status).toBe(404);
    expect((await getAudio(trip.id, tour.key, "99")).status).toBe(404);
    expect((await getAudio(trip.id, "not-a-key", "0")).status).toBe(404);
  });

  it("fails without charging when the narration can't be written", async () => {
    const trip = await createTrip();
    vi.spyOn(env.ai, "narrateTour").mockRejectedValueOnce(new Error("model down"));
    const response = await postTour(trip.id);
    expect(response.status).toBe(502);
    expect((await response.json()).error.code).toBe("TOUR_FAILED");
  });
});
