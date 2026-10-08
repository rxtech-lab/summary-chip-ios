import { describe, expect, it } from "vitest";
import { tripDocumentSchema } from "@/lib/contracts/trip";
import { activeTripDocument } from "@/lib/services/trip-document";
import { tourImageGroups } from "@/lib/services/trip-tour-images";

// Reproduces the saved Tokyo day: museums have images in JSON UI, but no saved museum place.
const document = tripDocumentSchema.parse({
  title: "Tokyo", startDate: "2026-10-11", endDate: "2026-10-11",
  places: [{ id: "tokyo", name: "Tokyo", coordinate: { lat: 35.685, lng: 139.7514 } }],
  days: [{ id: "d2", date: "2026-10-11", title: "Nezu Museum and Aoyama", route: { kind: "side", placeIds: ["tokyo"] } }],
  plans: [{ id: "plan", title: "Explore or rest", scope: "day", date: "2026-10-11", defaultOptionId: "aoyama", options: [
    { id: "aoyama", label: "Aoyama" }, { id: "rest", label: "Rest" },
  ] }],
  views: [{ id: "aoyama-reference", title: "Aoyama architecture", dayId: "d2", planOptionId: "aoyama", spec: {
    root: "root", elements: {
      root: { type: "Stack", children: ["gallery", "details"] },
      gallery: { type: "Gallery", props: { images: [
        { url: "https://example.com/nezu.jpg", caption: "Nezu Museum's bamboo entrance", credit: "Photographer A" },
        { url: "https://example.com/prada.jpg", caption: "Prada Aoyama's diamond glass facade", credit: "Photographer B" },
        { url: "https://example.com/garden.jpg", caption: "Nezu Museum's moss, trees and garden paths", credit: "Photographer C" },
      ] } },
      details: { type: "Disclosure", props: { title: "A closer look", expanded: false }, children: ["photo"] },
      photo: { type: "Image", props: { url: "https://example.com/detail.jpg", caption: "Roof detail", credit: "Photographer D" } },
      orphan: { type: "Image", props: { url: "https://example.com/hidden.jpg" } },
    },
  } }],
});

describe("custom tour images", () => {
  it("includes reachable galleries and disclosure images with original order and attribution", () => {
    const groups = tourImageGroups(activeTripDocument(document));
    expect(groups.map((group) => group.id)).toEqual(["aoyama-reference:gallery", "aoyama-reference:photo"]);
    expect(groups[0]).toMatchObject({ title: "Aoyama architecture", dayId: "d2" });
    expect(groups[0].photos.map((photo) => [photo.caption, photo.credit])).toEqual([
      ["Nezu Museum's bamboo entrance", "Photographer A"], ["Prada Aoyama's diamond glass facade", "Photographer B"], ["Nezu Museum's moss, trees and garden paths", "Photographer C"],
    ]);
    expect(groups[1]).toMatchObject({ title: "A closer look", photos: [{ url: "https://example.com/detail.jpg", caption: "Roof detail", credit: "Photographer D" }] });
    expect(document.places[0].photos).toEqual([]);
  });

  it("excludes imagery belonging to a plan the reader did not select", () => {
    expect(tourImageGroups(activeTripDocument(document, { plan: "rest" }))).toEqual([]);
  });
});
