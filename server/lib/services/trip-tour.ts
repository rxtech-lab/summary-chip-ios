import { createHash } from "node:crypto";
import type { LanguageModelUsage } from "ai";
import { getAiProvider, type AiProvider } from "@/lib/ai/provider";
import { tourVoice } from "@/lib/ai/models";
import { LANGUAGE_NAMES } from "@/lib/ai/summary-schema";
import type { TranslationLanguage } from "@/lib/contracts/api";
import type { TripDocument } from "@/lib/contracts/trip";
import type { TourScene, TourSceneKind, TripTour } from "@/lib/contracts/tour";
import type { Database } from "@/lib/db/client";
import { runAfter } from "@/lib/http/after";
import { ApiError } from "@/lib/http/errors";
import { getObjectStore, type ObjectStore } from "@/lib/storage/r2";
import type { BillingEnvironment } from "@/lib/subscription/config";
import { pointsForCost, reserveTourPoints, usageCostUsd } from "@/lib/subscription/chat-billing";
import { activeTripDocument, tripDayCount } from "./trip-document";
import { findTripForViewer, readSavedTripDocument } from "./trips";
import { tourImageGroups } from "./trip-tour-images";

/** Trip tours: the trip played as narrated scenes over the map. Spec: `docs/tours.md`. */

/** Bump when the scenes or the narration prompt change, so stored tours are written again. */
const TOUR_VERSION = 9;
/** Places toured per day: the day's sights, not every station it passes. */
const MAX_DAY_PLACES = 4;
const MAX_DAY_TRANSPORTS = 3;
/** Long trips are cut short rather than narrated for hours. */
const MAX_SCENES = 90;
/** Scenes voiced right after a tour is written, so playback starts without waiting. */
const WARM_SCENES = 3;

export interface TourDeps {
  ai?: AiProvider;
  store?: ObjectStore;
  now?: () => Date;
  billingEnvironment?: BillingEnvironment;
}

/** A scene before narration: what it shows, and the facts the narrator may use. */
export interface TourSkeletonScene {
  kind: TourSceneKind;
  dayId: string | null;
  placeId: string | null;
  transportId: string | null;
  hotelId: string | null;
  facts: Record<string, unknown>;
}

type Day = TripDocument["days"][number];

function compact<T extends Record<string, unknown>>(value: T): Partial<T> {
  return Object.fromEntries(Object.entries(value).filter(([, entry]) =>
    entry !== null && entry !== undefined && entry !== "" && !(Array.isArray(entry) && entry.length === 0))) as Partial<T>;
}

function weekday(date: string): string {
  return new Date(`${date}T12:00:00Z`).toLocaleDateString("en-US", { weekday: "long", timeZone: "UTC" });
}

/** The places a day tours: its route, then its moments' places, sights before stations. */
function dayPlaceIds(document: TripDocument, day: Day, toured: Set<string>): string[] {
  const places = new Map(document.places.map((place) => [place.id, place]));
  const hotelPlaces = new Set(document.hotels.flatMap((hotel) => hotel.placeId ? [hotel.placeId] : []));
  const ids = [...new Set([...day.route?.placeIds ?? [], ...day.moments.flatMap((moment) => moment.placeId ? [moment.placeId] : [])])];
  const worth = (id: string) => {
    const place = places.get(id);
    if (!place || toured.has(id) || hotelPlaces.has(id)) return false;
    // Stations, airports and ports are only toured when there's something to say about them.
    if (["station", "airport", "port", "hotel"].includes(place.kind)) return Boolean(place.description || place.photos.length);
    return true;
  };
  return ids.filter(worth).slice(0, MAX_DAY_PLACES);
}

function placeFacts(place: TripDocument["places"][number]) {
  return compact({
    id: place.id,
    name: place.name,
    kind: place.kind,
    address: place.address,
    description: place.description,
    note: place.note,
  });
}

function transportFacts(places: Map<string, TripDocument["places"][number]>, transport: TripDocument["transports"][number]) {
  const option = transport.options.find((candidate) => candidate.id === transport.selectedOptionId) ?? transport.options[0];
  return compact({
    // The map still follows the selected ride; the guide only needs its geography.
    segments: option.segments.slice(0, 6).map((segment) => compact({
      mode: segment.mode,
      from: segment.fromName,
      to: segment.toName,
      fromDescription: segment.fromPlaceId ? places.get(segment.fromPlaceId)?.description : null,
      toDescription: segment.toPlaceId ? places.get(segment.toPlaceId)?.description : null,
    })),
  });
}

/**
 * The scenes of a tour, in the order they play: an intro over the whole trip; then for every day,
 * one day opening including its journey, the distinct sights it visits (each once over the trip)
 * and the first neighborhood at each hotel; and an outro. Journey facts belong to the day,
 * rather than a second "getting there" introduction. The app draws the map from the day ids.
 */
export function tourSkeleton(document: TripDocument): TourSkeletonScene[] {
  const places = new Map(document.places.map((place) => [place.id, place]));
  const transports = new Map(document.transports.map((transport) => [transport.id, transport]));
  const hotels = new Map(document.hotels.map((hotel) => [hotel.id, hotel]));
  const days = [...document.days].sort((a, b) => a.date.localeCompare(b.date));
  const scene = (kind: TourSceneKind, facts: Record<string, unknown>, ids: Partial<Pick<TourSkeletonScene, "dayId" | "placeId" | "transportId" | "hotelId">> = {}): TourSkeletonScene =>
    ({ kind, dayId: null, placeId: null, transportId: null, hotelId: null, ...ids, facts });

  const scenes: TourSkeletonScene[] = [scene("intro", compact({
    title: document.title,
    subtitle: document.subtitle,
    intro: document.intro,
    startDate: document.startDate,
    endDate: document.endDate,
    days: tripDayCount(document),
    mainPlaces: document.places.filter((place) => place.major).slice(0, 8).map((place) => place.name),
  }))];
  const toured = new Set<string>();
  let previousStay: string | null = null;
  days.forEach((day, index) => {
    // Keep the tour day's date with every scene, including batches starting mid-chapter.
    const dayContext = { day: index + 1, date: day.date, weekday: weekday(day.date) };
    const dayScene = (kind: TourSceneKind, facts: Record<string, unknown>, ids: Partial<Pick<TourSkeletonScene, "placeId" | "transportId" | "hotelId">> = {}) =>
      scene(kind, { ...dayContext, ...facts }, { dayId: day.id, ...ids });
    const dayScenes: TourSkeletonScene[] = [dayScene("day", compact({
      title: day.title,
      short: day.short,
      blurb: day.blurb,
      route: day.route ? compact({ kind: day.route.kind, summary: day.route.summary, stops: day.route.placeIds.flatMap((id) => places.get(id)?.name ?? []) }) : null,
      journeys: day.transportIds.slice(0, MAX_DAY_TRANSPORTS).flatMap((id) => {
        const transport = transports.get(id);
        return transport ? [transportFacts(places, transport)] : [];
      }),
      // Include familiar places again as day context, even though their own scene plays only once.
      places: dayPlaceIds(document, day, new Set()).map((id) => placeFacts(places.get(id)!)),
      experiences: day.moments.slice(0, 10).map((moment) => compact({ slot: moment.slot, text: moment.text, place: moment.placeId ? places.get(moment.placeId)?.name : null })),
      tip: day.tip,
    }))];
    for (const id of dayPlaceIds(document, day, toured)) {
      toured.add(id);
      dayScenes.push(dayScene("place", placeFacts(places.get(id)!), { placeId: id }));
    }
    const hotel = day.stayId ? hotels.get(day.stayId) : undefined;
    if (hotel && hotel.id !== previousStay) {
      const place = hotel.placeId ? places.get(hotel.placeId) : undefined;
      dayScenes.push(dayScene("stay", compact({
        name: hotel.name,
        address: hotel.address ?? place?.address,
        area: place?.name,
        areaDescription: place?.description,
        areaNote: place?.note,
        nearbyPlaces: dayPlaceIds(document, day, new Set()).map((id) => placeFacts(places.get(id)!)),
      }), { hotelId: hotel.id, placeId: hotel.placeId ?? null }));
    }
    previousStay = day.stayId ?? previousStay;
    scenes.push(...dayScenes);
  });
  const trimmed = scenes.slice(0, MAX_SCENES - 1);
  trimmed.push(scene("outro", compact({
    title: document.title,
    days: tripDayCount(document),
    placesVisited: toured.size,
    lastDay: days.at(-1)?.title,
    shortened: scenes.length > trimmed.length || null,
  })));
  return trimmed;
}

/** Names a tour version: the trip as followed, the language, the models and the voice. */
export function tourKey(document: TripDocument, language: string, model: string, speechModel: string | null, voice: string): string {
  return createHash("sha256")
    .update(JSON.stringify({ version: TOUR_VERSION, language, model, speechModel, voice, document }))
    .digest("hex")
    .slice(0, 32);
}

function tourObjectKey(tripId: string, key: string): string {
  return `tours/${tripId}/${key}.json`;
}

/** Narration audio is keyed by what it says and who says it, so unchanged scenes keep their audio across tours. */
export function speechObjectKey(speechModel: string, voice: string, text: string): string {
  return `tour-audio/${createHash("sha256").update(JSON.stringify([speechModel, voice, text])).digest("hex")}.mp3`;
}

function audioPath(tripId: string, key: string, index: number): string {
  return `/api/v1/trips/${encodeURIComponent(tripId)}/tour/${key}/scenes/${index}/audio`;
}

async function readTour(store: ObjectStore, tripId: string, key: string): Promise<TripTour | null> {
  try {
    const object = await store.get(tourObjectKey(tripId, key));
    return JSON.parse(new TextDecoder().decode(object.bytes)) as TripTour;
  } catch (error) {
    if (error instanceof ApiError && error.code === "OBJECT_MISSING") return null;
    throw error;
  }
}

/** Tours being written in this instance, so a double tap doesn't write (and charge) twice. */
const writing = new Map<string, Promise<TripTour>>();
const speaking = new Map<string, Promise<Uint8Array>>();

/**
 * `POST /api/v1/trips/:id/tour`: the tour of the trip as the viewer follows it, in the language
 * they read it in. A stored tour of the same version is returned as is (free); otherwise the tour
 * model narrates it, and the viewer is charged for the narration and the speech it will need.
 */
export async function getOrCreateTour(db: Database, tripId: string, viewerId: string, accepted: TranslationLanguage | null, options: { regenerate?: boolean } = {}, deps: TourDeps = {}): Promise<TripTour> {
  const ai = deps.ai ?? await getAiProvider();
  const store = deps.store ?? getObjectStore();
  const { document: saved, language, planSelections, originalLanguage } = await readSavedTripDocument(db, tripId, viewerId, accepted);
  const document = activeTripDocument(saved, planSelections);
  const spoken = language ?? originalLanguage;
  const voice = tourVoice();
  const key = tourKey(document, spoken, ai.tourModelId(), ai.speechModelId(), voice);
  if (!options.regenerate) {
    const stored = await readTour(store, tripId, key);
    if (stored) return stored;
  }
  const inFlight = writing.get(`${tripId}:${key}`);
  if (inFlight) return inFlight;
  const run = writeTour(db, { tripId, viewerId, document, language: spoken, voice, key }, { ...deps, ai, store })
    .finally(() => writing.delete(`${tripId}:${key}`));
  writing.set(`${tripId}:${key}`, run);
  return run;
}

async function writeTour(
  db: Database,
  input: { tripId: string; viewerId: string; document: TripDocument; language: string; voice: string; key: string },
  deps: TourDeps & { ai: AiProvider; store: ObjectStore },
): Promise<TripTour> {
  const { ai, store } = deps;
  const skeleton = tourSkeleton(input.document);
  const imageGroups = tourImageGroups(input.document);
  const charge = await reserveTourPoints(input.viewerId, input.tripId, input.key, ai.tourModelId(), deps.billingEnvironment);
  const steps: LanguageModelUsage[] = [];
  let narration;
  try {
    narration = await ai.narrateTour({
      language: LANGUAGE_NAMES[input.language as TranslationLanguage] ?? input.language,
      trip: compact({
        title: input.document.title,
        subtitle: input.document.subtitle,
        intro: input.document.intro,
        startDate: input.document.startDate,
        endDate: input.document.endDate,
        days: tripDayCount(input.document),
        mainPlaces: input.document.places.filter((place) => place.major).slice(0, 8).map(placeFacts),
      }),
      places: input.document.places.map((place) => ({
        id: place.id, name: place.name,
        photos: place.photos.map((photo, index) => ({ index, caption: photo.caption })),
      })),
      imageGroups: imageGroups.map((group) => ({
        id: group.id, title: group.title,
        photos: group.photos.map((photo, index) => ({ index, caption: photo.caption })),
      })),
      scenes: skeleton.map(({ kind, facts, dayId, placeId }) => {
        const day = input.document.days.find((candidate) => candidate.id === dayId);
        const hotel = day?.stayId ? input.document.hotels.find((candidate) => candidate.id === day.stayId) : undefined;
        const rides = input.document.transports.filter((transport) => day?.transportIds.includes(transport.id))
          .flatMap((transport) => (transport.options.find((option) => option.id === transport.selectedOptionId) ?? transport.options[0]).segments)
          .flatMap((segment) => [segment.fromPlaceId, segment.toPlaceId].filter((id): id is string => Boolean(id)));
        const ids = day ? [...(day.route?.placeIds ?? []), ...day.moments.flatMap((moment) => moment.placeId ? [moment.placeId] : []), ...(hotel?.placeId ? [hotel.placeId] : []), ...rides]
          : input.document.places.filter((place) => place.major).slice(0, 8).map((place) => place.id);
        // Places mentioned in free-text moments may not have a route or moment placeId yet.
        const text = JSON.stringify(facts).normalize("NFKC").toLowerCase().replace(/[\s_]/g, "");
        const named = input.document.places.filter((place) => text.includes(place.name.normalize("NFKC").toLowerCase().replace(/[\s_]/g, ""))).map((place) => place.id);
        return {
          kind, facts, placeIds: [...new Set([...ids, ...(placeId ? [placeId] : []), ...named])],
          // Day-specific rendered galleries belong to that day's story, after plan selection.
          imageGroupIds: day ? imageGroups.filter((group) => !group.dayId || group.dayId === day.id).map((group) => group.id) : [],
        };
      }),
    }, { onUsage: (usage) => steps.push(usage), abortSignal: AbortSignal.timeout(150_000) });
  } catch (error) {
    console.error("[tour] narration failed", { tripId: input.tripId, error });
    await charge?.settle(0, { failed: true });
    throw new ApiError(502, "TOUR_FAILED", "The tour couldn't be written. Please try again.");
  }

  const createdAt = (deps.now?.() ?? new Date()).toISOString();
  const scenes: TourScene[] = skeleton.map((scene, index) => ({
    kind: scene.kind,
    dayId: scene.dayId,
    placeId: scene.placeId,
    transportId: scene.transportId,
    hotelId: scene.hotelId,
    title: narration[index].title,
    narration: narration[index].narration,
    visuals: narration[index].visuals,
    landmarks: narration[index].landmarks,
    imageGroups: imageGroups.filter((group) => narration[index].visuals.some((visual) => visual.imageGroupId === group.id)),
    audioPath: audioPath(input.tripId, input.key, index),
  }));
  const tour: TripTour = { key: input.key, language: input.language, voice: input.voice, createdAt, scenes };
  await store.put(tourObjectKey(input.tripId, input.key), {
    bytes: new TextEncoder().encode(JSON.stringify(tour)),
    contentType: "application/json",
  });

  const speechModel = ai.speechModelId();
  if (charge) {
    // Speech already stored (unchanged scenes of an earlier tour) costs nothing again; without a speech model there is none.
    const missing = await Promise.all(scenes.map(async (scene) =>
      !speechModel || await store.head(speechObjectKey(speechModel, input.voice, scene.narration)) ? 0 : scene.narration.length));
    const characters = missing.reduce((sum, count) => sum + count, 0);
    const pricing = await ai.tourPricing().catch(() => null);
    const textCost = pricing ? steps.reduce((sum, usage) => sum + usageCostUsd(usage, pricing), 0) : 0;
    const speechCost = characters * ai.speechUsdPerCharacter();
    const points = Math.max(pointsForCost(textCost + speechCost), steps.length ? 1 : 0);
    await charge.settle(points, { scenes: scenes.length, characters, textCostUsd: textCost, speechCostUsd: speechCost, speechModel });
  }

  // Voice the first scenes now so playback can start while the rest is read on demand.
  if (speechModel) {
    runAfter(async () => {
      for (const scene of scenes.slice(0, WARM_SCENES)) await sceneSpeech(store, ai, speechModel, input.voice, scene.narration).catch(() => null);
    });
  }
  return tour;
}

/** A scene's narration audio: stored once per text and voice, read aloud the first time it's asked for. */
async function sceneSpeech(store: ObjectStore, ai: AiProvider, speechModel: string, voice: string, text: string): Promise<Uint8Array> {
  const objectKey = speechObjectKey(speechModel, voice, text);
  const pending = speaking.get(objectKey);
  if (pending) return pending;
  const run = (async () => {
    try {
      return (await store.get(objectKey)).bytes;
    } catch (error) {
      if (!(error instanceof ApiError && error.code === "OBJECT_MISSING")) throw error;
    }
    const audio = await ai.speak(text, voice);
    await store.put(objectKey, { bytes: audio.bytes, contentType: "audio/mpeg", cacheControl: "private, max-age=31536000, immutable" });
    return audio.bytes;
  })().finally(() => speaking.delete(objectKey));
  speaking.set(objectKey, run);
  return run;
}

/**
 * `GET /api/v1/trips/:id/tour/:key/scenes/:index/audio`: a stored tour scene read aloud, for anyone
 * who can open the trip. The tour was charged when it was written, so this is free.
 */
export async function tourSceneAudio(db: Database, tripId: string, viewerId: string, key: string, index: number, deps: Pick<TourDeps, "ai" | "store"> = {}): Promise<Uint8Array> {
  if (!/^[0-9a-f]{32}$/.test(key) || !Number.isInteger(index) || index < 0) throw new ApiError(404, "NOT_FOUND", "The tour scene does not exist");
  if (!await findTripForViewer(db, tripId, viewerId)) throw new ApiError(404, "NOT_FOUND", "The trip does not exist");
  const ai = deps.ai ?? await getAiProvider();
  const store = deps.store ?? getObjectStore();
  const tour = await readTour(store, tripId, key);
  const scene = tour?.scenes[index];
  if (!tour || !scene) throw new ApiError(404, "NOT_FOUND", "The tour scene does not exist");
  const speechModel = ai.speechModelId();
  if (!speechModel) throw new ApiError(503, "TOUR_SPEECH_UNAVAILABLE", "Tour narration isn't available right now.");
  try {
    return await sceneSpeech(store, ai, speechModel, tour.voice, scene.narration);
  } catch (error) {
    if (error instanceof ApiError) throw error;
    console.error("[tour] speech failed", { tripId, key, index, error });
    throw new ApiError(502, "TOUR_SPEECH_FAILED", "The narration couldn't be read aloud. Please try again.");
  }
}
