import { describe, expect, it } from "vitest";
import { tripDocumentSchema, tripOperationSchema, type TripDocument } from "@/lib/contracts/trip";
import { viewText } from "@/lib/contracts/trip-view";
import { sourceImages } from "@/lib/ai/trip-agent";
import { directionsUrl, escapeHtml, renderTripReport, renderViewHtml, reportLanguage } from "@/lib/pdf/trip-report";
import { tripText } from "@/lib/services/trip-document";
import { tripPdfFilename } from "@/lib/services/trip-pdf";

function trip(overrides: Record<string, unknown> = {}): TripDocument {
  return tripDocumentSchema.parse({
    title: "Kyoto <weekend>",
    startDate: "2026-11-06",
    endDate: "2026-11-08",
    timeZone: "Asia/Tokyo",
    currency: "JPY",
    places: [{
      id: "kiyomizu",
      name: "Kiyomizu-dera",
      coordinate: { lat: 34.994856, lng: 135.785046 },
      description: "Wooden stage over the hillside.\nBest at dusk.",
      photos: [
        { url: "https://upload.wikimedia.org/kiyomizu.jpg", caption: "The stage", credit: "Wikimedia Commons" },
        { url: "https://upload.wikimedia.org/pagoda.jpg" },
      ],
      hours: "6:00–18:00",
      visitDuration: "1–2 h",
      pricing: [{ label: "Adult", price: { amount: 500, currency: "JPY" } }, { label: "Under 6", note: "With an adult" }],
      website: "https://www.kiyomizudera.or.jp/",
      phone: "+81 75-551-1234",
    }],
    days: [{ id: "day-1", date: "2026-11-06", title: "Higashiyama", moments: [{ slot: "evening", time: "17:30", text: "Temple at dusk", placeId: "kiyomizu" }] }],
    expenses: [
      { id: "pass", category: "pass", title: "Bus pass", amount: { amount: 1100, currency: "JPY" } },
      { id: "bus", category: "transport", title: "Bus", amount: { amount: 230, currency: "JPY" }, coveredByExpenseId: "pass" },
    ],
    ...overrides,
  });
}

describe("place details", () => {
  it("defaults photos and pricing, and keeps the guidebook fields", () => {
    const bare = tripDocumentSchema.parse({ title: "T", startDate: "2026-01-01", endDate: "2026-01-01", places: [{ id: "p", name: "P", coordinate: { lat: 0, lng: 0 } }] });
    expect(bare.places[0]).toMatchObject({ photos: [], pricing: [] });
    expect(trip().places[0]).toMatchObject({ hours: "6:00–18:00", visitDuration: "1–2 h", pricing: [{ label: "Adult" }, { label: "Under 6" }] });
  });

  it("only takes https photos", () => {
    const place = { id: "p", name: "P", coordinate: { lat: 0, lng: 0 } };
    expect(tripOperationSchema.safeParse({ op: "upsert_place", place: { ...place, photos: [{ url: "http://example.com/a.jpg" }] } }).success).toBe(false);
    expect(tripOperationSchema.safeParse({ op: "upsert_place", place: { ...place, photos: [{ url: "javascript:alert(1)" }] } }).success).toBe(false);
    expect(tripOperationSchema.safeParse({ op: "upsert_place", place: { ...place, photos: [{ url: "https://example.com/a.jpg" }] } }).success).toBe(true);
  });

  it("puts descriptions, hours and prices in the trip's searchable text", () => {
    const text = tripText(trip());
    expect(text).toContain("Wooden stage over the hillside.");
    expect(text).toContain("Hours: 6:00–18:00");
    expect(text).toContain("Adult: 500 JPY");
    expect(text).toContain("Under 6: free (With an adult)");
  });
});

describe("Image, Gallery and Place view elements", () => {
  const spec = {
    root: "root",
    elements: {
      root: { type: "Stack", children: ["hero", "more", "card"] },
      hero: { type: "Image", props: { url: "https://example.com/hero.jpg", caption: "Sunset", aspect: "wide" } },
      more: { type: "Gallery", props: { images: [{ url: "https://example.com/1.jpg", caption: "One" }, { url: "https://example.com/2.jpg" }] } },
      card: { type: "Place", props: { placeId: "kiyomizu" } },
    },
  };

  it("validates and reads their captions", () => {
    const doc = trip({ views: [{ id: "v", title: "Highlights", spec }] });
    expect(viewText(doc.views[0].spec)).toEqual(expect.arrayContaining(["Sunset", "One"]));
    const insecure = { ...spec, elements: { ...spec.elements, hero: { type: "Image", props: { url: "http://example.com/hero.jpg" } } } };
    expect(tripDocumentSchema.safeParse({ ...doc, views: [{ id: "v", title: "Highlights", spec: insecure }] }).success).toBe(false);
  });

  it("renders them as HTML, and a Place whose place is gone as nothing", () => {
    const doc = trip({ views: [{ id: "v", title: "Highlights", spec }] });
    const html = renderViewHtml(doc.views[0].spec, doc);
    expect(html).toContain('src="https://example.com/hero.jpg"');
    expect(html).toContain("Kiyomizu-dera");
    expect(html).toContain(escapeHtml(directionsUrl(34.994856, 135.785046)));
    const gone = renderViewHtml(doc.views[0].spec, { ...doc, places: [] });
    expect(gone).not.toContain("Kiyomizu-dera");
  });
});

describe("trip report", () => {
  it("escapes the document and prints header, footer and page numbers", () => {
    const { html, page } = renderTripReport(trip({ intro: "<script>alert(1)</script>" }));
    expect(html).not.toContain("<script>");
    expect(html).toContain("&lt;script&gt;");
    expect(html).toContain("Kyoto &lt;weekend&gt;");
    expect(page.headerTemplate).toContain("Kyoto &lt;weekend&gt;");
    expect(page.footerTemplate).toContain('class="pageNumber"');
    expect(page.footerTemplate).toContain('class="totalPages"');
    expect(page.margin).toEqual({ top: "22mm", bottom: "18mm", left: "16mm", right: "16mm" });
  });

  it("shows places as guidebook entries with photos, prices and directions", () => {
    const { html } = renderTripReport(trip());
    expect(html).toContain('src="https://upload.wikimedia.org/kiyomizu.jpg"');
    expect(html).toContain("Wikimedia Commons");
    expect(html).toContain("Wooden stage over the hillside.<br>Best at dusk.");
    expect(html).toContain("https://www.google.com/maps/dir/?api=1&amp;destination=34.994856,135.785046");
    expect(html).toContain("Free");
    expect(html).toContain('href="tel:+81755511234"');
  });

  it("totals the budget without covered expenses", () => {
    const { html } = renderTripReport(trip());
    expect(html).toMatch(/Total \(JPY\)<\/td><td class="align-trailing">JP¥1,100/);
  });

  it("speaks Chinese when asked", () => {
    expect(reportLanguage("zh-TW,en;q=0.8")).toBe("zh-Hant");
    expect(reportLanguage("zh-Hans")).toBe("zh-Hans");
    expect(reportLanguage("fr-FR")).toBe("en");
    expect(renderTripReport(trip(), "zh-Hant").html).toContain("第 1 天");
  });

  it("names the file after the trip", () => {
    expect(tripPdfFilename("Kyoto <weekend> 2026")).toBe("Kyoto-weekend-2026.pdf");
    expect(tripPdfFilename("北海道 · 秋")).toBe("北海道-秋.pdf");
    expect(tripPdfFilename("!!!")).toBe("trip.pdf");
  });
});

describe("sourceImages", () => {
  it("lists the page's https images, preview first, without icons", () => {
    const images = sourceImages({
      imageUrl: "https://example.com/og.jpg",
      html: '<p><img src="https://example.com/a.jpg?w=1&amp;h=2"><img src="http://example.com/insecure.jpg"><img src="https://example.com/logo.png"><img src="https://example.com/og.jpg"></p>',
    });
    expect(images).toEqual(["https://example.com/og.jpg", "https://example.com/a.jpg?w=1&h=2"]);
  });
});
