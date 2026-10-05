import { parseHTML } from "linkedom";
import sharp from "sharp";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { fetchPublicDocument } from "@/lib/extract/fetch";
import { prepareReportImages } from "@/lib/pdf/report-images";

vi.mock("@/lib/extract/fetch", () => ({ fetchPublicDocument: vi.fn() }));
const fetchImage = vi.mocked(fetchPublicDocument);
const source = "https://photos.example/large.png";
beforeEach(() => { fetchImage.mockReset(); });
afterEach(() => { vi.restoreAllMocks(); });

describe("report photos", () => {
  it("embeds a resized JPEG, fetches duplicates once, and preserves captions and text", async () => {
    const bytes = await sharp({ create: { width: 3000, height: 2000, channels: 4, background: { r: 40, g: 120, b: 200, alpha: 0.5 } } }).png().toBuffer();
    fetchImage.mockResolvedValue({ url: new URL(source), contentType: "image/png", bytes });
    const html = await prepareReportImages(`<!doctype html><html lang="en"><head><style>p { color: red; }</style></head><body><p>Itinerary &amp; notes</p><figure><img src="${source}" alt="Hill"><figcaption>Credit &amp; caption</figcaption></figure><img src="${source}" alt="Hill again"></body></html>`);
    const { document } = parseHTML(html);
    const images = Array.from(document.querySelectorAll("img"));
    const src = images[0].getAttribute("src")!;
    expect(src).toMatch(/^data:image\/jpeg;base64,/);
    expect(images[1].getAttribute("src")).toBe(src);
    expect(fetchImage).toHaveBeenCalledOnce();
    expect(fetchImage).toHaveBeenCalledWith(source, expect.objectContaining({ maxBytes: 15 * 1024 * 1024, accept: "image/*" }));
    const jpeg = Buffer.from(src.split(",")[1], "base64");
    const metadata = await sharp(jpeg).metadata();
    expect(metadata).toMatchObject({ format: "jpeg", width: 1440, height: 960, hasAlpha: false });
    expect(jpeg.byteLength).toBeLessThanOrEqual(256 * 1024);
    expect(document.querySelector("figcaption")?.textContent).toBe("Credit & caption");
    expect(document.querySelector("p")?.textContent).toBe("Itinerary & notes");
    expect(document.querySelector("style")?.textContent).toBe("p { color: red; }");
  });

  it("keeps a photo source link and credit when fetching fails", async () => {
    fetchImage.mockRejectedValue(new TypeError("terminated"));
    const html = await prepareReportImages(`<html lang="zh-Hant"><body><figure><img src="${source}" alt="Hill"><figcaption>Credit</figcaption></figure><img src="https://photos.example/other.jpg"></body></html>`);
    const { document } = parseHTML(html);
    expect(document.querySelectorAll("img").length).toBe(0);
    expect(document.querySelector("a")?.getAttribute("href")).toBe(source);
    expect(document.querySelector("a")?.textContent).toBe("Hill");
    expect(document.querySelectorAll("a")[1].textContent).toBe("照片");
    expect(html).toContain("Credit");
  });

  it("does not pass unsafe protocols or invalid images to the renderer", async () => {
    fetchImage.mockResolvedValue({ url: new URL(source), contentType: "text/html", bytes: new TextEncoder().encode("not an image") });
    const html = await prepareReportImages(`<html><body><img src="${source}"><img src="file:///tmp/private"><img src="javascript:alert(1)"></body></html>`);
    expect(fetchImage).toHaveBeenCalledOnce();
    expect(html).not.toContain("<img");
    expect(html).not.toContain("file:");
    expect(html).not.toContain("javascript:");
  });

  it("keeps a source link if image decoding fails", async () => {
    fetchImage.mockResolvedValue({ url: new URL(source), contentType: "image/png", bytes: new TextEncoder().encode("corrupt PNG") });
    const html = await prepareReportImages(`<html><body><img src="${source}"></body></html>`);
    expect(html).toContain(`href="${source}"`);
    expect(html).not.toContain("<img");
  });

  it("leaves reports without photos untouched", async () => {
    const html = "<!doctype html><html><body>Trip</body></html>";
    expect(await prepareReportImages(html)).toBe(html);
    expect(fetchImage).not.toHaveBeenCalled();
  });

  it("accounts for repeated data URLs when bounding the HTML image budget", async () => {
    const bytes = await sharp({ create: { width: 1440, height: 1440, channels: 3, background: "#6699cc" } }).png().toBuffer();
    const jpeg = await sharp(bytes).rotate().resize({ width: 1440, height: 1440, fit: "inside", withoutEnlargement: true }).flatten({ background: "#ffffff" }).jpeg({ quality: 76 }).toBuffer();
    fetchImage.mockResolvedValue({ url: new URL(source), contentType: "image/png", bytes });
    const copies = Math.floor((12 * 1024 * 1024) / jpeg.length) + 1;
    const html = await prepareReportImages(`<html><body>${`<img src="${source}">`.repeat(copies)}</body></html>`);
    expect(fetchImage).toHaveBeenCalledOnce();
    expect(html).not.toContain("data:image");
    expect(html).toContain(`href="${source}"`);
  });

  it("uses source links after the photo preparation deadline", async () => {
    const now = vi.spyOn(Date, "now").mockReturnValue(0);
    const bytes = await sharp({ create: { width: 20, height: 20, channels: 3, background: "#6699cc" } }).png().toBuffer();
    fetchImage.mockImplementation(async () => {
      now.mockReturnValue(20_001);
      return { url: new URL(source), contentType: "image/png", bytes };
    });
    const html = await prepareReportImages(`<html><body><img src="${source}"></body></html>`);
    expect(html).not.toContain("data:image");
    expect(html).toContain(`href="${source}"`);
  });
});
