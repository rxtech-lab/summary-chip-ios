import { z } from "zod";
import type { TripDocument } from "./trip";

/** A trip tour: the trip played as narrated scenes over the map. Spec: `docs/tours.md`. */

export const TOUR_SCENE_KINDS = ["intro", "day", "travel", "place", "stay", "outro"] as const;
export type TourSceneKind = (typeof TOUR_SCENE_KINDS)[number];

/** A compiled speech command that brings a place or one of its photos into view. */
export const tourVisualSchema = z.object({
  textOffset: z.number().int().min(0),
  placeId: z.string().trim().min(1).max(80).optional(),
  landmarkId: z.string().trim().min(1).max(80).optional(),
  imageGroupId: z.string().trim().min(1).max(200).optional(),
  photoIndex: z.number().int().min(0).max(11).nullish(),
});
export type TourVisual = z.infer<typeof tourVisualSchema>;

/** Images rendered by a custom trip view, kept in their original order with attribution. */
export interface TourImageGroup {
  id: string;
  title: string;
  dayId?: string | null;
  photos: TripDocument["places"][number]["photos"];
}

/** A landmark named in the itinerary but missing from its city-level saved map stops. */
export interface TourLandmark {
  id: string;
  name: string;
  /** Apple Maps searches near this saved place; the model never supplies coordinates. */
  nearPlaceId: string;
}

export const tourNarratedLandmarkSchema = z.object({
  number: z.number().int().min(1).max(8),
  name: z.string().trim().min(1).max(200),
  nearPlaceId: z.string().trim().min(1).max(80),
});

export interface TourScene {
  kind: TourSceneKind;
  /** The day the scene belongs to (null for the intro and outro). */
  dayId: string | null;
  /** The place the camera visits (`place`, and `stay` when the hotel has a place). */
  placeId: string | null;
  /** The transport being ridden (`travel`). */
  transportId: string | null;
  /** The hotel of the night (`stay`). */
  hotelId: string | null;
  /** A short caption over the map, written by the narrator. */
  title: string;
  /** What the narrator says; also shown as subtitles. */
  narration: string;
  /** Compiled command positions in the clean narration, measured in UTF-16 code units. */
  visuals?: TourVisual[];
  imageGroups?: TourImageGroup[];
  landmarks?: TourLandmark[];
  /** Where the app downloads the scene's narration (`audio/mpeg`), relative to the API origin. */
  audioPath: string;
}

export interface TripTour {
  /** Names this version of the tour: the trip as followed, its language, model and voice. */
  key: string;
  language: string;
  voice: string;
  createdAt: string;
  scenes: TourScene[];
}

/** `POST /api/v1/trips/:id/tour`. `regenerate` writes the tour again even when one is stored. */
export const createTourSchema = z.object({ regenerate: z.boolean().optional() }).default({});

/** What the narrator writes for each scene, in order. */
export const tourNarrationSchema = z.object({
  scenes: z.array(z.object({
    title: z.string().trim().min(1).max(80),
    // Includes inline commands. The compiler separately limits clean speech to 2000 characters.
    narration: z.string().trim().min(1).max(22000),
    landmarks: z.array(tourNarratedLandmarkSchema).max(8).optional(),
  })),
});
export interface TourNarration {
  title: string;
  narration: string;
  visuals: TourVisual[];
  landmarks?: TourLandmark[];
}
