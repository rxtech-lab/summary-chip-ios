import { describe, expect, it } from "vitest";
import { compileTourSpeech, tourSpeechImages, tourSpeechPlaces, validTourSpeech } from "@/lib/ai/tour-speech";

const places = tourSpeechPlaces([
  { id: "tokyo", name: "Tokyo", photos: [{ index: 0, caption: "A garden" }, { index: 1, caption: "The pond" }] },
  { id: "kyoto", name: "Kyoto", photos: [] },
]);

describe("tour speech commands", () => {
  it("shows custom gallery images at a landmark and returns to the saved city without stale images", () => {
    const images = tourSpeechImages([{ id: "aoyama:gallery", title: "Aoyama", photos: [{ index: 0, caption: "Nezu entrance" }, { index: 1, caption: "Nezu garden" }] }]);
    const landmarks = [{ id: "landmark-1", name: "Nezu Museum", nearPlaceId: "tokyo" }];
    const result = compileTourSpeech("[NAVIGATE_LANDMARK_1][SHOW_IMAGES_1]Explore Nezu. [SHOW_IMAGE_1_1]Look at the mossy garden. [NAVIGATE_TO_TOKYO]Back to Tokyo.", places, images, landmarks);
    expect(result.narration).toBe("Explore Nezu. Look at the mossy garden. Back to Tokyo.");
    expect(result.visuals).toEqual([
      { textOffset: 0, landmarkId: "landmark-1", photoIndex: null },
      { textOffset: 0, landmarkId: "landmark-1", imageGroupId: "aoyama:gallery", photoIndex: null },
      { textOffset: 14, landmarkId: "landmark-1", imageGroupId: "aoyama:gallery", photoIndex: 1 },
      { textOffset: 40, placeId: "tokyo", photoIndex: null },
    ]);
    expect(compileTourSpeech("[SHOW_IMAGE_1_1]Look.", places, images).visuals[0]).toEqual({ textOffset: 0, imageGroupId: "aoyama:gallery", photoIndex: 1 });
    expect(compileTourSpeech("[SHOW_IMAGES_999][NAVIGATE_LANDMARK_99][SHOW_IMAGE_1_99]Look.", places, images, landmarks).visuals).toEqual([]);
    expect(validTourSpeech("[SHOW_IMAGES_1", places, images)).toBe(false);
  });
  it("removes commands and records exact UTF-16 positions, including repeated visits and Unicode", () => {
    const result = compileTourSpeech("  [NAVIGATE_TO_TOKYO]东京 🗼。 [SHOW_PHOTO_TOKYO_1]看看池塘。 [NAVIGATE_TO_KYOTO]探索京都。 [NAVIGATE_TO_TOKYO]回到东京。  ", places);
    expect(result.narration).toBe("东京 🗼。 看看池塘。 探索京都。 回到东京。");
    expect(result.visuals).toEqual([
      { textOffset: 0, placeId: "tokyo", photoIndex: null },
      { textOffset: result.narration.indexOf("看看"), placeId: "tokyo", photoIndex: 1 },
      { textOffset: result.narration.indexOf("探索"), placeId: "kyoto", photoIndex: null },
      { textOffset: result.narration.indexOf("回到"), placeId: "tokyo", photoIndex: null },
    ]);
  });

  it("strips unknown or out-of-scene destinations and photos without executing them", () => {
    expect(compileTourSpeech("[NAVIGATE_TO_MISSING][SHOW_PHOTO_TOKYO_9][NAVIGATE_TO_KYOTO]Hello.", places.slice(0, 1)))
      .toEqual({ narration: "Hello.", visuals: [] });
  });

  it("keeps literal brackets and rejects unclosed commands or speech outside the limits", () => {
    expect(compileTourSpeech("Read [this] sign.", places).narration).toBe("Read [this] sign.");
    expect(validTourSpeech("[NAVIGATE_TO_TOKYO", places)).toBe(false);
    expect(validTourSpeech("[NAVIGATE_TO_TOKYO]", places)).toBe(false);
    expect(validTourSpeech("a".repeat(2001), places)).toBe(false);
    expect(validTourSpeech("[NAVIGATE_TO_TOKYO]".repeat(25) + "Hello.", places)).toBe(false);
  });

  it("supplies unique commands even when place IDs differ only in case", () => {
    const commands = tourSpeechPlaces([
      { id: "tokyo", name: "Tokyo", photos: [] }, { id: "TOKYO", name: "Another place", photos: [] },
    ]);
    expect(commands[0].navigateCommand).not.toBe(commands[1].navigateCommand);
    expect(compileTourSpeech(`${commands[1].navigateCommand}Visit.`, commands).visuals[0].placeId).toBe("TOKYO");
  });
});
