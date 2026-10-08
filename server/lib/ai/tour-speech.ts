import type { TourLandmark, TourVisual } from "@/lib/contracts/tour";

interface Place {
  id: string;
  name: string;
  photos: { index: number; caption: string | null | undefined }[];
}

/** Give the narrator exact, unambiguous commands instead of asking the player to identify prose. */
export function tourSpeechPlaces(places: Place[]) {
  const aliases = new Set<string>();
  return places.map((place) => {
    const base = encodeURIComponent(place.id).toUpperCase();
    let alias = base;
    while (aliases.has(alias)) alias += `_${aliases.size + 1}`;
    aliases.add(alias);
    return {
      ...place,
      navigateCommand: `[NAVIGATE_TO_${alias}]`,
      photos: place.photos.map((photo) => ({ ...photo, showCommand: `[SHOW_PHOTO_${alias}_${photo.index}]` })),
    };
  });
}

export function tourSpeechImages(groups: { id: string; title: string; photos: Place["photos"] }[]) {
  return groups.map((group, index) => ({
    ...group,
    showCommand: `[SHOW_IMAGES_${index + 1}]`,
    photos: group.photos.map((photo) => ({ ...photo, showCommand: `[SHOW_IMAGE_${index + 1}_${photo.index}]` })),
  }));
}

/** Compile once on the server. Offsets use UTF-16, matching String.utf16 on Apple platforms. */
export function compileTourSpeech(script: string, places: ReturnType<typeof tourSpeechPlaces>, images: ReturnType<typeof tourSpeechImages> = [], landmarks: TourLandmark[] = []) {
  const commands = new Map<string, Omit<TourVisual, "textOffset">>();
  for (const place of places) {
    commands.set(place.navigateCommand, { placeId: place.id, photoIndex: null });
    for (const photo of place.photos) commands.set(photo.showCommand, { placeId: place.id, photoIndex: photo.index });
  }
  for (const landmark of landmarks) commands.set(`[NAVIGATE_LANDMARK_${landmark.id.slice("landmark-".length)}]`, { landmarkId: landmark.id, photoIndex: null });
  for (const group of images) {
    commands.set(group.showCommand, { imageGroupId: group.id, photoIndex: null });
    for (const photo of group.photos) commands.set(photo.showCommand, { imageGroupId: group.id, photoIndex: photo.index });
  }
  let narration = "";
  const visuals: TourVisual[] = [];
  let destination: Pick<TourVisual, "placeId" | "landmarkId"> = {};
  for (let index = 0; index < script.length;) {
    if (["[NAVIGATE_TO_", "[NAVIGATE_LANDMARK_", "[SHOW_PHOTO_", "[SHOW_IMAGES_", "[SHOW_IMAGE_"].some((prefix) => script.startsWith(prefix, index))) {
      const end = script.indexOf("]", index);
      if (end === -1) throw new Error("Unterminated tour speech command");
      const command = commands.get(script.slice(index, end + 1));
      if (command) {
        if (command.placeId || command.landmarkId) destination = command.placeId ? { placeId: command.placeId } : { landmarkId: command.landmarkId };
        visuals.push({ textOffset: narration.length, ...(command.imageGroupId ? destination : {}), ...command });
      }
      // Unknown destinations and photos are stripped too, but never execute.
      index = end + 1;
    } else {
      narration += script[index++];
    }
  }
  const leading = narration.length - narration.trimStart().length;
  narration = narration.trim();
  return { narration, visuals: visuals.map((visual) => ({ ...visual, textOffset: Math.min(narration.length, Math.max(0, visual.textOffset - leading)) })) };
}

export function validTourSpeech(script: string, places: ReturnType<typeof tourSpeechPlaces>, images: ReturnType<typeof tourSpeechImages> = [], landmarks: TourLandmark[] = []): boolean {
  try {
    const { narration, visuals } = compileTourSpeech(script, places, images, landmarks);
    return narration.length > 0 && narration.length <= 2000 && visuals.length <= 24;
  } catch { return false; }
}
